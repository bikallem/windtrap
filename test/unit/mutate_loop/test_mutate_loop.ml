(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The loop forks, so it is observed from outside its process: each
   scenario starts suite_main.exe (or a sibling fixture) in a stated
   environment and reads what the loop decided from the dry run's summary,
   the outcome line, the survivors it named and the verdict file. How a
   report lays these out is Report_sections'. Only [drain], which reads the
   pipes of the children, [next_look], which times the looks at a child,
   and [deadline], which holds the formula of the deadline of a child, are
   called in this process ([never_empty], [looks], [deadline_formula]). *)

open Windtrap
module Mutate = Windtrap_runtime.Mutate
module Verdicts = Windtrap_runtime.Verdicts
module Instr = Windtrap_runtime.Instr
module Child = Windtrap_test_support.Child

let strf = Printf.sprintf
let exe_dir = Filename.dirname Instr.executable
let suite_exe = Filename.concat exe_dir "suite_main.exe"
let plain_exe = Filename.concat exe_dir "plain_main.exe"
let runaway_exe = Filename.concat exe_dir "runaway/runaway_main.exe"
let inline_exe = Filename.concat exe_dir "inline/runner_main.exe"
let scoped_exe = Filename.concat exe_dir "scoped/scoped_main.exe"
let partitions_exe = Filename.concat exe_dir "partitions/partitions_main.exe"

(* Under --instrument-with the fixtures link an instrumented core, so every
   loop scenario passes this directory as its scope: the counts below are
   those of subject.ml, spinner.ml, inline_armed.ml and quiet.ml alone. *)
let scope = "test/unit/mutate_loop/"
let mutate = "--mutate=" ^ scope
let mutate_mirror = ("WINDTRAP_MUTATE", scope)
let jobs n = strf "--mutate-jobs=%d" n
let suite name = ("MUTATE_FIXTURE", name)
let exec_children = ("WINDTRAP_MUTATE_CHILDREN", "exec")
let flagged = suite "flagged"
let weak = ("MUTATE_WEAK", "1")

(* Under --instrument-with this executable's core catalogues its mutants,
   and so does plain_main's. *)
let core_instrumented =
  match Mutate.catalogue () with [] -> false | _ :: _ -> true

let read path =
  if Sys.file_exists path then
    In_channel.with_open_bin path In_channel.input_all
  else ""

let write path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)
let remove path = try Sys.remove path with Sys_error _ -> ()
let entries dir = List.sort String.compare (Array.to_list (Sys.readdir dir))
let lines s = String.split_on_char '\n' s

let index_of ~sub ?(from = 0) s =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1)
  in
  go from

(* What a run ended with *)

let signal_name signal =
  let names =
    [
      (Sys.sighup, "SIGHUP");
      (Sys.sigint, "SIGINT");
      (Sys.sigkill, "SIGKILL");
      (Sys.sigpipe, "SIGPIPE");
      (Sys.sigterm, "SIGTERM");
    ]
  in
  Option.value (List.assoc_opt signal names) ~default:(string_of_int signal)

let ended = function
  | Unix.WEXITED code -> strf "exited %d" code
  | Unix.WSIGNALED signal -> "killed by " ^ signal_name signal
  | Unix.WSTOPPED signal -> "stopped by " ^ signal_name signal

let verdict = function
  | Verdicts.Killed _ -> "killed"
  | Verdicts.Killed_elsewhere { exe } -> "killed elsewhere by " ^ exe
  | Verdicts.Survived { first; others; runs } ->
      "survived by "
      ^ String.concat ", "
          (List.map (String.concat " \u{203a} ") (first :: others))
      ^ if runs > 1 then strf " (%d runs)" runs else ""
  | Verdicts.Flaky { test; failure } ->
      strf "flaky by %s: %s" (String.concat " \u{203a} " test) failure
  | Verdicts.Not_evaluated -> "not evaluated"
  | Verdicts.Outside_tests -> "outside tests"
  | Verdicts.Filtered reason -> "filtered: " ^ reason
  | Verdicts.Unreached -> "unreached"

let local file =
  if String.starts_with ~prefix:scope file then
    String.sub file (String.length scope)
      (String.length file - String.length scope)
  else file

(* A record as a row: the file under the scope, the line, the verdict. *)
let row (r : Verdicts.record) =
  strf "%s:%d %s" (local r.id.file) r.id.line (verdict r.verdict)

(* The same, with the previous verdict of the record in place of the
   verdict. *)
let previous_row (r : Verdicts.record) =
  strf "%s:%d %s" (local r.id.file) r.id.line
    (match r.previous with None -> "none" | Some v -> verdict v)

type file = {
  raw : string;
  rows : string list;
  previous : string list; (* The previous verdict of each record. *)
  identity : (string * string) option; (* The writer's path and digest. *)
}

let identity (i : Verdicts.identity) = (i.exe, i.digest)

let saved path =
  if not (Sys.file_exists path) then None
  else
    let raw = read path in
    match Verdicts.load path with
    | Ok (t, writer, _) ->
        Some
          {
            raw;
            rows = List.map row (Verdicts.records t);
            previous = List.map previous_row (Verdicts.records t);
            identity = Option.map identity writer;
          }
    | Error e ->
        let reason = Format.asprintf "unreadable: %a" Verdicts.pp_error e in
        Some { raw; rows = [ reason ]; previous = []; identity = None }

type ran = {
  status : string;
  out : string;
  err : string;
  file : file option; (* The executable's verdict file as the run left it. *)
}

let rows r = Option.map (fun (f : file) -> f.rows) r.file
let previous_rows r = Option.map (fun (f : file) -> f.previous) r.file

(* No test is ever reported slow, so the dry run's report is the same on
   any machine. *)
let quiet env = ("WINDTRAP_SLOW_THRESHOLD", "0") :: env

(* The suite that a fixture executable runs, unless a scenario names one. *)
let suite_of exe =
  if exe = inline_exe then "inline_armed"
  else if exe = runaway_exe then "spin"
  else if exe = scoped_exe then "scoped"
  else if exe = plain_exe then "plain"
  else "calc"

(* The verdict file of the suite [suite] of the executable [exe]. *)
let verdict_path ?suite exe =
  let suite = Option.value suite ~default:(suite_of exe) in
  Verdicts.output_file ~exe ~suite

(* The verdict files of every suite of [exe] in its data directory, sorted. *)
let suite_files exe =
  let stem = Instr.output_dir Verdicts.format ~exe in
  let dir = Filename.dirname stem and prefix = Filename.basename stem ^ "-" in
  if not (Sys.file_exists dir && Sys.is_directory dir) then []
  else
    entries dir
    |> List.filter (fun name ->
        String.starts_with ~prefix name
        && String.ends_with ~suffix:".mutants" name)
    |> List.map (Filename.concat dir)

let remove_suite_files exe = List.iter remove (suite_files exe)

(* The verdict files of the executable are removed first, so a stale file
   cannot pass a test the loop failed to write. *)
let spawn ?(exe = suite_exe) ?suite ?cwd ?(env = []) args =
  remove_suite_files exe;
  let path = verdict_path ?suite exe in
  let r = Child.run ?cwd ~env:(quiet env) exe args in
  {
    status = ended r.Child.status;
    out = r.Child.out;
    err = r.Child.err;
    file = saved path;
  }

(* A run the test watches while it goes. [stdout], when given, replaces
   the file and stays the caller's to close. [exe] can be a launcher. The
   verdict file of the run is that of [writer]. *)
type started = {
  pid : int;
  writer : string;
  verdict_file : string;
  out_path : string;
  err_path : string;
}

let start ?(exe = suite_exe) ?(writer = suite_exe) ?suite ?stdout ~env args =
  let dir = temp_dir () in
  let out_path = Filename.concat dir "out"
  and err_path = Filename.concat dir "err" in
  let target path =
    Unix.openfile path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ]
      0o644
  in
  let out = target out_path and err = target err_path in
  let pid =
    Fun.protect
      ~finally:(fun () -> List.iter Unix.close [ out; err ])
      (fun () ->
        Unix.create_process_env exe
          (Array.of_list (exe :: args))
          (Child.environment (quiet env))
          Unix.stdin
          (Option.value stdout ~default:out)
          err)
  in
  { pid; writer; verdict_file = verdict_path ?suite writer; out_path; err_path }

let finish started =
  let _, status = Unix.waitpid [] started.pid in
  {
    status = ended status;
    out = read started.out_path;
    err = read started.err_path;
    file = saved started.verdict_file;
  }

(* A process this suite started must not outlive it: a file that never
   comes, or never holds what [ready] asks, kills the run and fails the
   test. *)
let await ?(ready = fun contents -> contents <> "") ~what started path =
  let rec poll attempts =
    if ready (read path) then ()
    else if attempts = 0 then begin
      (try Unix.kill started.pid Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (finish started);
      failf "%s never happened" what
    end
    else begin
      Unix.sleepf 0.01;
      poll (attempts - 1)
    end
  in
  poll 3000

(* The parent reaps a child as soon as its pipe closes, so a pid that is gone
   is a child whose verdict the loop holds. *)
let reaped ~what started pid =
  let rec poll attempts =
    match Unix.kill pid 0 with
    | () when attempts = 0 ->
        (try Unix.kill started.pid Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (finish started);
        failf "%s never happened" what
    | () ->
        Unix.sleepf 0.01;
        poll (attempts - 1)
    | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()
  in
  poll 3000

(* A condition that never holds kills the run and fails the test. *)
let until ~what started holds =
  let rec poll attempts =
    if holds () then ()
    else if attempts = 0 then begin
      (try Unix.kill started.pid Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (finish started);
      failf "%s never happened" what
    end
    else begin
      Unix.sleepf 0.01;
      poll (attempts - 1)
    end
  in
  poll 3000

(* A run that must end on its own is ended after [seconds], SIGTERM first,
   which the loop answers by killing its running child's group. While the
   run goes, [meanwhile] runs every 10 ms. *)
let finish_within ?(seconds = 10.) ?(meanwhile = ignore) ~what started =
  let rec wait_until time =
    match Unix.waitpid [ Unix.WNOHANG ] started.pid with
    | 0, _ when Unix.gettimeofday () > time -> None
    | 0, _ ->
        meanwhile ();
        Unix.sleepf 0.01;
        wait_until time
    | _, status -> Some status
  in
  match wait_until (Unix.gettimeofday () +. seconds) with
  | Some status ->
      {
        status = ended status;
        out = read started.out_path;
        err = read started.err_path;
        file = saved started.verdict_file;
      }
  | None ->
      (try Unix.kill started.pid Sys.sigterm with Unix.Unix_error _ -> ());
      if wait_until (Unix.gettimeofday () +. 5.) = None then begin
        (try Unix.kill started.pid Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] started.pid)
      end;
      failf "%s: the run was still going after %.0fs" what seconds

(* A zombie has died and waits for its reaper, which a container's first
   process may never be: Linux shows its state in /proc, and elsewhere
   init reaps it. *)
let zombie pid =
  match
    In_channel.with_open_bin (strf "/proc/%d/stat" pid) In_channel.input_all
  with
  | stat -> (
      (* The state follows the ")" that closes the command's name. *)
      match String.rindex_opt stat ')' with
      | Some i when i + 2 < String.length stat -> stat.[i + 2] = 'Z'
      | Some _ | None -> false)
  | exception Sys_error _ -> false

(* A grandchild that ignores SIGTERM dies only by its group's SIGKILL, and
   init's reap of it can lag. *)
let fate pid =
  let rec poll attempts =
    match Unix.kill pid 0 with
    | () when zombie pid -> "gone"
    | () when attempts = 0 -> "alive"
    | () ->
        Unix.sleepf 0.1;
        poll (attempts - 1)
    | exception Unix.Unix_error (Unix.ESRCH, _, _) -> "gone"
    | exception Unix.Unix_error (e, _, _) -> Unix.error_message e
  in
  poll 100

let pids text = List.filter_map int_of_string_opt (lines text)

(* A child that ended and that its parent did not reap is a zombie. Where
   /proc is missing, half a second stands in for the check. *)
let exited ~what started pid =
  let rec poll attempts =
    if zombie pid then ()
    else if attempts = 0 then begin
      (try Unix.kill started.pid Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (finish started);
      failf "%s never happened" what
    end
    else begin
      Unix.sleepf 0.01;
      poll (attempts - 1)
    end
  in
  if Sys.file_exists "/proc/self/stat" then poll 3000 else Unix.sleepf 0.5

(* Fills the pipe of [writer] until a write would block. *)
let fill writer =
  Unix.set_nonblock writer;
  let rec write chunk =
    match Unix.write writer chunk 0 (Bytes.length chunk) with
    | _ -> write chunk
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
  in
  write (Bytes.make 4096 'x');
  write (Bytes.make 1 'x');
  Unix.clear_nonblock writer

let read_to_end fd =
  let chunk = Bytes.create 65536 and contents = Buffer.create 65536 in
  let rec read () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents contents
    | n ->
        Buffer.add_subbytes contents chunk 0 n;
        read ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
  in
  read ()

(* What a report says *)

(* The first line, the dry run's summary, with its duration masked. *)
let summary out =
  let first = List.hd (lines out) in
  match String.rindex_opt first ' ' with
  | Some i -> String.sub first 0 (i + 1) ^ "<time>."
  | None -> first

let masked out =
  match lines out with
  | [] -> out
  | _ :: rest -> String.concat "\n" (summary out :: rest)

(* The last line printed. *)
let outcome out =
  match List.rev (List.filter (fun l -> l <> "") (lines out)) with
  | last :: _ -> last
  | [] -> ""

let survivors out =
  List.filter_map
    (fun line ->
      match String.split_on_char ' ' (String.trim line) with
      | "SURVIVED" :: rest -> List.find_opt (fun w -> w <> "") rest
      | _ -> None)
    (lines out)

(* A survivor's reaching tests, each with its location; the fixture's line
   numbers are masked, since suite_main.ml moves under edits no claim here is
   about. *)
let witnesses out =
  let located line =
    match index_of ~sub:"  " line with
    | None -> line
    | Some i ->
        let loc = String.trim (String.sub line i (String.length line - i)) in
        let loc =
          match String.rindex_opt loc ':' with
          | Some j -> String.sub loc 0 (j + 1) ^ "N"
          | None -> loc
        in
        strf "%s (%s)" (String.sub line 0 i) loc
  in
  List.filter_map
    (fun line ->
      if
        String.starts_with ~prefix:"      " line
        && Option.is_some (index_of ~sub:" \u{203a} " line)
      then Some (located (String.trim line))
      else None)
    (lines out)

(* A survivor's source line, as the block quotes it. *)
let excerpt out =
  List.filter_map
    (fun line ->
      match index_of ~sub:" \u{2502} " line with
      | Some _ -> Some (String.trim line)
      | None -> None)
    (lines out)

let reproduce out =
  List.find_map
    (fun line ->
      if String.starts_with ~prefix:"reproduce: " line then
        Some (String.sub line 11 (String.length line - 11))
      else None)
    (lines out)

(* The catalogue *)

(* Read out of the binary rather than transcribed, so a line moving in
   subject.ml cannot re-point an armed identifier at another site. *)
let catalogue =
  lazy
    (let r = spawn ~env:[ suite "catalogue" ] [] in
     List.filter_map
       (fun line ->
         if String.starts_with ~prefix:scope line then
           Result.to_option (Mutate.id_of_string line)
         else None)
       (lines r.out))

let pp_ids ppf ids =
  Format.pp_print_list ~pp_sep:Format.pp_print_space
    (fun ppf id -> Format.pp_print_string ppf (Mutate.id_to_string id))
    ppf ids

(* The identifier of subject.ml's mutant on [line]. *)
let site_id line =
  require_match ~pp:pp_ids
    (List.find_opt (fun (id : Mutate.id) -> id.line = line))
    (Lazy.force catalogue)

let site line = Mutate.id_to_string (site_id line)

(* A run over the verdict file that an earlier run left. *)
let rerun ?suite ?(env = []) args =
  let r = Child.run ~env:(quiet env) suite_exe args in
  {
    status = ended r.Child.status;
    out = r.Child.out;
    err = r.Child.err;
    file = saved (verdict_path ?suite suite_exe);
  }

(* A line of the rule kind: dashes alone. *)
let is_rule line =
  line <> ""
  && String.length line mod 3 = 0
  && String.equal line
       (String.concat ""
          (List.init (String.length line / 3) (fun _ -> "\u{2500}")))

(* The lines of the section [title] of a report, between its opening rule
   and its closing rule. It is [None] when the report has none. *)
let sections ~title out =
  let opening = strf "\u{2500}\u{2500} %s (" title in
  let rec until acc = function
    | [] -> (List.rev acc, [])
    | line :: _ as rest when is_rule line -> (List.rev acc, rest)
    | line :: rest -> until (line :: acc) rest
  in
  let rec scan = function
    | [] -> []
    | line :: rest when Option.is_some (index_of ~sub:opening line) ->
        let body, after = until [] rest in
        body :: scan after
    | _ :: rest -> scan rest
  in
  scan (lines out)

let section ~title out =
  match sections ~title out with [] -> None | first :: _ -> Some first

let unstable = section ~title:"unstable"
let flaky_lines = section ~title:"flaky"

(* The previous verdicts of a file written with no file to compare with. *)
let none_rows = List.map (strf "subject.ml:%d none") [ 15; 18; 21; 27; 38 ]
let lead = "  The source of each mutant did not change, but its verdict did."

(* The section with one row for each [(line, change)] of subject.ml: the
   identifier padded to the widest, then the change. *)
let listed changes =
  let ids = List.map (fun (line, _) -> site line) changes in
  let width = List.fold_left (fun w id -> max w (String.length id)) 0 ids in
  Some
    (lead
    :: List.map2
         (fun id (_, text) -> strf "  %-*s   %s" width id text)
         ids changes)

(* The scenarios several tests read. Each runs once, in the first test that
   reads it, and keeps what it saw: a lazy rather than a fixture, since a
   mutation child of this suite would acquire a fixture again. *)

let green = lazy (spawn [ mutate ])

let green_rows =
  [
    "subject.ml:15 killed";
    "subject.ml:18 survived by widen \u{203a} widen is nonzero, widen \u{203a} \
     widen is not 99";
    "subject.ml:21 unreached";
    "subject.ml:27 unreached";
    "subject.ml:38 filtered: zero operand";
  ]

let green_outcome =
  "mutants: 1 survived of 2 reached by this suite, 1 killed, 2 never reached, \
   1 filtered, score 50.0%"

let not_saved =
  "windtrap: verdicts not saved: this run's selection narrows the suite, and a \
   partial run's verdicts would stand in the project merge as the whole.\n"

let located test = strf "%s (test/unit/mutate_loop/suite_main.ml:N)" test

(* Running *)

let running =
  group "Running"
    [
      cases "a run not asked to mutate is the ordinary run"
        ~name:(fun (name, _) -> name)
        [
          ("no variable", []);
          ("WINDTRAP_MUTATE=off", [ ("WINDTRAP_MUTATE", "off") ]);
        ]
        (fun (_, env) ->
          let r = spawn ~env [] in
          equal string "exited 0" r.status;
          equal text "calc: 7 passed in <time>.\n" (masked r.out);
          equal text "" r.err);
      test "a build with no mutants runs as it would without the seam"
        (fun () ->
          let r = spawn ~exe:plain_exe [] in
          equal string "exited 0" r.status;
          equal text "plain: 1 passed in <time>.\n" (masked r.out);
          equal text "" r.err);
      test "a loop that ran whole exits 0 with a survivor, stderr silent"
        (fun () ->
          let r = Lazy.force green in
          equal string "exited 0" r.status;
          equal (list string) [ site 18 ] (survivors r.out);
          equal text "" r.err);
    ]

(* The population *)

let rewrites () =
  List.map
    (fun (id : Mutate.id) -> strf "%d %s" id.line id.rewrite)
    (Lazy.force catalogue)

let population =
  group "Population"
    [
      test "the fixture catalogues subject.ml's six sites in source order"
        (fun () ->
          equal (list string)
            [ "15 add"; "18 sub"; "21 sub"; "27 add"; "33 sub"; "38 sub" ]
            (rewrites ()));
      test "a scope keeps every mutant under it, and dismissal drops one"
        (fun () ->
          let r = Lazy.force green in
          equal (option (list string)) (Some green_rows) (rows r);
          equal string green_outcome (outcome r.out));
      test "WINDTRAP_MUTATE with prefixes is the scope --mutate gives"
        (fun () ->
          let r = spawn ~env:[ mutate_mirror ] [] in
          equal string "exited 0" r.status;
          equal string green_outcome (outcome r.out));
      test "a truthy WINDTRAP_MUTATE is the bare flag, every mutant in scope"
        (fun () ->
          if core_instrumented then
            skip
              ~reason:
                "under --instrument-with the core is instrumented, so the bare \
                 flag would survey its mutants too"
              ();
          let r = spawn ~env:[ ("WINDTRAP_MUTATE", "1") ] [] in
          equal string "exited 0" r.status;
          equal string green_outcome (outcome r.out));
    ]

(* The dry run *)

(* [baseline]'s one test pins [sub]'s answer against a file under
   WINDTRAP_PROJECT_ROOT; the run also asks for a JUnit file there. *)
type baseline_run = {
  ran : ran;
  baseline : string; (* The baseline file as the run left it. *)
  beside : string list; (* What else the run left in the root. *)
}

let baseline_run ?(env = []) args ~stale =
  let root = temp_dir () in
  let file = Filename.concat root "sub.expected" in
  write file stale;
  let ran =
    spawn
      ~env:(suite "baseline" :: ("WINDTRAP_PROJECT_ROOT", root) :: env)
      (args @ [ "--junit"; Filename.concat root "junit.xml" ])
  in
  {
    ran;
    baseline = read file;
    beside = List.filter (fun name -> name <> "sub.expected") (entries root);
  }

let baseline_loop = lazy (baseline_run [ mutate; "-u" ] ~stale:"5\n")
let boundary = lazy (spawn ~env:[ suite "boundary" ] [ mutate ])

let outside_tests () =
  let r = Lazy.force boundary in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 survived of 2 reached by this suite, 1 killed, 2 evaluated \
     outside tests, 1 filtered, score 50.0%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 survived by widen \u{203a} first reaches widen, after \
          a retry, widen \u{203a} third reaches widen";
         "subject.ml:21 outside tests";
         "subject.ml:27 outside tests";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

let tagged () =
  let r = spawn ~env:[ suite "tagged"; ("WINDTRAP_TAG", "gated") ] [ mutate ] in
  equal string "exited 0" r.status;
  equal string "calc: 5 passed in <time>." (summary r.out);
  equal string
    "mutants: 1 survived of 2 reached by the 5 selected tests, 1 killed, 2 \
     never reached, 1 filtered, score 50.0%"
    (outcome r.out);
  equal (list string)
    [
      located "widen \u{203a} widen is nonzero";
      located "widen \u{203a} widen is not 99";
    ]
    (witnesses r.out);
  equal text not_saved r.err

let dry_run =
  group "Dry run"
    [
      test "the dry run's report comes first and the loop's outcome line last"
        (fun () ->
          let r = Lazy.force green in
          equal string "calc: 7 passed in <time>." (summary r.out);
          equal string green_outcome (outcome r.out));
      test "the dry run of --mutate -u accepts what -u accepts" (fun () ->
          let b = Lazy.force baseline_loop in
          equal string "exited 0" b.ran.status;
          contains ~sub:"  accepted sub.expected\n" b.ran.out;
          equal text "6\n" b.baseline);
      test "the dry run writes no JUnit file" (fun () ->
          equal (list string) [] (Lazy.force baseline_loop).beside);
      test
        "a site evaluated at module initialization or in a fixture release is \
         evaluated outside tests"
        outside_tests;
      test
        "a retried test is one reaching test, and a test that ran elsewhere \
         none" (fun () ->
          let r = Lazy.force boundary in
          equal (list string) [ site 18 ] (survivors r.out);
          equal (list string)
            [
              located "widen \u{203a} first reaches widen, after a retry";
              located "widen \u{203a} third reaches widen";
            ]
            (witnesses r.out));
      test "a tag selection is the children's selection too" tagged;
    ]

(* The determinism probe *)

let disagreeing () =
  let r = spawn ~env:[ suite "flaky" ] [ mutate ] in
  equal string "exited 1" r.status;
  contains ~sub:"the suite is not deterministic" r.err;
  contains ~sub:"the dry run executed 4 tests, skipping 0 and failing none"
    r.err;
  contains ~sub:"the probe executed 4, skipping 0 and failing 1" r.err;
  contains ~sub:"flaky \u{203a} passes where it was measured" r.err;
  not_contains ~sub:"mutants: " r.out

let probe =
  group "Determinism probe"
    [
      test "a probe that fails a test is refused, naming the test" disagreeing;
      test "a probe that only skips differently is refused on the skip count"
        (fun () ->
          let r = spawn ~env:[ suite "skippy" ] [ mutate ] in
          equal string "exited 1" r.status;
          equal text
            "windtrap: the suite is not deterministic: the dry run executed 4 \
             tests, skipping 0 and failing none; the probe executed 4, \
             skipping 1 and failing 0. Mutation results over a \
             non-deterministic suite are not a weaker number, they are not a \
             number\n"
            r.err;
          not_contains ~sub:"mutants: " r.out);
    ]

(* Children *)

(* Every process that reaches Stdlib's exit machinery appends its pid to the
   log; [fatal]'s armed child raises Out_of_memory, which only the child's
   own wrapper keeps from the uncaught-exception handler that runs
   [at_exit]. *)
let no_at_exit_with env () =
  let log = Filename.concat (temp_dir ()) "atexit" in
  let r =
    spawn ~env:(suite "fatal" :: ("MUTATE_ATEXIT_LOG", log) :: env) [ mutate ]
  in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 survived of 3 reached by this suite, 2 killed, 1 never \
     reached, 1 filtered, score 66.7%"
    (outcome r.out);
  equal int 1 (List.length (pids (read log)))

let no_at_exit = no_at_exit_with []
let release = lazy (spawn ~env:[ suite "release" ] [ mutate ])

(* The inline runtime keeps its correction directory as its working
   directory at module load, so the fixture is staged there under the name
   the correction writer opens: a write would succeed, not fail on a missing
   file. *)
let staged () =
  let dir = temp_dir () in
  write
    (Filename.concat dir "inline_armed.ml")
    (read (Filename.concat exe_dir "inline/inline_armed.ml"));
  dir

let inline_run env =
  let cwd = staged () in
  let r =
    spawn ~exe:inline_exe ~cwd ~env [ "inline-test-runner"; "inline_armed" ]
  in
  (r, entries cwd)

let inline_loop_with env () =
  let r, left = inline_run (mutate_mirror :: env) in
  equal string "exited 0" r.status;
  equal text "" r.err;
  contains ~sub:"inline_armed: 1 passed" r.out;
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  equal (list string) [ "inline_armed.ml" ] left

let inline_loop = inline_loop_with []

let children =
  group "Children"
    [
      test "a child checks baselines read-only" (fun () ->
          let b = Lazy.force baseline_loop in
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome b.ran.out);
          equal text "6\n" b.baseline);
      test "no at_exit function runs in a child, a fatal exception included"
        no_at_exit;
      test "nothing a child prints reaches the loop's descriptors" (fun () ->
          let r = Lazy.force release in
          not_contains ~sub:"a child's release" r.out;
          equal text "" r.err);
      test
        "a loop under the inline runner kills through its children and writes \
         no correction"
        inline_loop;
    ]

(* Verdicts *)

let survivor_named () =
  let r = Lazy.force green in
  equal (list string) [ site 18 ] (survivors r.out);
  equal (list string)
    [
      located "widen \u{203a} widen is nonzero";
      located "widen \u{203a} widen is not 99";
    ]
    (witnesses r.out);
  equal string green_outcome (outcome r.out)

let crashed () =
  let r = spawn ~env:[ suite "crash" ] [ mutate ] in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 survived of 3 reached by this suite, 2 killed, 1 never \
     reached, 1 filtered, score 66.7%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 survived by widen \u{203a} widen is nonzero, widen \
          \u{203a} widen is not 99";
         "subject.ml:21 unreached";
         "subject.ml:27 killed";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

(* [memo] fills a table in the dry run, so the child that arms [widen]'s
   mutant reads the answer and never evaluates the site. *)
let memo = lazy (spawn ~env:[ suite "memo" ] [ mutate ])

let not_evaluated () =
  let r = Lazy.force memo in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal (list string) [] (survivors r.out);
  equal string
    "mutants: 2 reached by this suite, 1 killed, 1 not evaluated, 2 never \
     reached, 1 filtered, score 50.0%"
    (outcome r.out);
  contains ~sub:(strf "arm: %s --arm %s\n" suite_exe (site 18)) r.out

(* [memo_flaky] fails its test in each child after the probe. The child of
   [widen]'s mutant reads the answer from the table and does not evaluate the
   armed site. *)
let unevaluated_failure () =
  let marker = Filename.concat (temp_dir ()) "marker" in
  let r =
    spawn ~env:[ suite "memo_flaky"; ("MUTATE_MARKER", marker) ] [ mutate ]
  in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 reached by this suite, 1 not evaluated, 3 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out);
  contains
    ~sub:
      "    a failure that the mutant did not cause: memo \u{203a} memoized \
       widen adds, and fails in each child after the probe\n"
    r.out;
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 unreached";
         "subject.ml:18 not evaluated";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

let with_marker name =
  let marker = Filename.concat (temp_dir ()) "marker" in
  spawn ~env:[ suite name; ("MUTATE_MARKER", marker) ] [ mutate ]

let raw r = Option.fold ~none:"" ~some:(fun (f : file) -> f.raw) r.file

let capped () =
  let r = spawn ~env:[ suite "capped" ] [ mutate ] in
  equal (list string) [ site 18; site 21 ] (survivors r.out);
  equal string
    "mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never \
     reached, 1 filtered, score 33.3%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 survived by widen \u{203a} widen is nonzero, widen \
          \u{203a} widen is not 99";
         "subject.ml:21 survived by orphan \u{203a} orphan is nonzero";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

let verdicts =
  group "Verdicts"
    [
      test
        "a pinned mutant is killed, and one no test pins survives naming its \
         reaching tests"
        survivor_named;
      test "a child that dies without a verdict is killed" crashed;
      test "a failure in a fixture release kills the mutant" (fun () ->
          let r = Lazy.force release in
          equal string "exited 0" r.status;
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out));
      test "a mutant its child did not evaluate is no survivor" not_evaluated;
      test "the verdict file records it as not evaluated" (fun () ->
          equal
            (option (list string))
            (Some
               [
                 "subject.ml:15 killed";
                 "subject.ml:18 not evaluated";
                 "subject.ml:21 unreached";
                 "subject.ml:27 unreached";
                 "subject.ml:38 filtered: zero operand";
               ])
            (rows (Lazy.force memo)));
      test "its arm command, a new process, kills it" (fun () ->
          let r = spawn ~env:[ suite "memo" ] [ "--arm"; site 18 ] in
          equal string "exited 1" r.status;
          equal string "mutant killed." (outcome r.out));
      test
        "a test that fails in a child that did not evaluate the site of the \
         mutant does not kill it, and the report names the test"
        unevaluated_failure;
      test
        "a fixture release that fails in a child that did not evaluate the \
         site of the mutant does not kill it" (fun () ->
          let r = with_marker "flaky_release" in
          equal string "exited 0" r.status;
          equal string
            "mutants: 1 reached by this suite, 1 not evaluated, 3 never \
             reached, 1 filtered, score 0.0%"
            (outcome r.out);
          contains
            ~sub:
              "    a failure that the mutant did not cause: a fixture release\n"
            r.out);
      test
        "a test that fails before the first evaluation does not stop the \
         child, and a later test kills the mutant" (fun () ->
          let r = with_marker "fails_first" in
          equal string "exited 0" r.status;
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out);
          (* The record of the killer: its group, then its name. *)
          contains ~sub:"killed 1 2 5 first 10 widen adds" (raw r);
          equal bool false
            (String.includes ~affix:"fails after the probe" (raw r)));
      test
        "an evaluation in a process that a test forks counts, and the failure \
         kills the mutant" (fun () ->
          let r = spawn ~env:[ suite "forked" ] [ mutate ] in
          equal string "exited 0" r.status;
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out));
      test
        "a fatal exception before the first evaluation does not kill the mutant"
        (fun () ->
          let r = with_marker "fatal_first" in
          equal string "exited 0" r.status;
          equal string
            "mutants: 1 reached by this suite, 1 not evaluated, 3 never \
             reached, 1 filtered, score 0.0%"
            (outcome r.out);
          not_contains ~sub:"a failure that the mutant did not cause" r.out);
      test "an armed run does not count a failure before the first evaluation"
        (fun () ->
          let r = spawn ~env:[ suite "red" ] [ "--arm"; site 18 ] in
          equal string "exited 1" r.status;
          equal string
            "mutant survived: the site ran 2 times, and only tests before its \
             first run failed."
            (outcome r.out));
      test
        "an armed run under fail-fast does not stop at a failure before the \
         first evaluation" (fun () ->
          let r = spawn ~env:[ suite "red" ] [ "--arm"; site 18; "-x" ] in
          equal string "exited 1" r.status;
          equal string
            "mutant survived: the site ran 2 times, and only tests before its \
             first run failed."
            (outcome r.out));
      test
        "an armed run counts an evaluation in a forked process for a survivor"
        (fun () ->
          let r = spawn ~env:[ suite "fork_only" ] [ "--arm"; site 18 ] in
          equal string "exited 0" r.status;
          equal string
            "mutant survived: only a forked process ran the site, and no test \
             failed after that."
            (outcome r.out));
      test
        "an armed run in which only a test marked xfail evaluates the site, in \
         a forked process, does not reach the mutant" (fun () ->
          let r = spawn ~env:[ suite "fork_xfail" ] [ "--arm"; site 18 ] in
          equal string "mutant not reached: only xfail tests ran the site."
            (outcome r.out));
      test
        "an armed run counts the evaluation of an ordinary test in a forked \
         process beside a test marked xfail" (fun () ->
          let r = spawn ~env:[ suite "xfail_then_fork" ] [ "--arm"; site 18 ] in
          equal string
            "mutant survived: the armed site was evaluated 1 time and no test \
             failed."
            (outcome r.out));
      test "an armed run counts an evaluation in a forked process" (fun () ->
          let r = spawn ~env:[ suite "forked" ] [ "--arm"; site 18 ] in
          equal string "exited 1" r.status;
          equal string "mutant killed." (outcome r.out));
      test
        "an armed run whose tests fail without an evaluation of the site does \
         not kill the mutant" (fun () ->
          let r =
            spawn
              ~env:[ suite "red" ]
              [ "--arm"; site 18; "--filter"; "always red" ]
          in
          equal string "exited 1" r.status;
          equal string
            "mutant not evaluated: no selected test ran the site, so the \
             mutant did not cause the failure."
            (outcome r.out));
      test "every survivor is named" capped;
      test
        "a loop that kills everything it reaches prints its filtered mutants \
         and its outcome alone" (fun () ->
          let r = spawn ~env:[ suite "pinned" ] [ mutate ] in
          equal string "exited 0" r.status;
          equal text "" r.err;
          let unruled =
            List.filter
              (fun line -> not (String.starts_with ~prefix:"\u{2500}" line))
              (String.split_on_char '\n' (masked r.out))
          in
          equal (list string)
            [
              "calc: 6 passed in <time>.";
              "";
              "  The rewriter found these mutants equivalent or of no \
               interest, and no child tested them.";
              "  1  zero operand";
              "";
              "mutants: 4 reached by this suite, 4 killed, 1 filtered, score \
               100.0%";
              "";
            ]
            unruled;
          contains ~sub:" filtered (1) " r.out);
    ]

(* Tests marked xfail *)

(* [known] pairs [sub] and [widen] each with a test that pins nothing and a
   test marked xfail, and gives [orphan] an xfail test alone. [sub adds]
   passes where [sub]'s mutant is armed. *)
let known = lazy (spawn ~env:[ suite "known" ] [ mutate ])

let no_xfail_witness () =
  let r = Lazy.force known in
  equal string "exited 0" r.status;
  equal (list string) [ site 15; site 18 ] (survivors r.out);
  equal (list string)
    [
      located "known \u{203a} watches sub without pinning it";
      located "known \u{203a} widen is nonzero";
    ]
    (witnesses r.out);
  equal string
    "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out)

let known_armed line = spawn ~env:[ suite "known" ] [ "--arm"; site line ]

let xfail =
  group "Tests marked xfail"
    [
      test "the dry run runs the tests marked xfail" (fun () ->
          equal string "calc: 2 passed, 3 expected failures in <time>."
            (summary (Lazy.force known).out));
      test "no survivor names a test marked xfail, and none kills a mutant"
        no_xfail_witness;
      test "the verdict file names no test marked xfail" (fun () ->
          equal
            (option (list string))
            (Some
               [
                 "subject.ml:15 survived by known \u{203a} watches sub without \
                  pinning it";
                 "subject.ml:18 survived by known \u{203a} widen is nonzero";
                 "subject.ml:21 unreached";
                 "subject.ml:27 unreached";
                 "subject.ml:38 filtered: zero operand";
               ])
            (rows (Lazy.force known)));
    ]

(* Limits *)

let budget (k, over) =
  let target = (k * 8) + 1000 + over in
  let r =
    spawn
      ~env:[ suite "budget"; ("MUTATE_BUDGET", strf "%d %d" k target) ]
      [ mutate ]
  in
  equal string
    (if over = 0 then
       "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
        filtered, score 0.0%"
     else
       "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
        filtered, score 100.0%")
    (outcome r.out)

(* The runaway fixture's mutant spins; the hit budget stops it within
   microseconds, where a kill by the deadline waits out its 1.5-second
   floor. The first launch of a newly built executable can take seconds of
   the system's own, so an untimed run comes first. *)
let runaway () =
  ignore (spawn ~exe:runaway_exe []);
  let began = Unix.gettimeofday () in
  let r = spawn ~exe:runaway_exe [ mutate ] in
  let elapsed = Unix.gettimeofday () -. began in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal
    (option (list string))
    (Some [ "runaway/spinner.ml:15 killed" ]) (rows r);
  less float_exact ~than:1.0 elapsed

(* [block]'s child blocks on a pipe read until its deadline, after starting
   a grandchild that ignores SIGTERM. *)
type blocked = { run : ran; grandchildren : int list; elapsed : float }

let blocked =
  lazy
    (let pidfile = Filename.concat (temp_dir ()) "grandchild" in
     remove (verdict_path suite_exe);
     let began = Unix.gettimeofday () in
     let run =
       finish_within ~what:"the blocked child's deadline"
         (start
            ~env:[ suite "block"; ("MUTATE_GRANDCHILD_PIDFILE", pidfile) ]
            [ mutate ])
     in
     let elapsed = Unix.gettimeofday () -. began in
     { run; grandchildren = pids (read pidfile); elapsed })

let deadline_kill () =
  let b = Lazy.force blocked in
  equal string "exited 0" b.run.status;
  equal text "" b.run.err;
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome b.run.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows b.run)

(* The most memory, in kB, that the process [pid] has used until now: the
   line VmHWM of /proc/<pid>/status. It is [0] where the system does not
   give it, as for a process that exited. *)
let high_water pid =
  match
    In_channel.with_open_bin (strf "/proc/%d/status" pid) In_channel.input_all
  with
  | status ->
      List.find_map
        (fun line ->
          match String.split_on_char ':' line with
          | [ "VmHWM"; size ] ->
              Scanf.sscanf_opt (String.trim size) "%d kB" Fun.id
          | _ -> None)
        (lines status)
      |> Option.value ~default:0
  | exception Sys_error _ -> 0

(* [flood]'s child writes to its verdict pipe and never stops, so the pipe
   is never read to its end. In the second of its deadline, a loop that
   kept all that it read used more than 700 MB, and with 64 KiB of it, 8
   MB. *)
let flooded () =
  remove (verdict_path suite_exe);
  let run = start ~env:[ suite "flood" ] [ mutate ] in
  let peak = ref 0 in
  let r =
    finish_within ~what:"the flooding child's deadline"
      ~meanwhile:(fun () -> peak := Int.max !peak (high_water run.pid))
      run
  in
  equal string "exited 0" r.status;
  equal text "" r.err;
  if Sys.file_exists "/proc/self/status" then less int ~than:100_000 !peak;
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

(* [/dev/zero] is always ready and never at its end, as a pipe that a
   writer keeps full. But it has no race: the loop can empty the pipe of
   [flood] when it reads faster than the writers write. Without the limit of
   the reads, [drain] does not return, and the timeout of the test ends
   it. *)
let never_empty () =
  let zero = Unix.openfile "/dev/zero" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close zero) @@ fun () ->
  let kept = Buffer.create 4096 in
  let ended = Private.Mutate_loop.drain [ (zero, kept) ] in
  is_true (ended = []);
  equal int 65536 (Buffer.length kept)

(* A child that ended left a full pipe: 64 KiB, which the parent reads in
   16 reads of 4 KiB. The read of the end is the 17th. *)
let full_pipe () =
  let reader, writer = Unix.pipe ~cloexec:true () in
  Fun.protect ~finally:(fun () -> Unix.close reader) @@ fun () ->
  Unix.set_nonblock writer;
  let chunk = Bytes.make 4096 'x' in
  let rec write written =
    if written = 65536 then written
    else
      match Unix.write writer chunk 0 (Bytes.length chunk) with
      | n -> write (written + n)
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          written
  in
  let written = write 0 in
  Unix.close writer;
  let kept = Buffer.create 4096 in
  let ended = Private.Mutate_loop.drain [ (reader, kept) ] in
  is_true (ended = [ reader ]);
  equal int written (Buffer.length kept)

(* The sleep runs armed and unarmed alike, so the dry run prices it into
   the deadline; the verdict, not a stopwatch, says whether the clock
   ended the child. *)
let slow () =
  let r = spawn ~env:[ suite "slow" ] [ mutate ] in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 survived by slow \u{203a} sleeps briefly and pins \
          nothing about sub";
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

(* The fixture blocks only on its second run, on the marker the dry run
   leaves, so only the probe's own deadline can end it. *)
let probe_deadline () =
  let marker = Filename.concat (temp_dir ()) "marker" in
  let r =
    finish_within ~what:"the probe's deadline"
      (start
         ~env:[ suite "probe_block"; ("MUTATE_PROBE_MARKER", marker) ]
         [ mutate ])
  in
  equal string "exited 1" r.status;
  contains ~sub:"the determinism probe exceeded its deadline" r.err;
  contains ~sub:"not a number" r.err

let taskset =
  List.find_map
    (fun dir ->
      let path = Filename.concat dir "taskset" in
      if dir <> "" && Sys.file_exists path then Some path else None)
    (String.split_on_char ':'
       (Option.value ~default:"" (Sys.getenv_opt "PATH")))

(* Under [taskset -c 0] the loop sees one CPU
   ([Domain.recommended_domain_count]). *)
let one_cpu () =
  let taskset =
    match taskset with
    | None -> skip ~reason:"taskset is not on PATH" ()
    | Some taskset -> taskset
  in
  let pinned =
    spawn ~exe:taskset ~env:[ suite "catalogue" ] [ "-c"; "0"; suite_exe ]
  in
  if pinned.status <> "exited 0" then
    skip ~reason:"taskset cannot hold a process to CPU 0" ();
  remove (verdict_path suite_exe);
  taskset

(* Under [taskset -c 0,1] the loop sees two CPUs, on a host that has two
   or more. *)
let two_cpus () =
  if Domain.recommended_domain_count () < 2 then
    skip ~reason:"the host has fewer than two CPUs" ();
  let taskset =
    match taskset with
    | None -> skip ~reason:"taskset is not on PATH" ()
    | Some taskset -> taskset
  in
  let pinned =
    spawn ~exe:taskset ~env:[ suite "catalogue" ] [ "-c"; "0,1"; suite_exe ]
  in
  if pinned.status <> "exited 0" then
    skip ~reason:"taskset cannot hold a process to CPUs 0 and 1" ();
  remove (verdict_path suite_exe);
  taskset

(* [hung] reaches two mutants, so on one CPU 16 jobs give two children,
   which share the CPU, and each child of [hung] blocks until its deadline,
   three seconds or more. With the 16 jobs of the command line, the deadline
   would be 24 seconds or more. *)
let on_one_cpu () =
  let taskset = one_cpu () in
  let began = Unix.gettimeofday () in
  let r =
    finish_within ~seconds:30. ~what:"the deadlines of two children on one CPU"
      (start ~exe:taskset
         ~env:[ suite "hung" ]
         [ "-c"; "0"; suite_exe; mutate; jobs 16 ])
  in
  let elapsed = Unix.gettimeofday () -. began in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string
    "mutants: 2 reached by this suite, 2 killed, 2 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  at_least float_exact ~than:3.0 elapsed;
  less float_exact ~than:8.0 elapsed

(* [spinners] reaches two mutants, and each child uses the CPU until its
   deadline, about 1.5 seconds for one job. On one CPU, 2 jobs give two
   children for each CPU. Thus each deadline is three seconds, and each
   child gets half of the CPU, so it uses about 1.5 seconds of CPU time. The
   wait of each child for the other one does not move its deadline again:
   with that wait, each child used three seconds. The loop reaps its children
   and this test reaps the loop, so [tms_cutime] and [tms_cstime] hold their
   CPU time. *)
let spinning_on_one_cpu () =
  let taskset = one_cpu () in
  let children_cpu () =
    let times = Unix.times () in
    times.tms_cutime +. times.tms_cstime
  in
  let before = children_cpu () in
  let r =
    finish_within ~seconds:30. ~what:"the deadlines of two spinning children"
      (start ~exe:taskset
         ~env:[ suite "spinners" ]
         [ "-c"; "0"; suite_exe; mutate; jobs 2 ])
  in
  let used = children_cpu () -. before in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string
    "mutants: 2 reached by this suite, 2 killed, 2 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  less float_exact ~than:4.5 used

(* [flood] armed is 8 processes that use the CPU. On one CPU, the sum of
   their waits for the CPU grows 7 times as fast as the clock. The credit
   for that wait is at most the time that they did not use the CPU, so the
   deadline comes. *)
let flooded_on_one_cpu () =
  if not (Sys.file_exists "/proc/self/schedstat") then
    skip ~reason:"the system does not give the time that a process waits" ();
  let taskset = one_cpu () in
  let r =
    finish_within ~seconds:30. ~what:"the flooding child's deadline on one CPU"
      (start ~exe:taskset
         ~env:[ suite "flood" ]
         [ "-c"; "0"; suite_exe; mutate ])
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out)

(* [probe_jobs] reaches two mutants, so on one CPU 16 jobs give two
   children for each CPU. The probe runs alone before them, and its
   deadline, about one second, is that of one job. A probe deadline
   multiplied by the two children for each CPU would take one second
   more. *)
let probe_alone () =
  let taskset = one_cpu () in
  let refused n =
    let marker = Filename.concat (temp_dir ()) "marker" in
    let began = Unix.gettimeofday () in
    let r =
      finish_within ~seconds:30. ~what:"the probe's deadline on one CPU"
        (start ~exe:taskset
           ~env:[ suite "probe_jobs"; ("MUTATE_PROBE_MARKER", marker) ]
           [ "-c"; "0"; suite_exe; mutate; jobs n ])
    in
    equal string "exited 1" r.status;
    contains ~sub:"the determinism probe exceeded its deadline" r.err;
    Unix.gettimeofday () -. began
  in
  let one = refused 1 in
  less float_exact ~than:(one +. 0.5) (refused 16)

(* [starve fixture] runs [fixture] on one CPU beside 4 processes that use
   it and never stop. Thus its probe and its child wait for the CPU 4 times
   as long as they use it, and end after about 2 seconds, past their
   deadlines of about 1.5 seconds for the children. The probe keeps a
   deadline of about 1 second. The time that a child waits for a CPU does
   not count, so the probe agrees and the mutant survives.

   With [~two:true], the fixture and the hogs run on two CPUs. [env] goes
   to the fixture and to the hogs. *)
let starve ?(two = false) ?(env = []) fixture test_name =
  if not (Sys.file_exists "/proc/self/schedstat") then
    skip ~reason:"the system does not give the time that a process waits" ();
  let taskset, cpus = if two then (two_cpus (), "0,1") else (one_cpu (), "0") in
  let hogs =
    List.init 4 (fun _ ->
        Unix.create_process_env taskset
          [| taskset; "-c"; cpus; suite_exe |]
          (Child.environment (suite "hog" :: env))
          Unix.stdin Unix.stdout Unix.stderr)
  in
  let stop pid =
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    ignore (Unix.waitpid [] pid)
  in
  let r =
    Fun.protect ~finally:(fun () -> List.iter stop hogs) @@ fun () ->
    finish_within ~seconds:30. ~what:"the starved probe and child"
      (start ~exe:taskset ~env:(suite fixture :: env)
         [ "-c"; cpus; suite_exe; mutate; "--mutate-retry=0" ])
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 survived by starved \u{203a} " ^ test_name;
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

let starved () =
  starve "starved" "uses the CPU where it is re-run and pins nothing about sub"

(* In [spawning], a subprocess of the probe and of the child uses the CPU,
   and their main threads only wait for it. The wait of a thread of a
   process in the group of a child also does not count. *)
let spawning () =
  starve "spawning"
    "waits for a process that uses the CPU and pins nothing about sub"

(* In [burn_then_sleep], the deadline is about 2.5 seconds. The subprocess
   of the child waits for the CPU 4 times as long as it uses it, and ends
   after about 3.5 seconds. Then the child sleeps 0.9 seconds, and ends
   after about 4.4 seconds. The loop keeps the wait of the subprocess from
   its last read, and loses the wait after that read. The loop reads at
   least every 0.1 seconds, so it loses little of the wait. A loop that
   read again only when the wait of its last read was used up read at 2.5
   seconds and next at about 4 seconds. It lost about 1 second of wait and
   killed the child in its sleep. But the load of the machine moves these
   reads and the end of the subprocess, and that loop also passed this test
   in 1 of 4 runs. [looks] is the test that always finds that loop. *)
let burnt_then_slept () =
  starve "burn_then_sleep"
    "waits for a process that uses the CPU, then sleeps, and pins nothing \
     about sub"

(* In [late_burn], the subprocess starts after the loop read the group of
   the child. The loop keeps the pids that it found outside the group of
   each child, and it must not take a new pid for one of them. *)
let burnt_late () =
  starve "late_burn"
    "uses the CPU, then waits for a process that uses the CPU, and pins \
     nothing about sub"

(* In [starved_domains], the test of the armed child uses 5 seconds of CPU
   time on two domains, beside 4 hogs on the same two CPUs. Its deadline is
   about 3.5 seconds. Thus the child uses more CPU time than the deadline of
   one CPU. But the dry run measured about two CPUs for the test. Thus the
   wait of the child does not count toward its deadline until the child
   used about twice the CPU time of its deadline. The hogs use the CPU only
   after the test of the dry run, so that the dry run measures two CPUs. *)
let starved_on_two_cpus () =
  let gate = Filename.concat (temp_dir ()) "gate" in
  starve ~two:true
    ~env:[ ("MUTATE_HOG_GATE", gate) ]
    "starved_domains"
    "uses the CPU on two domains where it is armed and pins nothing about sub";
  is_true (Sys.file_exists gate)

(* In [wide_rendezvous], each child ends with a test that uses two CPUs. On
   two CPUs, two jobs let one child run at a time, so the first child waits
   until its deadline kills it. Four jobs let the two children run at once,
   and they meet. In [narrow_rendezvous], each test uses one CPU, and two
   jobs let the two children run at once. *)
let jobs_of_two_cpus () =
  let taskset = two_cpus () in
  let run fixture n =
    let dir = temp_dir () in
    spawn ~exe:taskset
      ~env:[ suite fixture; ("MUTATE_RENDEZVOUS", dir) ]
      [ "-c"; "0,1"; suite_exe; mutate; jobs n ]
  in
  let two = run "wide_rendezvous" 2
  and four = run "wide_rendezvous" 4
  and narrow = run "narrow_rendezvous" 2 in
  List.iter
    (fun r -> equal (pair string text) ("exited 0", "") (r.status, r.err))
    [ two; four; narrow ];
  equal string
    "mutants: 1 survived of 2 reached by this suite, 1 killed, 2 never \
     reached, 1 filtered, score 50.0%"
    (outcome two.out);
  equal string
    "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, score 0.0%"
    (outcome four.out);
  equal string
    "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, score 0.0%"
    (outcome narrow.out)

(* [next_look] is the decision of the loop at each look at a child. Past
   the deadline, the next look comes after 0.1 seconds at the latest, also
   when the wait moves the deadline more. A loop that looked again only at
   the new deadline gives [(1.5, 1.5)] for the second case. *)
let looks () =
  let look = Private.Mutate_loop.next_look in
  let seconds = pair float_exact float_exact in
  let no_read () = failwith "the wait was read before the deadline" in
  equal seconds (1.5, 1.5) (look ~left:1.5 ~waited:no_read);
  equal seconds (0.0625, 0.0625) (look ~left:0. ~waited:(fun () -> 0.0625));
  equal seconds (1.5, 0.1) (look ~left:(-0.5) ~waited:(fun () -> 2.0));
  equal seconds (0.0625, 0.0625) (look ~left:(-0.5) ~waited:(fun () -> 0.5625));
  equal seconds (-0.25, -0.25) (look ~left:(-0.5) ~waited:(fun () -> 0.25))

(* The formula of the deadline of a child. The values are dyadic, so the
   sums and the products are exact. *)
let deadline_formula (_, share, fixed, startup, scheduled, expected) =
  equal float_exact expected
    (Private.Mutate_loop.deadline ~share ~fixed ~startup ~scheduled)

(* The rows of the sites that [slow_release], [slow_acquire], [slow_order]
   and [warm_up] do not reach, after the row of [sub]. The tests of these
   suites use this list, thus a change to one of the suites can change it. *)
let other_rows =
  [
    "subject.ml:18 unreached";
    "subject.ml:21 unreached";
    "subject.ml:27 unreached";
    "subject.ml:38 filtered: zero operand";
  ]

let one_survivor =
  "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
   filtered, score 0.0%"

(* The slow test of [beside_slow] sleeps 3 seconds in the dry run only. The
   child of the mutant runs the fast test, which writes the time before it
   blocks. With a deadline of the time of the dry run, the child ends more
   than 4 seconds after that time. With the minimum deadline of 1.5
   seconds, it ends near 1.5 seconds. *)
let hang_beside_slow () =
  let stamp = Filename.concat (temp_dir ()) "stamp" in
  let r =
    finish_within ~what:"the deadline of a hang beside a slow test"
      (start
         ~env:[ suite "beside_slow"; ("MUTATE_HANG_STAMP", stamp) ]
         [ mutate ])
  in
  let hung =
    Unix.gettimeofday () -. float_of_string (String.trim (read stamp))
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  at_least float_exact ~than:1.0 hung;
  less float_exact ~than:3.0 hung

(* The fixture of [slow_release] takes 2 seconds to release. The probe
   releases it again, and the time is outside the tests that the probe
   runs. A probe deadline of 1.5 seconds refuses the suite. *)
let probe_slow_release () =
  let r = spawn ~env:[ suite "slow_release" ] [ mutate ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string one_survivor (outcome r.out);
  equal
    (option (list string))
    (Some
       ("subject.ml:15 survived by slow_release \u{203a} watches sub without \
         pinning it" :: other_rows))
    (rows r)

(* The child of the mutant of [sub] runs the second test of [slow_acquire]
   only. It acquires the fixture again (1 second) and releases it
   (1 second), outside the time that the dry run measured for that test. *)
let child_slow_fixture () =
  let r =
    finish_within ~what:"a child with a slow fixture"
      (start ~env:[ suite "slow_acquire" ] [ mutate ])
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string one_survivor (outcome r.out);
  equal
    (option (list string))
    (Some
       ("subject.ml:15 survived by slow_acquire \u{203a} uses the fixture and \
         watches sub" :: other_rows))
    (rows r)

let limits =
  group "Limits"
    [
      test
        "children that outnumber the CPUs get deadlines longer by the children \
         for each CPU"
        on_one_cpu;
      test
        "children that outnumber the CPUs and use the CPU get the CPU time of \
         the deadline of one job"
        spinning_on_one_cpu;
      test
        "processes of a child that wait for one CPU at the same time do not \
         keep the child past its deadline"
        flooded_on_one_cpu;
      cases
        "the runaway budget is eight evaluations per measured one, plus 1000"
        ~name:(fun (k, over) -> strf "%d measured, budget %+d" k over)
        [ (5, 0); (5, 1); (50, 0); (50, 1) ]
        budget;
      cases
        "the deadline of a child is its fixed time plus ten times its startup \
         and its tests, at least one second for the tests, times the share"
        ~name:(fun (name, _, _, _, _, _) -> name)
        [
          ("the minimum of one job", 1., 0.5, 0., 0., 1.5);
          ("a short test keeps the minimum", 1., 0.5, 0., 0.0625, 1.5);
          ("ten times the tests", 1., 0.5, 0., 0.25, 3.0);
          ("ten times the startup", 1., 0.5, 0.125, 0., 2.75);
          ("two children for each CPU", 2., 0.5, 0., 0., 3.0);
          ("the fixtures of the dry run", 1., 2.5, 0., 0.0625, 3.5);
          ("the probe has the dry run", 1., 4., 0., 0.25, 6.5);
        ]
        deadline_formula;
      test
        "a mutant that hangs a fast test beside a slow test is killed at the \
         minimum deadline, not after the time of the suite"
        hang_beside_slow;
      test
        "the probe's deadline has the time of the dry run, so a slow fixture \
         release does not refuse the suite"
        probe_slow_release;
      test
        "a child that acquires and releases a slow fixture of another test is \
         not killed at its deadline"
        child_slow_fixture;
      test "a mutant that never terminates is killed by its hit budget" runaway;
      test "a mutant that blocks is killed by its child's deadline"
        deadline_kill;
      test
        "a child that writes to its verdict pipe and never stops is killed by \
         its deadline, and does not fill the memory of the loop"
        flooded;
      test ~timeout:5.
        "the loop reads a pipe that never empties a limited number of times, \
         and keeps 64 KiB of it"
        never_empty;
      test "the loop reads a full pipe of a child that ended to its end at once"
        full_pipe;
      test "a child's deadline is at least 1.5 seconds" (fun () ->
          let b = Lazy.force blocked in
          equal string "exited 0" b.run.status;
          at_least float_exact ~than:1.5 b.elapsed);
      test "an expired child's process group dies whole" (fun () ->
          let b = Lazy.force blocked in
          equal int 1 (List.length b.grandchildren);
          equal (list string) [ "gone" ] (List.map fate b.grandchildren));
      test "a slow but finite test is never killed by the clock" slow;
      test "a probe past its deadline is refused as non-determinism"
        probe_deadline;
      test
        "the probe's deadline is that of one job, whatever the children for \
         each CPU"
        probe_alone;
      test
        "the time that a child waits for a CPU does not count toward its \
         deadline"
        starved;
      test
        "the time that a child on two domains waits for a CPU does not count \
         toward its deadline"
        starved_on_two_cpus;
      test
        "the time that a subprocess of a child waits for a CPU does not count \
         toward the deadline of the child"
        spawning;
      test
        "the wait of a subprocess that ends between two reads of its wait does \
         not count toward the deadline of the child"
        burnt_then_slept;
      test
        "the time that a subprocess that starts after the first read of the \
         group waits for a CPU does not count toward the deadline of the child"
        burnt_late;
      test
        "past its deadline, the loop looks at a child again after 0.1 seconds \
         at the latest"
        looks;
    ]

(* The verdict file *)

let written () =
  let r = Lazy.force green in
  let f = require_some r.file in
  let writer = Option.map identity (Verdicts.writer_identity ~exe:suite_exe) in
  equal text "" r.err;
  equal (option (pair string string)) writer f.identity;
  equal (list string) green_rows f.rows

(* The selection reaches only [sub], whose mutant dies, so its records
   would call [widen] unreached over the whole run's survivor. *)
let narrowed () =
  let whole = require_some (Lazy.force green).file in
  let path = verdict_path suite_exe in
  write path whole.raw;
  let r = Child.run ~env:(quiet []) suite_exe [ mutate; "-f"; "calc" ] in
  equal string "exited 0" (ended r.Child.status);
  equal string
    "mutants: 1 reached by the 3 selected tests, 1 killed, 3 never reached, 1 \
     filtered, score 100.0%"
    (outcome r.Child.out);
  equal (option string) None (reproduce r.Child.out);
  equal text not_saved r.Child.err;
  equal text whole.raw (read path)

(* A record of a file outside the scope, as a run under another prefix of
   this build would have left it. *)
let elsewhere =
  {
    Verdicts.id =
      { Mutate.file = "elsewhere/other.ml"; line = 1; col = 0; rewrite = "add" };
    before = "a - b";
    after = "a + b";
    source_digest = Some (String.make 32 'c');
    verdict = Verdicts.Killed { by = None };
    previous = Some (Verdicts.survived [ [ "g"; "t" ] ]);
  }

let rerun_over_ran ?identity ?suite collection =
  let path = verdict_path suite_exe in
  Verdicts.save ?identity ?suite path (Verdicts.add collection elsewhere);
  let r = rerun [ mutate ] in
  equal string "exited 0" r.status;
  equal text "" r.err;
  r

let rerun_over ?identity ?suite collection =
  rows (rerun_over_ran ?identity ?suite collection)

let kept_by_build () =
  let whole = require_some (Lazy.force green).file in
  let path = verdict_path suite_exe in
  write path whole.raw;
  let collection, identity, suite =
    require_ok ~pp:Verdicts.pp_error (Verdicts.load path)
  in
  let other_build =
    Option.map
      (fun (i : Verdicts.identity) -> { i with digest = String.make 32 '0' })
      identity
  in
  let r = rerun_over_ran ?identity ?suite collection in
  equal
    (option (list string))
    (Some ("elsewhere/other.ml:1 killed" :: green_rows))
    (rows r);
  (* The planted record has a stale previous verdict, a change in the planted
     file. The run gives the record its own verdict as its previous verdict,
     so the change does not stay in the file. *)
  equal (list string)
    [ "elsewhere/other.ml:1 killed" ]
    (List.filter
       (String.starts_with ~prefix:"elsewhere/")
       (require_some (previous_rows r)));
  equal (option (list string)) None (unstable r.out);
  equal
    (option (list string))
    (Some green_rows)
    (rerun_over ?identity:other_build ?suite collection);
  equal (option (list string)) (Some green_rows) (rerun_over ?suite collection);
  equal
    (option (list string))
    (Some green_rows)
    (rerun_over ?identity ~suite:"first" collection)

let failed_run () =
  let log = temp_dir () in
  let first = spawn ~env:[ suite "flip"; ("MUTATE_FLIP", "1") ] [ "-o"; log ] in
  let r = spawn ~env:[ suite "flip" ] [ mutate; "--failed"; "-o"; log ] in
  equal string "exited 1" first.status;
  equal string "exited 0" r.status;
  contains ~sub:"reached by the 1 selected test" (outcome r.out);
  equal text not_saved r.err

(* A copy of the suite in [root/_build/default], which is a scratch build
   directory. *)
let copied_suite root =
  let build = Filename.concat root "_build" in
  let exe = Filename.concat build "default/suite_main.exe" in
  Sys.mkdir build 0o755;
  Sys.mkdir (Filename.dirname exe) 0o755;
  write exe (read suite_exe);
  Unix.chmod exe 0o755;
  exe

(* A copy of the suite under a scratch build directory whose _mutants is a
   file. *)
let unwritable () =
  let root = temp_dir () in
  let exe = copied_suite root in
  write (Filename.concat root "_build/_mutants") "a file\n";
  let r = spawn ~exe ~env:[ suite "weak" ] [ mutate ] in
  equal string "exited 0" r.status;
  equal string
    "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out);
  starts_with ~affix:"windtrap: could not write the verdict file: " r.err;
  equal int 1 (List.length (lines (String.trim r.err)))

(* scoped_main links subject.ml and quiet.ml, whose only site is
   filtered. A scope of subject.ml leaves the filtered mutant of quiet.ml
   out, as it leaves out the other mutants of quiet.ml. *)
let filtered_in_scope () =
  let subject_rows =
    [
      "subject.ml:15 killed";
      "subject.ml:18 unreached";
      "subject.ml:21 unreached";
      "subject.ml:27 unreached";
      "subject.ml:38 filtered: zero operand";
    ]
  in
  let whole = spawn ~exe:scoped_exe [ mutate ] in
  let one = spawn ~exe:scoped_exe [ "--mutate=" ^ scope ^ "subject.ml" ] in
  equal (pair string text) ("exited 0", "") (whole.status, whole.err);
  equal
    (option (list string))
    (Some ("scoped/quiet.ml:8 filtered: zero operand" :: subject_rows))
    (rows whole);
  equal (pair string text) ("exited 0", "") (one.status, one.err);
  equal (option (list string)) (Some subject_rows) (rows one);
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome one.out)

(* The killing test of each killed record of the file at [path], by the
   file under the scope and the line. *)
let killers path =
  match Verdicts.load path with
  | Error _ -> []
  | Ok (t, _, _) ->
      List.filter_map
        (fun (r : Verdicts.record) ->
          match r.verdict with
          | Verdicts.Killed { by = Some test } ->
              Some
                (strf "%s:%d %s" (local r.id.file) r.id.line
                   (String.concat " \u{203a} " test))
          | Verdicts.Killed { by = None }
          | Verdicts.Killed_elsewhere _ | Verdicts.Flaky _ | Verdicts.Survived _
          | Verdicts.Not_evaluated | Verdicts.Outside_tests
          | Verdicts.Filtered _ | Verdicts.Unreached ->
              None)
        (Verdicts.records t)

(* The verdict file of [suite_main.exe] with [change] applied to each
   record, written by the same suite and, without [digest], the same build.
   With [suite], the file records that suite in place of its own. *)
let rewrite ?digest ?suite:renamed change =
  let path = verdict_path suite_exe in
  let t, identity, suite =
    require_ok ~pp:Verdicts.pp_error (Verdicts.load path)
  in
  let suite = match renamed with None -> suite | Some _ -> renamed in
  let identity =
    match digest with
    | None -> identity
    | Some digest ->
        Option.map (fun (i : Verdicts.identity) -> { i with digest }) identity
  in
  Verdicts.save ?identity ?suite path
    (List.fold_left Verdicts.add Verdicts.empty
       (List.map change (Verdicts.records t)))

(* A run of [fixture] that keeps the verdict file: its outcome, and the
   words of the tests that the children ran with a mutant armed. *)
let ordered_run ?(fixture = "ordered") ?(env = []) () =
  let ran = Filename.concat (temp_dir ()) "ran" in
  let r =
    Child.run
      ~env:(quiet ([ suite fixture; ("MUTATE_RAN", ran) ] @ env))
      suite_exe [ mutate ]
  in
  equal string "exited 0" (ended r.Child.status);
  equal text "" r.Child.err;
  (outcome r.Child.out, List.filter (( <> ) "") (lines (read ran)))

let ordered_outcome =
  "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
   score 100.0%"

let pinned_by = "subject.ml:15 ordered \u{203a} pins sub"

let first_tests_with env () =
  let path = verdict_path suite_exe in
  remove path;
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ~env ());
  equal (list string) [ pinned_by ] (killers path);
  equal
    (pair string (list string))
    (ordered_outcome, [ "pins" ])
    (ordered_run ~env ());
  equal (list string) [ pinned_by ] (killers path)

let first_tests = first_tests_with []

let changed_source () =
  let path = verdict_path suite_exe in
  remove path;
  ignore (ordered_run ());
  rewrite (fun r -> { r with source_digest = Some (String.make 32 '0') });
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

let flaky_record () =
  let path = verdict_path suite_exe in
  remove path;
  ignore (ordered_run ());
  rewrite (fun r ->
      if r.id = site_id 15 then
        {
          r with
          verdict =
            Verdicts.Flaky { test = [ "ordered"; "pins sub" ]; failure = "x" };
        }
      else r);
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

(* The record [r] with [test] as its killing test, when it is killed. *)
let killed_by test (r : Verdicts.record) =
  match r.verdict with
  | Verdicts.Killed _ -> { r with verdict = Verdicts.Killed { by = Some test } }
  | Verdicts.Killed_elsewhere _ | Verdicts.Flaky _ | Verdicts.Survived _
  | Verdicts.Not_evaluated | Verdicts.Outside_tests | Verdicts.Filtered _
  | Verdicts.Unreached ->
      r

let first_test_passes () =
  let path = verdict_path suite_exe in
  remove path;
  ignore (ordered_run ());
  rewrite (killed_by [ "ordered"; "watches sub again without pinning it" ]);
  equal
    (pair string (list string))
    (ordered_outcome, [ "again"; "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

(* The killing test was renamed: no test of the suite has its path. *)
let renamed_killer () =
  let path = verdict_path suite_exe in
  remove path;
  ignore (ordered_run ());
  rewrite (killed_by [ "ordered"; "pinned sub" ]);
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

let not_evaluated_first () =
  let path = verdict_path suite_exe in
  let primed = ordered_run ~fixture:"primed" in
  let pinned = "subject.ml:18 primed \u{203a} pins widen once primed" in
  remove path;
  equal
    (pair string (list string))
    (ordered_outcome, [ "primes"; "pins" ])
    (primed ());
  equal (list string) [ pinned ] (killers path);
  equal
    (pair string (list string))
    (ordered_outcome, [ "primes"; "pins" ])
    (primed ());
  equal (list string) [ pinned ] (killers path)

(* The killing test of the first run fails alone with no mutant. The second
   run pins [sub] no more, and only a full child, which runs the first test
   before it, gives the verdict. *)
let failing_alone () =
  let path = verdict_path suite_exe in
  let flagged = ordered_run ~fixture:"flagged" in
  remove path;
  equal
    (pair string (list string))
    (ordered_outcome, [ "raises"; "needs" ])
    (flagged ());
  equal (list string)
    [ "subject.ml:15 flagged \u{203a} needs the flag" ]
    (killers path);
  equal
    (pair string (list string))
    ( "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
       filtered, score 0.0%",
      [ "raises"; "needs" ] )
    (flagged ~env:[ ("MUTATE_WEAK", "1") ] ())

(* A verdict file that does not load: [damage] gives its contents from those
   of a file that loads. *)
let unloadable damage () =
  let path = verdict_path suite_exe in
  remove path;
  ignore (ordered_run ());
  write path (damage (read path));
  (match Verdicts.load path with
  | Ok _ -> failf "the damaged verdict file loads"
  | Error _ -> ());
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path);
  equal
    (option (list string))
    (Some none_rows)
    (Option.map (fun (f : file) -> f.previous) (saved path))

let other_suite_history () =
  let path = verdict_path suite_exe in
  remove_suite_files suite_exe;
  ignore (ordered_run ());
  rewrite ~suite:"other" Fun.id;
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

let history =
  group "History"
    [
      test
        "a killed mutant names the test that failed first, and the next run \
         runs that test alone first"
        first_tests;
      test "a mutant whose source changed runs its reaching tests in order"
        changed_source;
      test "a flaky record gives no first child, and every reaching test runs"
        flaky_record;
      test
        "a first test that kills nothing is followed by every reaching test, \
         and the verdict is theirs"
        first_test_passes;
      test
        "a first test that no longer reaches the mutant is not run, and every \
         reaching test runs"
        renamed_killer;
      test
        "a first test that does not evaluate the mutant is followed by every \
         reaching test"
        not_evaluated_first;
      test
        "a first test that fails alone with no mutant gets no first child, and \
         every reaching test runs"
        failing_alone;
      test
        "a verdict file at the path of the suite that records another suite \
         gives no history"
        other_suite_history;
      cases
        "a verdict file that does not load gives no history, and the run \
         replaces it"
        ~name:fst
        [
          ("a file of 0.2.0", fun _ -> "windtrap-mutants-v3\n");
          ("a file of the previous format", fun _ -> "windtrap-mutants-v9\n0\n");
          ("bytes after the last record", fun raw -> raw ^ "junk\n");
        ]
        (fun (_, damage) -> unloadable damage ());
    ]

let recorded_suite path =
  match Verdicts.load path with Ok (_, _, suite) -> suite | Error _ -> None

(* The rows of a suite that kills [sub] alone. *)
let first_rows =
  [
    "subject.ml:15 killed";
    "subject.ml:18 unreached";
    "subject.ml:21 unreached";
    "subject.ml:27 unreached";
    "subject.ml:38 filtered: zero operand";
  ]

let two_reach_rows =
  [
    "subject.ml:15 survived by flagged \u{203a} needs the flag, flagged \
     \u{203a} raises the flag";
    "subject.ml:18 unreached";
    "subject.ml:21 unreached";
    "subject.ml:27 unreached";
    "subject.ml:38 filtered: zero operand";
  ]

let one_file_for_each_suite () =
  let r = spawn ~env:[ suite "two_reach"; weak ] [ mutate ] in
  let first = verdict_path ~suite:"first" suite_exe
  and calc = verdict_path ~suite:"calc" suite_exe in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string)
    (List.sort String.compare [ first; calc ])
    (suite_files suite_exe);
  equal (option string) (Some "first") (recorded_suite first);
  equal (option string) (Some "calc") (recorded_suite calc);
  equal
    (option (list string))
    (Some first_rows)
    (Option.map (fun (f : file) -> f.rows) (saved first));
  equal
    (option (list string))
    (Some two_reach_rows)
    (Option.map (fun (f : file) -> f.rows) (saved calc));
  equal bool false
    (Sys.file_exists (Instr.output_file Verdicts.format ~exe:suite_exe))

(* A file at the name of the earlier version is not read, and no run
   replaces it. *)
let earlier_name () =
  let first = spawn [ mutate ] in
  equal (pair string text) ("exited 0", "") (first.status, first.err);
  let calc = verdict_path suite_exe
  and old = Instr.output_file Verdicts.format ~exe:suite_exe in
  let t, identity, suite =
    require_ok ~pp:Verdicts.pp_error (Verdicts.load calc)
  in
  let changed =
    List.fold_left
      (fun t (r : Verdicts.record) ->
        Verdicts.add t
          (if r.id.line = 15 then
             {
               r with
               verdict =
                 Verdicts.survived [ [ "calc"; "sub of two positives" ] ];
             }
           else r))
      Verdicts.empty (Verdicts.records t)
  in
  Fun.protect
    ~finally:(fun () -> remove old)
    (fun () ->
      Verdicts.save ?identity ?suite old changed;
      let planted = read old in
      remove calc;
      let r = rerun [ mutate ] in
      equal (pair string text) ("exited 0", "") (r.status, r.err);
      equal (option (list string)) None (unstable r.out);
      equal (option (list string)) (Some none_rows) (previous_rows r);
      equal text planted (read old))

let verdict_file =
  group "The verdict file"
    [
      test "a main with two suites writes one verdict file for each suite"
        one_file_for_each_suite;
      test
        "a verdict file at the name of the earlier version is not read and not \
         replaced"
        earlier_name;
      test "a scope records the filtered mutants of its files alone"
        filtered_in_scope;
      test
        "a loop that ran whole under a scope writes its file, with its writer"
        written;
      test "a narrowed run reports in full, says so, and leaves the file"
        narrowed;
      test "a scoped run keeps the other files' records only from its own build"
        kept_by_build;
      cases "every narrowing of the suite writes no verdict file"
        ~name:(String.concat " ")
        [
          [ "-e"; "nothing-matches" ];
          [ "--exclude-tag"; "nothing" ];
          [ "--shard"; "1/1" ];
        ]
        (fun flags ->
          let r = spawn ~env:[ suite "weak" ] (mutate :: flags) in
          equal (pair string text) ("exited 0", not_saved) (r.status, r.err);
          equal (option (list string)) None (rows r));
      test "a --failed run writes no verdict file" failed_run;
      test "a run with an active focus writes no verdict file" (fun () ->
          let r = spawn ~env:[ suite "focused" ] [ mutate ] in
          equal string "exited 0" r.status;
          contains ~sub:"reached by the 1 selected test" (outcome r.out);
          equal text not_saved r.err);
      test "a file that cannot be written is one sentence, and exit 0"
        unwritable;
    ]

(* What the environment asks *)

let empty_selection () =
  let mirrored =
    spawn
      ~env:[ ("WINDTRAP_MUTATE", "1"); ("WINDTRAP_FILTER", "no-such-test") ]
      []
  in
  let typed =
    spawn ~env:[ ("WINDTRAP_MUTATE", "1") ] [ "-f"; "no-such-test" ]
  in
  equal string "exited 0" mirrored.status;
  contains ~sub:"no tests ran: filter" mirrored.out;
  equal text "" mirrored.err;
  equal (pair string text) ("exited 2", "") (typed.status, typed.err)

let git =
  List.find_map
    (fun dir ->
      let path = Filename.concat dir "git" in
      if dir <> "" && Sys.file_exists path then Some path else None)
    (String.split_on_char ':'
       (Option.value ~default:"" (Sys.getenv_opt "PATH")))

(* A new git repository in a temporary directory, and a function that runs
   git in it. *)
let repository () =
  let git =
    match git with
    | None -> skip ~reason:"git is not on PATH" ()
    | Some git -> git
  in
  let root = temp_dir () in
  let run_git args =
    let r =
      Child.run ~cwd:root
        ~env:[ ("HOME", root); ("GIT_CONFIG_NOSYSTEM", "1") ]
        git
        ([ "-c"; "user.name=windtrap"; "-c"; "user.email=windtrap@example.com" ]
        @ args)
    in
    equal (pair string text) ("exited 0", "") (ended r.Child.status, r.Child.err)
  in
  run_git [ "init"; "-q" ];
  (root, run_git)

(* The directory [path] under [root], with each directory that it needs. *)
let directory root path =
  List.fold_left
    (fun dir name ->
      let dir = Filename.concat dir name in
      if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
      dir)
    root
    (List.filter (( <> ) "") (String.split_on_char '/' path))

(* The project root is a new git repository, and quiet.ml is a file of it
   that git does not track, so each of its lines changed since HEAD. Its
   one mutant is filtered, so the run has nothing to test. It writes the
   verdict file with the filtered mutant, as a loop does. *)
let filtered_since () =
  let root, run_git = repository () in
  run_git [ "commit"; "-q"; "--allow-empty"; "-m"; "empty" ];
  let dir = directory root (scope ^ "scoped") in
  write (Filename.concat dir "quiet.ml") "(* Each line changed. *)\n";
  let r =
    spawn ~exe:scoped_exe
      ~env:
        [
          ("WINDTRAP_PROJECT_ROOT", root);
          ("WINDTRAP_MUTATE", scope ^ "scoped/");
          ("WINDTRAP_MUTATE_SINCE", "HEAD");
        ]
      []
  in
  equal (pair string string)
    ("exited 0", "scoped: 2 passed in <time>.")
    (r.status, masked (String.trim r.out));
  equal text
    "windtrap: WINDTRAP_MUTATE is set, but every mutant this run could test is \
     dismissed by [@mutate off] or filtered by the rewriter, so the suite runs \
     without mutation\n"
    r.err;
  equal
    (option (list string))
    (Some [ "scoped/quiet.ml:8 filtered: zero operand" ]) (rows r)

(* A project root where git tracks subject.ml with 40 lines, and where the
   lines of [changed] are different from the commit. The filtered site of
   subject.ml is on line 38, and the killed site is on line 15. *)
let changed_subject changed =
  let root, run_git = repository () in
  let path = Filename.concat (directory root scope) "subject.ml" in
  let lines mark =
    String.concat ""
      (List.init 40 (fun i -> strf "(* line %d%s *)\n" (i + 1) (mark (i + 1))))
  in
  write path (lines (fun _ -> ""));
  run_git [ "add"; "." ];
  run_git [ "commit"; "-q"; "-m"; "subject" ];
  write path (lines (fun n -> if List.mem n changed then ", changed" else ""));
  root

let subject_scope = scope ^ "subject.ml"

(* A loop under --mutate-since records a filtered mutant only when its line
   changed. *)
let filtered_on_changed_line () =
  let run changed =
    spawn ~exe:scoped_exe
      ~env:[ ("WINDTRAP_PROJECT_ROOT", changed_subject changed) ]
      [ "--mutate=" ^ subject_scope; "--mutate-since=HEAD" ]
  in
  let other = run [ 15 ] and both = run [ 15; 38 ] in
  equal (pair string text) ("exited 0", "") (other.status, other.err);
  equal (option (list string)) (Some [ "subject.ml:15 killed" ]) (rows other);
  equal string "mutants: 1 reached by this suite, 1 killed, score 100.0%"
    (outcome other.out);
  equal (pair string text) ("exited 0", "") (both.status, both.err);
  equal
    (option (list string))
    (Some [ "subject.ml:15 killed"; "subject.ml:38 filtered: zero operand" ])
    (rows both);
  equal string
    "mutants: 1 reached by this suite, 1 killed, 1 filtered, score 100.0%"
    (outcome both.out)

(* A run that has no mutant to test under WINDTRAP_MUTATE_SINCE records a
   filtered mutant only when its line changed. *)
let filtered_unmutated_on_changed_line () =
  let run changed =
    spawn ~exe:scoped_exe
      ~env:
        [
          ("WINDTRAP_PROJECT_ROOT", changed_subject changed);
          ("WINDTRAP_MUTATE", subject_scope);
          ("WINDTRAP_MUTATE_SINCE", "HEAD");
        ]
      []
  in
  let other = run [ 1 ] and both = run [ 1; 38 ] in
  equal string "exited 0" other.status;
  equal text
    (strf
       "windtrap: WINDTRAP_MUTATE is set, but no mutant of this executable's \
        catalogue under %s is on a line that changed since HEAD, so the suite \
        runs without mutation\n"
       subject_scope)
    other.err;
  equal (option (list string)) (Some []) (rows other);
  equal string "exited 0" both.status;
  equal text
    "windtrap: WINDTRAP_MUTATE is set, but every mutant this run could test is \
     dismissed by [@mutate off] or filtered by the rewriter, so the suite runs \
     without mutation\n"
    both.err;
  equal
    (option (list string))
    (Some [ "subject.ml:38 filtered: zero operand" ]) (rows both)

let environment =
  group "What the environment asks"
    [
      test "WINDTRAP_MUTATE over a selection that keeps no test runs the suite"
        empty_selection;
      test
        "WINDTRAP_MUTATE_SINCE where every changed mutant is filtered writes \
         the filtered mutants"
        filtered_since;
      test
        "WINDTRAP_MUTATE_SINCE writes a filtered mutant only when its line \
         changed"
        filtered_unmutated_on_changed_line;
      test "--mutate-since records a filtered mutant only when its line changed"
        filtered_on_changed_line;
      test "WINDTRAP_MUTATE with no mutant in its scope runs the suite"
        (fun () ->
          let r =
            spawn ~exe:plain_exe ~env:[ ("WINDTRAP_MUTATE", "perhaps") ] []
          in
          equal (pair string string)
            ("exited 0", "plain: 1 passed in <time>.")
            (r.status, masked (String.trim r.out));
          equal text
            "windtrap: WINDTRAP_MUTATE is set, but no mutant of this \
             executable's catalogue is under perhaps, so the suite runs \
             without mutation\n"
            r.err);
      test "WINDTRAP_MUTATE where every mutant is filtered runs the suite"
        (fun () ->
          let r =
            spawn ~exe:scoped_exe
              ~env:[ ("WINDTRAP_MUTATE", scope ^ "scoped/") ]
              []
          in
          equal (pair string string)
            ("exited 0", "scoped: 2 passed in <time>.")
            (r.status, masked (String.trim r.out));
          equal text
            "windtrap: WINDTRAP_MUTATE is set, but every mutant this run could \
             test is dismissed by [@mutate off] or filtered by the rewriter, \
             so the suite runs without mutation\n"
            r.err;
          equal (option (list string)) None (rows r));
      test "WINDTRAP_MUTATE on a build with no mutants names the backend"
        (fun () ->
          if core_instrumented then
            skip
              ~reason:
                "under --instrument-with the core is instrumented, so \
                 plain_main catalogues its mutants"
              ();
          let r = spawn ~exe:plain_exe ~env:[ ("WINDTRAP_MUTATE", "1") ] [] in
          equal (pair string string)
            ("exited 0", "plain: 1 passed in <time>.")
            (r.status, masked (String.trim r.out));
          equal text
            "windtrap: WINDTRAP_MUTATE is set, but this executable links no \
             instrumented module, so the suite runs without mutation\n"
            r.err);
      (* dune runtest gives the two variables to every suite. Git refuses a
         revision that names no commit, so a run that asked git would stop
         with exit code 1. *)
      test "WINDTRAP_MUTATE_SINCE on a build with no mutants runs no git"
        (fun () ->
          if core_instrumented then
            skip
              ~reason:
                "under --instrument-with the core is instrumented, so \
                 plain_main catalogues its mutants"
              ();
          let r =
            spawn ~exe:plain_exe
              ~env:
                [
                  ("WINDTRAP_MUTATE", "1");
                  ("WINDTRAP_MUTATE_SINCE", "no-such-revision");
                ]
              []
          in
          equal (pair string string)
            ("exited 0", "plain: 1 passed in <time>.")
            (r.status, masked (String.trim r.out));
          equal text
            "windtrap: WINDTRAP_MUTATE is set, but this executable links no \
             instrumented module, so the suite runs without mutation\n"
            r.err);
    ]

(* Refusals *)

let empty_scope () =
  let r = spawn [ "--mutate=::no-such-source::" ] in
  equal string "exited 1" r.status;
  contains ~sub:"windtrap: --mutate=::no-such-source:: leaves no mutant" r.err;
  contains
    ~sub:
      "no instrumented file matches the prefix (is the library under test \
       instrumented with ppx_windtrap.mutate?), or the matched files have no \
       mutation sites"
    r.err;
  not_contains ~sub:"links no instrumented module" r.err

let in_order () =
  let red = spawn ~env:[ suite "red" ] [ "--mutate=::no-such-source::" ] in
  let nothing = spawn [ "--mutate=::no-such-source::"; "-f"; "no-such-test" ] in
  equal (pair string text)
    ( "exited 1",
      "windtrap: the dry run is red. Mutation scores a passing suite; a score \
       over a failing one is not a score\n" )
    (red.status, red.err);
  equal (pair string text)
    ("exited 1", "windtrap: no test ran, so there is nothing to mutate\n")
    (nothing.status, nothing.err)

let no_backend () =
  if core_instrumented then
    skip
      ~reason:
        "under --instrument-with the core is instrumented, so plain_main \
         catalogues its mutants"
      ();
  let r = spawn ~exe:plain_exe [ "--mutate" ] in
  equal string "exited 1" r.status;
  contains ~sub:"plain: 1 passed" r.out;
  contains ~sub:"links no instrumented module" r.err;
  contains ~sub:"instrument the library under test with ppx_windtrap.mutate"
    r.err;
  not_contains ~sub:"scope" r.err

let loud_scope () =
  let r = spawn ~exe:plain_exe [ "--mutate=perhaps" ] in
  equal string "exited 1" r.status;
  contains
    ~sub:
      "windtrap: --mutate=perhaps leaves no mutant in this executable's \
       catalogue"
    r.err;
  contains
    ~sub:"is the library under test instrumented with ppx_windtrap.mutate?"
    r.err;
  not_contains ~sub:"links no instrumented module" r.err

(* Requests *)

(* A request that a process of the suite executable writes, as the loop will
   do in exec mode. Thus the identity of the executable and the catalogue in
   the request are those of suite_main.exe. [paths] has "/" between the names
   of a path. *)
let request ?(suite_name = "calc") ~kind paths =
  let path = Filename.concat (temp_dir ()) "request" in
  let r =
    spawn
      ~env:
        [
          suite "request";
          ("MUTATE_REQUEST", path);
          ("MUTATE_REQUEST_KIND", kind);
          ("MUTATE_REQUEST_PATHS", String.concat "\n" paths);
          ("MUTATE_REQUEST_SUITE", suite_name);
        ]
      []
  in
  equal (pair string string) ("exited 0", "") (r.status, r.err);
  path

(* Serves the request at [path] in a new process of the suite executable, as
   the loop will start a child in exec mode: the path in
   WINDTRAP_MUTATE_CHILD, and the write end of the verdict pipe as the
   standard input. The result is the status, what the child wrote to the
   pipe, and the name of the pipe in /proc. *)
let serve ?(fixture = "green") ?(env = []) path =
  let reader, writer = Unix.pipe ~cloexec:true () in
  let pipe = strf "pipe:[%d]" (Unix.fstat reader).st_ino in
  let null = Unix.openfile Filename.null [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
  let pid =
    Fun.protect
      ~finally:(fun () -> List.iter Unix.close [ writer; null ])
      (fun () ->
        Unix.create_process_env suite_exe [| suite_exe |]
          (Child.environment
             (suite fixture :: ("WINDTRAP_MUTATE_CHILD", path) :: env))
          writer null null)
  in
  let line =
    Fun.protect
      ~finally:(fun () -> Unix.close reader)
      (fun () -> read_to_end reader)
  in
  let _, status = Unix.waitpid [] pid in
  (ended status, line, pipe)

let served ?fixture ?env path =
  let status, line, _ = serve ?fixture ?env path in
  (status, line)

(* Writes [text] in place of line [n] (from 1) of the header of a request. *)
let replace_line path n text =
  let contents = read path in
  let rec header n start =
    if n = 1 then start
    else header (n - 1) (String.index_from contents start '\n' + 1)
  in
  let start = header n 0 in
  let stop = String.index_from contents start '\n' in
  write path
    (String.sub contents 0 start
    ^ text
    ^ String.sub contents stop (String.length contents - stop))

let green_paths =
  [
    "calc/sub of two positives";
    "calc/sub to zero";
    "calc/sub of two negatives";
    "widen/widen is nonzero";
    "widen/widen is not 99";
    "dismissed/the dismissed site is run and not pinned";
    "dismissed/the filtered site is run and not pinned";
  ]

let changed = ("exited 0", "error the executable changed after the dry run\n")

let requests =
  group "Requests"
    [
      test "a probe request runs its tests with no mutant and gives the counts"
        (fun () ->
          equal (pair string string)
            ("exited 0", "probe 7 0 0\n")
            (served (request ~kind:"probe" green_paths)));
      test "a check request gives steady for a last test that passes" (fun () ->
          equal (pair string string) ("exited 0", "steady\n")
            (served (request ~kind:"check" [ "calc/sub to zero" ])));
      test "a check request gives flaky and the headline of the last test"
        (fun () ->
          equal (pair string string)
            ("exited 0", "flaky expected 1, got 2\n")
            (served ~fixture:"red"
               (request ~kind:"check" [ "calc/sub to zero"; "calc/always red" ])));
      test
        "a check request runs the last test after the failure of an earlier \
         test" (fun () ->
          let runs = Filename.concat (temp_dir ()) "runs" in
          let env fails =
            ("MUTATE_FIRST_FAILS", "1") :: ("MUTATE_CHILD_RUNS", runs) :: fails
          in
          let path =
            request ~kind:"check"
              [ "kill/reaches widen"; "kill/fails at the given child runs" ]
          in
          equal (pair string string)
            ("exited 0", "flaky child run 1\n")
            (served ~fixture:"flaky_kill"
               ~env:(env [ ("MUTATE_FAIL_AT", "1") ])
               path);
          equal (pair string string) ("exited 0", "steady\n")
            (served ~fixture:"flaky_kill" ~env:(env []) path));
      test "a mutant request arms its mutant, and a test that pins it kills it"
        (fun () ->
          equal (pair string string) ("exited 0", "killed 0\n")
            (served (request ~kind:(site 15) [ "calc/sub of two positives" ])));
      test "a mutant request gives a survivor when no test pins the mutant"
        (fun () ->
          equal (pair string string) ("exited 0", "survived\n")
            (served
               (request ~kind:(site 18)
                  [ "widen/widen is nonzero"; "widen/widen is not 99" ])));
      test "an alone request gives passes for a test that passes" (fun () ->
          equal (pair string string) ("exited 0", "passes\n")
            (served (request ~kind:"alone" [ "calc/sub to zero" ])));
      test "a request with a test that the process does not have is refused"
        (fun () ->
          equal (pair string string)
            ( "exited 0",
              "error the tests changed after the dry run: this process has no \
               test \"calc \u{203A} no such test\"\n" )
            (served (request ~kind:"alone" [ "calc/no such test" ])));
      test
        "a request for another suite runs no test, and the call returns for a \
         later call" (fun () ->
          let seen = Filename.concat (temp_dir ()) "seen" in
          equal (pair string string) ("exited 0", "")
            (served ~fixture:"child"
               ~env:[ ("MUTATE_SEEN", seen) ]
               (request ~suite_name:"other" ~kind:"alone"
                  [ "child/reads the request variable" ]));
          is_false (Sys.file_exists seen));
      test "a request from another executable file is refused" (fun () ->
          let path = request ~kind:"alone" [ "calc/sub to zero" ] in
          replace_line path 2 "0 0 0 0";
          equal (pair string string) changed (served path));
      test "a request from another catalogue is refused" (fun () ->
          let path = request ~kind:"alone" [ "calc/sub to zero" ] in
          replace_line path 3 (String.make 32 '0');
          equal (pair string string) changed (served path));
      test "a request that ends early is refused" (fun () ->
          let path = request ~kind:"alone" [ "calc/sub to zero" ] in
          let contents = read path in
          write path (String.sub contents 0 (String.length contents - 8));
          equal (pair string string)
            ("exited 0", "error the request file is not complete\n")
            (served path));
      test "a request that ends in its header is refused" (fun () ->
          let path = request ~kind:"alone" [ "calc/sub to zero" ] in
          write path "windtrap-mutate-request 1\n";
          equal (pair string string)
            ("exited 0", "error the request file is not complete\n")
            (served path));
      test "a request file that does not open is refused" (fun () ->
          let status, line =
            served (Filename.concat (temp_dir ()) "no-such-request")
          in
          equal string "exited 0" status;
          is_true
            (String.starts_with ~prefix:"error cannot read the request: " line));
      test "a child is the leader of a session of its own" (fun () ->
          equal (pair string string) ("exited 0", "passes\n")
            (served ~fixture:"child"
               (request ~kind:"alone" [ "child/is the leader of its session" ])));
      test "an empty request variable gives an ordinary run" (fun () ->
          let r = spawn ~env:[ ("WINDTRAP_MUTATE_CHILD", "") ] [] in
          equal (pair string string)
            ("exited 0", "calc: 7 passed in <time>.\n")
            (r.status, masked r.out));
      test
        "a subprocess of module initialization gets neither the verdict pipe \
         nor the request variable" (fun () ->
          let seen = Filename.concat (temp_dir ()) "seen" in
          let path = request ~kind:"alone" [ "calc/sub to zero" ] in
          let status, line, pipe =
            serve ~env:[ ("MUTATE_INIT_FDS", seen) ] path
          in
          equal (pair string string) ("exited 0", "passes\n") (status, line);
          not_contains ~sub:pipe (read seen);
          contains ~sub:" 0 -> /dev/null\n" (read seen);
          contains ~sub:"variable=unset\n" (read seen));
      test "a test in the child does not find the request variable" (fun () ->
          let seen = Filename.concat (temp_dir ()) "seen" in
          let path =
            request ~kind:"alone" [ "child/reads the request variable" ]
          in
          equal (pair string string) ("exited 0", "passes\n")
            (served ~fixture:"child" ~env:[ ("MUTATE_SEEN", seen) ] path);
          equal string "unset" (read seen));
      test
        "a subprocess of a test does not get the verdict pipe, and reads \
         /dev/null" (fun () ->
          let seen = Filename.concat (temp_dir ()) "seen" in
          let path =
            request ~kind:"alone"
              [ "child/lists the descriptors of a subprocess" ]
          in
          let status, line, pipe =
            serve ~fixture:"child" ~env:[ ("MUTATE_SEEN", seen) ] path
          in
          equal (pair string string) ("exited 0", "passes\n") (status, line);
          not_contains ~sub:pipe (read seen);
          contains ~sub:" 0 -> /dev/null\n" (read seen));
    ]

let refusals =
  group "Refusals"
    [
      test "a red dry run refuses to score anything" (fun () ->
          let r = spawn ~env:[ suite "red" ] [ mutate ] in
          equal string "exited 1" r.status;
          contains ~sub:"the dry run is red" r.err;
          not_contains ~sub:"mutants: " r.out);
      test "a selection that matched nothing is refused with 1, never 2"
        (fun () ->
          let r = spawn [ mutate; "-f"; "no-such-test" ] in
          equal string "exited 1" r.status;
          contains ~sub:"nothing to mutate" r.err;
          not_contains ~sub:"mutants: " r.out);
      test "a dry run refused at startup is exit 1, whatever its own code"
        (fun () ->
          let r =
            spawn
              ~env:[ suite "weak" ]
              [ mutate; "--failed"; "-o"; temp_dir () ]
          in
          equal string "exited 1" r.status;
          equal text "" r.out;
          equal text "windtrap: no recorded failures match the current suite\n"
            r.err);
      test "a scope that leaves no mutant is refused, naming the scope"
        empty_scope;
      test "the dry run's code is tried before the population" in_order;
      test "a build with no mutants asked to mutate names the backend"
        no_backend;
      test "a scope is refused by name even where there is nothing to mutate"
        loud_scope;
      test "a scope where every mutant is filtered is refused" (fun () ->
          let r = spawn ~exe:scoped_exe [ "--mutate=" ^ scope ^ "scoped/" ] in
          equal string "exited 1" r.status;
          equal text
            "windtrap: every mutant this run could test is dismissed by \
             [@mutate off] or filtered by the rewriter; there is nothing to \
             test\n"
            r.err;
          equal (option (list string)) None (rows r));
      test
        "domain_spawned is true after a domain spawned, also after the domain \
         ended" (fun () ->
          let r = spawn ~env:[ suite "spawned" ] [] in
          equal (pair string string)
            ("exited 0", "false\ntrue\n")
            (r.status, r.out));
      test
        "a suite that spawned a domain is refused in fork mode, because the \
         loop cannot fork" (fun () ->
          (* A file as TMPDIR: a check after the scratch directory gives
             another refusal. *)
          let r =
            spawn
              ~env:
                [
                  suite "domain";
                  ("WINDTRAP_MUTATE_CHILDREN", "fork");
                  ("TMPDIR", temp_file ());
                ]
              [ mutate ]
          in
          equal (pair string text)
            ("exited 1", "calc: 1 passed in <time>.\n")
            (r.status, masked r.out);
          equal text
            "windtrap: this process has spawned a domain, and OCaml refuses \
             Unix.fork in a process that has: run with --mutate-children=auto \
             or exec to start each child as a new process\n"
            r.err);
      test "a scratch directory that cannot be made is refused before the probe"
        (fun () ->
          let r =
            spawn ~env:[ suite "weak"; ("TMPDIR", temp_file ()) ] [ mutate ]
          in
          equal (pair string text)
            ("exited 1", "calc: 2 passed in <time>.\n")
            (r.status, masked r.out);
          starts_with
            ~affix:"windtrap: could not create the loop's scratch directory: "
            r.err);
    ]

(* The armed run *)

let armed_kill () =
  let r = spawn [ "--arm"; site 15 ] in
  equal string "exited 1" r.status;
  equal string
    (strf "mutant %s armed: a - b \u{2192} a + b" (site 15))
    (List.hd (lines r.out));
  contains ~sub:" (mutant armed)\n" r.out;
  contains ~sub:"    expected  6\n    actual    14\n\n  FAIL  " r.out;
  not_contains ~sub:"rerun:" r.out;
  equal string "mutant killed." (outcome r.out)

let armed_nothing_ran () =
  let r = spawn [ "--arm"; site 15; "-f"; "no-such-test" ] in
  equal string "exited 2" r.status;
  contains ~sub:" armed: " r.out;
  not_contains ~sub:"mutant killed." r.out;
  not_contains ~sub:"mutant survived" r.out;
  not_contains ~sub:"mutant not evaluated" r.out

let armed_closing env args expected () =
  let r = spawn ~env ([ "--arm"; site 18 ] @ args) in
  equal string "exited 0" r.status;
  contains ~sub:"armed: a + b \u{2192} a - b" r.out;
  equal string expected (outcome r.out)

(* [boundary] evaluates [orphan] at module initialization, before anything
   is armed. *)
let before_arming () =
  let r = spawn ~env:[ suite "boundary" ] [ "--arm"; site 21 ] in
  equal string "exited 0" r.status;
  contains ~sub:"armed: a + b \u{2192} a - b" r.out;
  equal string "mutant not evaluated: no selected test ran the site."
    (outcome r.out)

let armed_baseline = lazy (baseline_run [ "--arm"; site 15; "-u" ] ~stale:"6\n")

let armed_under_update () =
  let b = Lazy.force armed_baseline in
  equal string "exited 1" b.ran.status;
  equal string "mutant killed." (outcome b.ran.out);
  not_contains ~sub:"accepted" b.ran.out;
  equal text "6\n" b.baseline

let stale () =
  let id = Mutate.id_to_string { (site_id 15) with line = 999 } in
  let r = spawn [ "--arm"; id ] in
  equal string "exited 1" r.status;
  contains ~sub:id r.err;
  contains ~sub:"no such mutation site" r.err;
  contains ~sub:(site 15) r.err;
  not_contains ~sub:"calc: " r.out

(* One identifier handed to two executables built from disjoint sources,
   as [WINDTRAP_MUTATE_ARM=<id> dune runtest] hands it to every executable
   of a project. *)
let uncatalogued () =
  let r = spawn ~exe:runaway_exe ~env:[ ("WINDTRAP_MUTATE_ARM", site 15) ] [] in
  equal string "exited 0" r.status;
  equal text "spin: 1 passed in <time>.\n" (masked r.out);
  contains ~sub:"not this executable's mutant" r.err;
  contains ~sub:(site 15) r.err;
  equal int 1 (List.length (List.filter (fun l -> l <> "") (lines r.err)))

let plain_armed () =
  let r =
    spawn ~exe:plain_exe
      ~env:[ ("WINDTRAP_MUTATE_ARM", "lib/absent.ml:1:0:add") ]
      []
  in
  equal string "exited 0" r.status;
  equal text "plain: 1 passed in <time>.\n" (masked r.out);
  contains ~sub:"lib/absent.ml:1:0:add" r.err;
  contains ~sub:"not this executable's mutant" r.err;
  contains ~sub:"instrumented with ppx_windtrap.mutate" r.err

(* A dismissed or filtered site has no guard, so an armed run of its mutant
   is the unarmed run, and would end on a false "not evaluated". [dismissed]
   runs the two sites. Only [-no-filter] can arm a filtered mutant, and the
   refusal is the one place that tells the user so: [hint] pins that text.
   [-no-filter] does not arm a dismissed mutant, so its refusal must not give
   the hint. *)
let unarmable ?hint line reason () =
  let r = spawn ~env:[ suite "dismissed" ] [ "--arm"; site line ] in
  equal string "exited 1" r.status;
  equal text "" r.out;
  contains ~sub:(site line) r.err;
  contains ~sub:reason r.err;
  contains ~sub:"no run can arm it" r.err;
  match hint with
  | Some hint -> contains ~sub:hint r.err
  | None -> not_contains ~sub:"-no-filter" r.err

let inline_armed () = inline_run [ ("WINDTRAP_MUTATE_ARM", site 18) ]

(* Exit 0 would be the correction-coverage downgrade firing on output an
   armed mutant produced: dune would record the partition as passed. *)
let inline_mismatch () =
  let r, _ = inline_armed () in
  equal string "exited 1" r.status;
  contains ~sub:"armed: a + b \u{2192} a - b" r.out;
  contains ~sub:"expect: mismatch" r.out;
  contains ~sub:"- 7" r.out;
  contains ~sub:"+ -1" r.out;
  not_contains ~sub:"ran multiple times" r.out;
  contains ~sub:"mutant killed." r.out

let armed =
  group "The armed run"
    [
      test
        "an armed run announces the mutant first, fails, and reports the kill"
        armed_kill;
      test "an armed run whose selection matched nothing claims no verdict"
        armed_nothing_ran;
      test "a survivor's closing line counts the armed site's evaluations"
        (armed_closing
           [ suite "weak" ]
           []
           "mutant survived: the armed site was evaluated 2 times and no test \
            failed.");
      test "a site evaluated once is evaluated 1 time"
        (armed_closing
           [ suite "weak" ]
           [ "-f"; "widen is nonzero" ]
           "mutant survived: the armed site was evaluated 1 time and no test \
            failed.");
      test "an armed run whose selection never ran the site says so"
        (armed_closing [] [ "-f"; "calc" ]
           "mutant not evaluated: no selected test ran the site.");
      test "a site evaluated only before arming is not evaluated" before_arming;
      test "an armed run under -u records no correction" armed_under_update;
      test "an armed run writes its JUnit file" (fun () ->
          equal (list string) [ "junit.xml" ] (Lazy.force armed_baseline).beside);
      test "an identifier stale within a file this build catalogues is refused"
        stale;
      test "an identifier this executable holds no site of runs it green"
        uncatalogued;
      test "the same identifier arms the executable that holds it" (fun () ->
          let r = spawn ~env:[ ("WINDTRAP_MUTATE_ARM", site 15) ] [] in
          equal string "exited 1" r.status;
          contains
            ~sub:(strf "mutant %s armed: a - b \u{2192} a + b" (site 15))
            r.out);
      test "an identifier of a build with no mutants declines by name"
        plain_armed;
      test "a mutant that [@mutate off] dismisses is refused"
        (unarmable 33 "[@mutate off] dismisses this mutant");
      test "a mutant that the rewriter filtered is refused"
        (unarmable 38 "the rewriter filtered this mutant (zero operand)"
           ~hint:"give -no-filter after ppx_windtrap.mutate to test it");
      test "an armed site only tests marked xfail ran is not reached" (fun () ->
          let r = known_armed 21 in
          equal string "exited 0" r.status;
          equal string "mutant not reached: only xfail tests ran the site."
            (outcome r.out));
      test "an armed mutant an xfail test passes on survives, failing the run"
        (fun () ->
          let r = known_armed 15 in
          equal string "exited 1" r.status;
          contains ~sub:"expected to fail (sub subtracts), but the test passed"
            r.out;
          equal string
            "mutant survived: the site was evaluated 2 times and only xfail \
             tests failed."
            (outcome r.out));
      test "an armed site an xfail test also runs counts every evaluation"
        (fun () ->
          let r = known_armed 18 in
          equal string "exited 0" r.status;
          equal string
            "mutant survived: the armed site was evaluated 2 times and no test \
             failed."
            (outcome r.out));
      test "an armed inline partition writes no .corrected" (fun () ->
          let r, left = inline_armed () in
          equal (list string) [ "inline_armed.ml" ] left;
          not_contains ~sub:"wrote" r.err;
          not_contains ~sub:"could not write" r.err);
      test "an armed inline mismatch is a plain failure" inline_mismatch;
      test "the same partition is green and silent unarmed" (fun () ->
          let r, left = inline_run [] in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          not_contains ~sub:" armed: " r.out;
          equal (list string) [ "inline_armed.ml" ] left);
    ]

(* Reproducing a survivor *)

let inside_dune () =
  let r = spawn ~env:[ ("INSIDE_DUNE", "1") ] [ mutate ] in
  let armed = spawn [ "--arm"; site 18 ] in
  equal (option string)
    (Some
       ("dune exec --instrument-with ppx_windtrap.mutate \
         test/unit/mutate_loop/suite_main.exe -- --arm " ^ site 18))
    (reproduce r.out);
  equal string "exited 0" armed.status;
  contains ~sub:"armed: a + b \u{2192} a - b" armed.out

let shell command =
  let r = Child.run ~env:(quiet []) "/bin/sh" [ "-c"; command ] in
  {
    status = ended r.Child.status;
    out = r.Child.out;
    err = r.Child.err;
    file = None;
  }

(* A survivor of a narrowed run survived that selection only, so the
   command restates the filter. *)
let filtered () =
  let under_dune =
    spawn ~env:[ ("INSIDE_DUNE", "1") ] [ mutate; "-f"; "widen" ]
  in
  let command =
    require_some (reproduce (spawn [ mutate; "-f"; "widen" ]).out)
  in
  let pasted = shell command in
  equal (option string)
    (Some
       ("dune exec --instrument-with ppx_windtrap.mutate \
         test/unit/mutate_loop/suite_main.exe -- --arm " ^ site 18
      ^ " -f 'widen'"))
    (reproduce under_dune.out);
  contains ~sub:"reached by the 2 selected tests" (outcome under_dune.out);
  equal (pair string text) ("exited 0", "") (pasted.status, pasted.err);
  contains ~sub:"armed: a + b \u{2192} a - b" pasted.out;
  contains ~sub:"calc: 2 passed" pasted.out

let shell_split () =
  let root = temp_dir () in
  let dir = Filename.concat root "a suite's dir" in
  Sys.mkdir dir 0o755;
  let exe = Filename.concat dir "suite main.exe" in
  write exe (read suite_exe);
  Unix.chmod exe 0o755;
  let command =
    require_some (reproduce (spawn ~exe [ mutate; "-f"; "widen" ]).out)
  in
  let under_dune =
    spawn ~exe ~env:[ ("INSIDE_DUNE", "1") ] [ mutate; "-f"; "widen" ]
  in
  let pasted = shell command in
  equal string
    (strf "'%s/a suite'\\''s dir/suite main.exe' --arm %s -f 'widen'" root
       (site 18))
    command;
  equal (pair string text) ("exited 0", "") (pasted.status, pasted.err);
  contains ~sub:"armed: a + b \u{2192} a - b" pasted.out;
  contains ~sub:"reproduce: dune exec --instrument-with ppx_windtrap.mutate '"
    under_dune.out;
  contains
    ~sub:("suite main.exe' -- --arm " ^ site 18 ^ " -f 'widen'\n")
    under_dune.out

let reproducing =
  group "Reproducing a survivor"
    [
      test "a loop's command arms its first survivor" (fun () ->
          let r = Lazy.force green in
          equal (option string)
            (Some (strf "%s --arm %s" suite_exe (site 18)))
            (reproduce r.out));
      test "under dune the command names the backend, and its identifier arms"
        inside_dune;
      test "a filtered run's command arms the mutant under that filter" filtered;
      test "the command runs as pasted from a path a shell would split"
        shell_split;
    ]

(* Forks *)

(* No opening rule holds a run of thirty. *)
let closing_rule = String.concat "" (List.init 30 (fun _ -> "\u{2500}"))

(* [held]'s second child writes a start file and waits for a gate this
   test opens, so the report is read while that child provably runs. *)
let streamed () =
  let dir = temp_dir () in
  let began = Filename.concat dir "began"
  and gate = Filename.concat dir "gate" in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:[ suite "held"; ("MUTATE_STARTED", began); ("MUTATE_GATE", gate) ]
      [ mutate ]
  in
  await ~what:"the second child's start" run began;
  let seen = read run.out_path in
  write gate "";
  let r = finish run in
  equal (list string) [ site 15 ] (survivors seen);
  not_contains ~sub:closing_rule seen;
  not_contains ~sub:"mutants:" seen;
  equal string "exited 0" r.status;
  starts_with ~affix:seen r.out;
  equal (list string) [ site 15; site 18 ] (survivors r.out)

(* [held]'s two children start at once, and the second waits at the gate
   while the first survives. *)
let streamed_with_jobs () =
  let dir = temp_dir () in
  let began = Filename.concat dir "began"
  and gate = Filename.concat dir "gate" in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:[ suite "held"; ("MUTATE_STARTED", began); ("MUTATE_GATE", gate) ]
      [ mutate; jobs 2 ]
  in
  await ~what:"the second child's start" run began;
  await ~what:"the first survivor"
    ~ready:(fun out -> survivors out <> [])
    run run.out_path;
  let seen = read run.out_path in
  write gate "";
  let r = finish run in
  equal (list string) [ site 15 ] (survivors seen);
  not_contains ~sub:"mutants:" seen;
  equal string "exited 0" r.status;
  starts_with ~affix:seen r.out;
  equal (list string) [ site 15; site 18 ] (survivors r.out)

let held_order () =
  let r = spawn ~env:[ suite "held" ] [ mutate ] in
  equal (list string) [ site 15; site 18 ] (survivors r.out);
  equal (list string)
    [
      located "held \u{203a} watches sub without pinning it";
      located "held \u{203a} widen is nonzero, once the gate opens";
      located "held \u{203a} widen is not 99";
    ]
    (witnesses r.out);
  equal string
    "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out);
  equal (option string)
    (Some (strf "%s --arm %s" suite_exe (site 15)))
    (reproduce r.out)

let forks =
  group "Forks"
    [
      test
        "children run in the catalogue's order, however many tests reach each"
        held_order;
      test "a survivor is reported when its child ends, not when the loop does"
        streamed;
      test
        "with several jobs, a survivor is reported once every mutant before it \
         has a verdict, while later children run"
        streamed_with_jobs;
    ]

(* Jobs *)

(* What a reader of a run sees, with each duration masked: the dry run's
   summary is not always the first line. *)
let seen r =
  let timed line =
    match String.rindex_opt line ' ' with
    | Some i
      when i >= 3
           && String.sub line (i - 3) 3 = " in"
           && String.ends_with ~suffix:"s." line ->
        String.sub line 0 (i + 1) ^ "<time>."
    | Some _ | None -> line
  in
  (r.status, String.concat "\n" (List.map timed (lines r.out)), r.err, rows r)

let seen_witness = quad string text text (option (list string))

let same_with_jobs (_, env, args) =
  let one = spawn ~env [ mutate ] in
  equal seen_witness (seen one) (seen (spawn ~env (mutate :: args)))

(* The same, with two more runs of the child of each survivor. *)
let same_with_jobs_and_retry (_, env, args) =
  let retry = "--mutate-retry=2" in
  equal seen_witness
    (seen (spawn ~env [ mutate; retry ]))
    (seen (spawn ~env (mutate :: retry :: args)))

let retry_fixtures =
  [
    ("green, retry 2", [], [ jobs 4 ]);
    ("held, retry 2", [ suite "held" ], [ jobs 4 ]);
    ("intermittent, retry 2", [ suite "intermittent" ], [ jobs 4 ]);
    ("capped, retry 2", [ suite "capped" ], [ jobs 4 ]);
  ]

let fixtures =
  [
    ("green", [], [ jobs 4 ]);
    ("crash", [ suite "crash" ], [ jobs 4 ]);
    ("fatal", [ suite "fatal" ], [ jobs 4 ]);
    ("capped", [ suite "capped" ], [ jobs 4 ]);
    ("known", [ suite "known" ], [ jobs 4 ]);
    ("memo", [ suite "memo" ], [ jobs 4 ]);
    ("boundary", [ suite "boundary" ], [ jobs 4 ]);
    ("pinned", [ suite "pinned" ], [ jobs 4 ]);
    ("release", [ suite "release" ], [ jobs 4 ]);
    ("held", [ suite "held" ], [ jobs 4 ]);
    ("tagged", [ suite "tagged"; ("WINDTRAP_TAG", "gated") ], [ jobs 4 ]);
    ("capped, auto", [ suite "capped" ], [ "--mutate-jobs=auto" ]);
    ("capped, mirror", [ suite "capped"; ("WINDTRAP_MUTATE_JOBS", "4") ], []);
  ]

(* Each armed child of [rendezvous] waits for the other's mark. *)
let rendezvous env args =
  let dir = temp_dir () in
  spawn
    ~env:(suite "rendezvous" :: ("MUTATE_RENDEZVOUS", dir) :: env)
    (mutate :: args)

let at_once () =
  let typed = rendezvous [] [ jobs 2 ]
  and mirrored = rendezvous [ ("WINDTRAP_MUTATE_JOBS", "2") ] [] in
  List.iter
    (fun r ->
      equal (pair string text) ("exited 0", "") (r.status, r.err);
      equal string
        "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
         filtered, score 0.0%"
        (outcome r.out))
    [ typed; mirrored ]

let one_at_a_time () =
  let r = rendezvous [] [] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string
    "mutants: 1 survived of 2 reached by this suite, 1 killed, 2 never \
     reached, 1 filtered, score 50.0%"
    (outcome r.out)

(* Under two jobs, the loop starts the child of [widen] while it holds the
   pipe of the child of [sub]. Each child has its verdict pipe, and the
   pipes that the two got from the same loop and runner. A child that kept
   the pipe of the other child has one pipe more. *)
let own_pipe () =
  let dir = temp_dir () in
  let r =
    spawn ~env:[ suite "siblings"; ("MUTATE_PIPES", dir) ] [ mutate; jobs 2 ]
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string
    "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out);
  let count name = read (Filename.concat dir name) in
  is_true (count "sub" <> "");
  equal string (count "sub") (count "widen")

(* The pid of the child that waits at the gate [name] of [stalled], and the
   function that opens the gate. *)
let gate ~gates run name =
  let path = Filename.concat gates name in
  await ~what:("the start of the child of " ^ name) run path;
  (List.hd (pids (read path)), fun () -> write (path ^ ".open") "")

(* The two children of [stalled] wait at their gates at the same time, each
   with a log directory of its own in the scratch directory of the loop,
   the one entry of TMPDIR. The loop removes the directory of a child when
   it reaps the child, while the other child continues to run. In exec
   mode, each child also has a request file and a temporary directory, and
   [per_child] is the number of entries of one child. *)
let nothing_left_with ?(env = []) ~per_child () =
  let gates = temp_dir () and tmpdir = temp_dir () in
  let run =
    start
      ~env:
        (suite "stalled" :: ("MUTATE_GATES", gates) :: ("TMPDIR", tmpdir) :: env)
      [ mutate; jobs 2 ]
  in
  let first, open_first = gate ~gates run "sub" in
  let _, open_second = gate ~gates run "widen" in
  let logs =
    match entries tmpdir with
    | [ scratch ] -> fun () -> entries (Filename.concat tmpdir scratch)
    | found -> failf "TMPDIR holds %d entries" (List.length found)
  in
  let both = logs () in
  equal int (2 * per_child) (List.length both);
  open_first ();
  reaped ~what:"the reaping of the first child" run first;
  until ~what:"the removal of the first child's log directory" run (fun () ->
      List.length (logs ()) = per_child);
  let left = logs () in
  is_true (List.for_all (fun entry -> List.mem entry both) left);
  open_second ();
  let r = finish_within ~what:"the end of the second child" run in
  equal string "exited 0" r.status;
  equal (list string) [] (entries tmpdir)

let nothing_left () = nothing_left_with ~per_child:1 ()

(* The two children of [fixture], [stalled] or [queued], wait at their
   gates, and standard output is a pipe that this test fills. The child of
   [sub] ends first, and the loop blocks in the write of its survivor. The
   child of [widen] then ends while the loop is blocked, except when
   [widen_ends] is false. [meanwhile] gets the pid of that child, and acts
   before this test reads the pipe to its end. The result holds what the
   loop wrote. *)
let stalled_report ?(fixture = "stalled") ?(widen_ends = true) meanwhile =
  let gates = temp_dir () and tmpdir = temp_dir () in
  remove (verdict_path suite_exe);
  let reader, writer = Unix.pipe ~cloexec:true () in
  let run =
    start ~stdout:writer
      ~env:[ suite fixture; ("MUTATE_GATES", gates); ("TMPDIR", tmpdir) ]
      [ mutate; jobs 2 ]
  in
  let first, open_first = gate ~gates run "sub" in
  let second, open_second = gate ~gates run "widen" in
  fill writer;
  Unix.close writer;
  open_first ();
  reaped ~what:"the reaping of the first child" run first;
  if widen_ends then begin
    open_second ();
    exited ~what:"the end of the second child" run second
  end;
  meanwhile run second;
  let out = read_to_end reader in
  Unix.close reader;
  ({ (finish run) with out }, tmpdir)

let stalled_outcome =
  "mutants: 2 survived of 2 reached by this suite, 2 never reached, 1 \
   filtered, score 0.0%"

(* The verdict file of one job, where no gate holds a child. *)
let stalled_rows () = rows (spawn ~env:[ suite "stalled" ] [ mutate ])

(* The loop stays blocked past the deadline of the second child. *)
let past_deadline () =
  let share =
    Float.max 1. (2. /. float_of_int (Domain.recommended_domain_count ()))
  in
  let r, tmpdir = stalled_report (fun _ _ -> Unix.sleepf (2.5 *. share)) in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string) [ site 15; site 18 ] (survivors r.out);
  equal string stalled_outcome (outcome r.out);
  equal (list string) [] (entries tmpdir);
  equal (option (list string)) (stalled_rows ()) (rows r)

(* [stalled]'s two children wait at their gates, under SIGPIPE ignored, and
   this test closes the pipe of standard output. The write of the survivor
   of [sub] fails, and its [Sys_error] ends the loop while the child of
   [widen] waits at its gate. *)
let abandoned () =
  let gates = temp_dir () and tmpdir = temp_dir () in
  remove (verdict_path suite_exe);
  let reader, writer = Unix.pipe ~cloexec:true () in
  let run =
    start ~exe:"/bin/sh" ~stdout:writer
      ~env:[ suite "stalled"; ("MUTATE_GATES", gates); ("TMPDIR", tmpdir) ]
      [ "-c"; "trap '' PIPE; exec \"$0\" \"$@\""; suite_exe; mutate; jobs 2 ]
  in
  let _, open_first = gate ~gates run "sub" in
  let second, _ = gate ~gates run "widen" in
  Unix.close writer;
  Unix.close reader;
  open_first ();
  let r = finish run in
  let left = fate second in
  (* A child that the loop left alive must not outlive this test. *)
  (try Unix.kill (-second) Sys.sigkill with Unix.Unix_error _ -> ());
  equal string "exited 2" r.status;
  contains ~sub:"Sys_error" r.err;
  equal string "gone" left;
  equal (list string) [] (entries tmpdir);
  equal (option (list string)) None (rows r)

(* The live line *)

external openpty : unit -> Unix.file_descr * Unix.file_descr
  = "windtrap_test_openpty"

(* Adds to [seen] what [master] holds at this time. When the other end of
   the terminal is closed, a read gives EIO on Linux and 0 on macOS. *)
let drain master seen =
  let chunk = Bytes.create 4096 in
  let rec read () =
    match Unix.read master chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes seen chunk 0 n;
        read ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
    | exception
        Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EIO), _, _) ->
        ()
  in
  read ()

let without_escapes s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i >= String.length s then Buffer.contents b
    else if s.[i] = '\027' && i + 1 < String.length s && s.[i + 1] = '[' then
      let rec final j =
        if j >= String.length s then j
        else match s.[j] with '@' .. '~' -> j + 1 | _ -> final (j + 1)
      in
      go (final (i + 2))
    else begin
      Buffer.add_char b s.[i];
      go (i + 1)
    end
  in
  go 0

(* Each text that the live line showed for the mutants, in its order. A
   carriage return starts each live line. The live lines of the dry run
   name tests, not mutants. *)
let mutation_live out =
  List.filter_map
    (fun text ->
      let text = String.trim text in
      match index_of ~sub:"] " text with
      | Some i
        when String.starts_with ~prefix:"[" text
             && index_of ~sub:scope ~from:i text = Some (i + 2) ->
          Some text
      | Some _ | None -> None)
    (String.split_on_char '\r' (without_escapes out))

(* Runs [queued] under two jobs, with standard output a terminal. Its
   children of [sub] and of [widen] wait at their gates, and the child of
   [orphan] waits for a job. [meanwhile] gets the run, the gates of [sub]
   and of [widen] as [gate] gives them, and a function that gives the live
   lines that the terminal showed until that time. The result is the live
   lines of the run. *)
let live_lines meanwhile =
  let gates = temp_dir () in
  let seen = Buffer.create 4096 in
  let master, slave = openpty () in
  Unix.set_nonblock master;
  remove (verdict_path suite_exe);
  let run =
    Fun.protect
      ~finally:(fun () -> Unix.close slave)
      (fun () ->
        start ~stdout:slave
          ~env:
            [
              suite "queued";
              ("MUTATE_GATES", gates);
              ("WINDTRAP_COLOR", "always");
            ]
          [ mutate; jobs 2 ])
  in
  let sub = gate ~gates run "sub" in
  let widen = gate ~gates run "widen" in
  let shown () =
    drain master seen;
    mutation_live (Buffer.contents seen)
  in
  let r =
    Fun.protect
      ~finally:(fun () -> snd widen ())
      (fun () ->
        meanwhile run ~sub ~widen shown;
        finish run)
  in
  drain master seen;
  Unix.close master;
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  mutation_live (Buffer.contents seen)

(* When the child of [sub] ends, the child of [orphan] starts, and ends
   while the child of [widen] waits. Thus the count of the live line is
   not the position of a mutant that started. The loop draws the live
   line each time that a child ends, and the third line comes when the
   child of [orphan] ends. *)
let live_count () =
  equal (list string)
    [
      strf "[0/3] %s and 1 more\u{2026}" (site 15);
      strf "[1/3] %s and 1 more\u{2026}" (site 18);
      strf "[2/3] %s\u{2026}" (site 18);
    ]
    (live_lines (fun run ~sub:(_, open_sub) ~widen:(_, open_widen) shown ->
         open_sub ();
         until ~what:"the third live line of the loop" run (fun () ->
             List.length (shown ()) >= 3);
         open_widen ()))

(* The loop stops while the children of [sub] and of [widen] end. When
   the loop continues, one wait gives the two children. The live line
   counts the two, and then names the child of [orphan] alone. *)
let live_count_together () =
  equal (list string)
    [
      strf "[0/3] %s and 1 more\u{2026}" (site 15);
      strf "[2/3] %s\u{2026}" (site 21);
    ]
    (live_lines
       (fun run ~sub:(sub, open_sub) ~widen:(widen, open_widen) shown ->
         until ~what:"the first live line of the loop" run (fun () ->
             shown () <> []);
         Unix.kill run.pid Sys.sigstop;
         Fun.protect
           ~finally:(fun () ->
             try Unix.kill run.pid Sys.sigcont with Unix.Unix_error _ -> ())
           (fun () ->
             open_sub ();
             open_widen ();
             exited ~what:"the end of the child of sub" run sub;
             exited ~what:"the end of the child of widen" run widen)))

let jobs_group =
  group "Jobs"
    [
      cases "more jobs give the report and the verdict file of one"
        ~name:(fun (name, _, _) -> name)
        fixtures same_with_jobs;
      cases
        "more jobs give the report and the verdict file of one, with two more \
         runs of each survivor"
        ~name:(fun (name, _, _) -> name)
        retry_fixtures same_with_jobs_and_retry;
      test "children of several jobs run at once" at_once;
      test "children of one job run one at a time" one_at_a_time;
      test
        "a child counts as many jobs as the CPUs of its heaviest test, rounded \
         to the nearest integer"
        jobs_of_two_cpus;
      test "a child does not keep the pipes of the other children" own_pipe;
      test
        "each child of several jobs has a log directory of its own, removed \
         when the child is reaped"
        nothing_left;
      test
        "a child that ends while a write of the report holds the loop keeps \
         its verdict past its deadline"
        past_deadline;
      test
        "an exception that ends the loop kills the children that continue to \
         run"
        abandoned;
      test
        "on a terminal, the live line counts the mutants whose children ended \
         and names those that run"
        live_count;
      test
        "on a terminal, the live line counts each child of a wait that gives \
         more than one"
        live_count_together;
    ]

(* Signals *)

(* A run whose standard output is a pipe this test holds, stopped while a
   child waits at the fixture's gate. The loop keeps its scratch directory
   under the TMPDIR it is given. *)
let held_at_the_gate ?exe ?(args = [ mutate ]) name =
  let dir = temp_dir () and tmpdir = temp_dir () in
  let began = Filename.concat dir "began"
  and gate = Filename.concat dir "gate" in
  remove (verdict_path suite_exe);
  let reader, writer = Unix.pipe ~cloexec:true () in
  let run =
    start ?exe ~stdout:writer
      ~env:
        [
          suite name;
          ("MUTATE_STARTED", began);
          ("MUTATE_GATE", gate);
          ("TMPDIR", tmpdir);
        ]
      args
  in
  await ~what:"the held child's start" run began;
  (run, tmpdir, reader, writer, fun () -> write gate "")

let reader_leaves ?exe ?args name =
  let run, tmpdir, reader, writer, open_gate =
    held_at_the_gate ?exe ?args name
  in
  Unix.close writer;
  Unix.close reader;
  open_gate ();
  (finish run, tmpdir)

let pinned_rows =
  [
    "subject.ml:15 killed";
    "subject.ml:18 killed";
    "subject.ml:21 killed";
    "subject.ml:27 killed";
    "subject.ml:38 filtered: zero operand";
  ]

let left_mid_loop () =
  let r, tmpdir = reader_leaves "held" in
  equal string "killed by SIGPIPE" r.status;
  equal text "" r.err;
  equal (list string) [] (entries tmpdir);
  equal (option (list string)) None (rows r)

let left_at_the_end () =
  let r, tmpdir = reader_leaves "pinned" in
  equal string "killed by SIGPIPE" r.status;
  equal text "" r.err;
  equal (option (list string)) (Some pinned_rows) (rows r);
  equal (list string) [] (entries tmpdir)

let pipe_ignored () =
  let r, tmpdir =
    reader_leaves ~exe:"/bin/sh"
      ~args:[ "-c"; "trap '' PIPE; exec \"$0\" \"$@\""; suite_exe; mutate ]
      "held"
  in
  equal string "exited 2" r.status;
  contains ~sub:"Sys_error" r.err;
  equal (list string) [] (entries tmpdir);
  equal (option (list string)) None (rows r)

(* The pipe is filled and never read, so the loop most likely blocks in the
   write of its outcome line when SIGINT comes; a signal after the verdict
   file costs it nothing either way. *)
let late_interrupt () =
  let run, tmpdir, reader, writer, open_gate = held_at_the_gate "pinned" in
  fill writer;
  Unix.close writer;
  open_gate ();
  let path = verdict_path suite_exe in
  await ~what:"the verdict file" run path;
  Unix.sleepf 0.2;
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  Unix.close reader;
  equal string "killed by SIGINT" r.status;
  equal text "" r.err;
  equal (option (list string)) (Some pinned_rows) (rows r);
  equal (list string) [] (entries tmpdir)

(* [interrupted]'s second child hangs in a session of its own, with a
   grandchild that ignores SIGTERM. *)
let interrupted_by ?(exe = suite_exe) ?(args = [ mutate ]) ?(env = []) ?planted
    signal =
  let pidfile = Filename.concat (temp_dir ()) "hanging"
  and tmpdir = temp_dir () in
  remove_suite_files exe;
  Option.iter (write (verdict_path exe)) planted;
  let run =
    start ~exe ~writer:exe
      ~env:
        (suite "interrupted"
        :: ("MUTATE_GRANDCHILD_PIDFILE", pidfile)
        :: ("TMPDIR", tmpdir) :: env)
      args
  in
  await ~what:"the hanging child" run pidfile;
  Unix.kill run.pid signal;
  let r = finish run in
  (r, List.map fate (pids (read pidfile)), entries tmpdir)

let interrupted_outcome =
  "mutants: 1 survived of 3 reached by this suite, 1 never reached, 1 \
   filtered, 2 not tested, score 0.0%"

let stopped_with env () =
  let r, grandchildren, left = interrupted_by ~env Sys.sigint in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 18)) r.err;
  equal (list string) [ site 15 ] (survivors r.out);
  equal (option string)
    (Some (strf "%s --arm %s" suite_exe (site 15)))
    (reproduce r.out);
  equal string interrupted_outcome (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] left;
  equal (list string) [ "gone" ] grandchildren

let stopped = stopped_with []

let sigpipe () =
  let r, grandchildren, left = interrupted_by Sys.sigpipe in
  equal string "killed by SIGPIPE" r.status;
  equal text "" r.err;
  equal (list string) [ site 15 ] (survivors r.out);
  not_contains ~sub:"mutants:" r.out;
  equal (option (list string)) None (rows r);
  equal (list string) [] left;
  equal (list string) [ "gone" ] grandchildren

let probe_interrupted () =
  let marker = Filename.concat (temp_dir ()) "marker"
  and tmpdir = temp_dir () in
  let run =
    start
      ~env:
        [
          suite "probe_block";
          ("MUTATE_PROBE_MARKER", marker);
          ("TMPDIR", tmpdir);
        ]
      [ mutate ]
  in
  await ~what:"the probe's start" run (marker ^ ".probe");
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  equal string "killed by SIGINT" r.status;
  equal text "windtrap: interrupted during the determinism probe\n" r.err;
  equal string
    "mutants: 1 reached by this suite, 3 never reached, 1 filtered, 1 not \
     tested"
    (outcome r.out);
  equal (list string) [] (entries tmpdir)

(* [late]'s armed child leaves a watcher that sends SIGINT once the loop's
   scratch directory is gone; the FIFO at the verdict file's place holds
   the loop in the window between its last child and its handlers'
   restoration (see suite_main.ml). *)
let after_last_child () =
  let path = verdict_path suite_exe in
  remove path;
  Unix.mkfifo path 0o600;
  let tmpdir = temp_dir () in
  let r = finish (start ~env:[ suite "late"; ("TMPDIR", tmpdir) ] [ mutate ]) in
  equal string "killed by SIGINT" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
     filtered, score 0.0%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 survived by late \u{203a} signals the loop once its \
          last child ends";
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r);
  equal (list string) [] (entries tmpdir)

(* [hung]'s two children hang at once, each with a grandchild that ignores
   SIGTERM. *)
let two_interrupted () =
  let pidfile = Filename.concat (temp_dir ()) "hanging"
  and tmpdir = temp_dir () in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:
        [
          suite "hung";
          ("MUTATE_GRANDCHILD_PIDFILE", pidfile);
          ("TMPDIR", tmpdir);
        ]
      [ mutate; jobs 2 ]
  in
  await ~what:"the two hanging children"
    ~ready:(fun contents -> List.length (pids contents) = 2)
    run pidfile;
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  equal string "killed by SIGINT" r.status;
  equal text
    (strf "windtrap: interrupted while testing %s, %s\n" (site 15) (site 18))
    r.err;
  equal (list string) [] (survivors r.out);
  equal string
    "mutants: 2 reached by this suite, 2 never reached, 1 filtered, 2 not \
     tested"
    (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir);
  equal (list string) [ "gone"; "gone" ] (List.map fate (pids (read pidfile)))

(* [gap]'s first child hangs, and its second survives and ends. *)
let over_the_gap () =
  let ended = Filename.concat (temp_dir ()) "ended" and tmpdir = temp_dir () in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:[ suite "gap"; ("MUTATE_ENDED", ended); ("TMPDIR", tmpdir) ]
      [ mutate; jobs 2 ]
  in
  await ~what:"the end of the second child's test" run ended;
  reaped ~what:"the reaping of the second child" run
    (List.hd (pids (read ended)));
  let held = read run.out_path in
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  equal (list string) [] (survivors held);
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 15)) r.err;
  equal (list string) [ site 18 ] (survivors r.out);
  equal string
    "mutants: 1 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, 1 not tested, score 0.0%"
    (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir)

(* [closing]'s child of [widen] closes its pipe and continues to run, so the
   loop waits for it to exit. The signal comes in that wait, and the handler
   kills the two children. The wait gives the child of [widen], and a second
   wait gives the child of [sub], which is first in the catalogue. *)
let stopped_in_two_waits () =
  if not (Sys.file_exists "/proc/self/fd") then
    skip ~reason:"the system does not show the descriptors of a process" ();
  let closed = Filename.concat (temp_dir ()) "closed"
  and tmpdir = temp_dir () in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:[ suite "closing"; ("MUTATE_CLOSED", closed); ("TMPDIR", tmpdir) ]
      [ mutate; jobs 2 ]
  in
  await ~what:"the wait of the loop for the child of widen" run closed;
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  equal string "killed by SIGINT" r.status;
  equal text
    (strf "windtrap: interrupted while testing %s, %s\n" (site 15) (site 18))
    r.err;
  equal string
    "mutants: 2 reached by this suite, 2 never reached, 1 filtered, 2 not \
     tested"
    (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir)

(* The signal comes after the last child ends, and before the loop reaps
   it, because a write holds the loop. *)
let after_last_unreaped () =
  let r, tmpdir = stalled_report (fun run _ -> Unix.kill run.pid Sys.sigint) in
  equal (pair string text) ("killed by SIGINT", "") (r.status, r.err);
  equal (list string) [ site 15; site 18 ] (survivors r.out);
  equal string stalled_outcome (outcome r.out);
  equal (list string) [] (entries tmpdir);
  equal (option (list string)) (stalled_rows ()) (rows r)

(* The signal comes while a write holds the loop, and the handler kills the
   child of [widen] at its gate. The pipe of that child closes before the
   loop reads it. The slot of the child of [sub] is free, and the mutant of
   [orphan] waits for it. *)
let killed_unreaped () =
  let r, tmpdir =
    stalled_report ~fixture:"queued" ~widen_ends:false (fun run second ->
        Unix.kill run.pid Sys.sigint;
        exited ~what:"the death of the second child" run second)
  in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 18)) r.err;
  equal (list string) [ site 15 ] (survivors r.out);
  equal string
    "mutants: 1 survived of 3 reached by this suite, 1 never reached, 1 \
     filtered, 2 not tested, score 0.0%"
    (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir)

(* The signal comes while a write holds the loop, after the child of
   [widen] ends. No child runs, and the mutant of [orphan] remains. *)
let before_next () =
  let r, tmpdir =
    stalled_report ~fixture:"queued" (fun run _ -> Unix.kill run.pid Sys.sigint)
  in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted before testing %s\n" (site 21)) r.err;
  equal (list string) [ site 15; site 18 ] (survivors r.out);
  equal string
    "mutants: 2 survived of 3 reached by this suite, 1 never reached, 1 \
     filtered, 1 not tested, score 0.0%"
    (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir)

(* [retried]'s mutant of [widen] has a killing test in the verdict file,
   which its first child runs alone. The child of [orphan] ends, the child
   of [sub] ends and the loop blocks in the write of its survivor, and then
   the first child of [widen] ends. The signal comes before the loop reads
   that the first child killed nothing, so no child runs and the full child
   of [widen] remains. *)
let before_full_child () =
  let path = verdict_path suite_exe in
  remove path;
  ignore (spawn ~env:[ suite "retried" ] [ mutate ]);
  rewrite (fun r ->
      if r.id = site_id 18 then
        {
          r with
          verdict =
            Verdicts.Killed
              { by = Some [ "retried"; "widen waits at its gate" ] };
        }
      else r);
  let gates = temp_dir () and tmpdir = temp_dir () in
  let reader, writer = Unix.pipe ~cloexec:true () in
  let run =
    start ~stdout:writer
      ~env:[ suite "retried"; ("MUTATE_GATES", gates); ("TMPDIR", tmpdir) ]
      [ mutate; jobs 3 ]
  in
  let first, open_first = gate ~gates run "sub" in
  let second, open_second = gate ~gates run "widen" in
  let third, open_third = gate ~gates run "orphan" in
  open_third ();
  reaped ~what:"the reaping of the child of orphan" run third;
  fill writer;
  Unix.close writer;
  open_first ();
  reaped ~what:"the reaping of the child of sub" run first;
  open_second ();
  exited ~what:"the end of the first child of widen" run second;
  Unix.kill run.pid Sys.sigint;
  let out = read_to_end reader in
  Unix.close reader;
  let r = { (finish run) with out } in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted before testing %s\n" (site 18)) r.err;
  equal (list string) [ site 15; site 21 ] (survivors r.out);
  equal string
    "mutants: 2 survived of 3 reached by this suite, 1 never reached, 1 \
     filtered, 1 not tested, score 0.0%"
    (outcome r.out);
  equal (list string) [] (entries tmpdir)

(* A signal sent to the whole process tree, as [pkill] sends it, kills the
   child of [widen] at its gate while a write holds the loop. The loop gets
   the signal after the child dies. *)
let tree_signal signal =
  let r, tmpdir =
    stalled_report ~widen_ends:false (fun run second ->
        Unix.kill second signal;
        exited ~what:"the death of the second child" run second;
        Unix.kill run.pid signal)
  in
  equal string ("killed by " ^ signal_name signal) r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 18)) r.err;
  equal (list string) [ site 15 ] (survivors r.out);
  equal string
    "mutants: 1 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, 1 not tested, score 0.0%"
    (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir)

let signals =
  group "Signals"
    [
      test
        "a child that ended before a signal keeps its verdict, also when the \
         loop did not reap it"
        after_last_unreaped;
      test "a signal kills every running child, and names each one"
        two_interrupted;
      test
        "a signal names the children that it stopped in catalogue order, also \
         when two waits give them"
        stopped_in_two_waits;
      test
        "a child that the handler killed gets no verdict, also when its pipe \
         closed before the loop read it, and no child starts after the signal"
        killed_unreaped;
      cases
        "a child that a signal to the whole process tree killed gets no verdict"
        ~name:signal_name
        [ Sys.sigint; Sys.sigterm; Sys.sighup ]
        tree_signal;
      test
        "a signal when no child runs stops the loop before the next mutant, \
         and names it"
        before_next;
      test
        "a signal commits the verdicts that ended before it, over the gap of a \
         child it stopped"
        over_the_gap;
      test
        "a signal stops the loop, reports what it found, and kills by that \
         signal"
        stopped;
      cases "SIGTERM and SIGHUP stop it as SIGINT does" ~name:signal_name
        [ Sys.sigterm; Sys.sighup ] (fun signal ->
          let r, _, _ = interrupted_by signal in
          equal string ("killed by " ^ signal_name signal) r.status;
          equal text
            (strf "windtrap: interrupted while testing %s\n" (site 18))
            r.err;
          equal string interrupted_outcome (outcome r.out));
      test
        "a signal after a first child that killed nothing commits the verdicts \
         after its mutant, and names that mutant as not tested"
        before_full_child;
      test "a signal during the determinism probe names the probe"
        probe_interrupted;
      test
        "a signal after the last child ends the run after its file and report"
        after_last_child;
      test "SIGPIPE stops it silently, with no closing report" sigpipe;
      test "a reader that leaves mid-loop: a silent death by SIGPIPE, no file"
        left_mid_loop;
      test
        "a reader that leaves a loop that then ran whole: the file is written"
        left_at_the_end;
      test "with SIGPIPE ignored, the failed write's Sys_error escapes"
        pipe_ignored;
      test "a SIGINT after the verdict file costs it nothing" late_interrupt;
    ]

(* Effects *)

(* A survivor's source line is read under the project root first, then at
   its recorded path from the working directory. *)
let source_lines () =
  let plant dir comment =
    let path = Filename.concat dir (scope ^ "subject.ml") in
    List.iter
      (fun d -> Sys.mkdir (Filename.concat dir d) 0o755)
      [ "test"; "test/unit"; "test/unit/mutate_loop" ];
    write path (String.make 17 '\n' ^ "let widen a b = a + b " ^ comment ^ "\n")
  in
  let root = temp_dir () and cwd = temp_dir () in
  plant root "(* under the root *)";
  plant cwd "(* as recorded *)";
  let excerpt_under project_root =
    excerpt
      (spawn ~cwd
         ~env:[ suite "weak"; ("WINDTRAP_PROJECT_ROOT", project_root) ]
         [ mutate; "-f"; "widen" ])
        .out
  in
  equal (list string)
    [ "18 \u{2502} let widen a b = a + b (* under the root *)" ]
    (excerpt_under root);
  equal (list string)
    [ "18 \u{2502} let widen a b = a + b (* as recorded *)" ]
    (excerpt_under (temp_dir ()))

let effects =
  group "Effects"
    [
      test "a survivor quotes the mutated source line" (fun () ->
          equal (list string)
            [ "18 \u{2502} let widen a b = a + b" ]
            (excerpt (Lazy.force green).out));
      test
        "a survivor's source is read under the project root, then as recorded"
        source_lines;
    ]

(* Exec mode *)

let exec_line = "children: new processes (--mutate-children=exec)"

(* A run in exec mode with no mode line, to compare with a fork. *)
let without_exec_line r =
  {
    r with
    out = String.concat "\n" (List.filter (( <> ) exec_line) (lines r.out));
  }

(* The line before the outcome line. *)
let before_outcome out =
  match List.rev (List.filter (fun l -> l <> "") (lines out)) with
  | _ :: line :: _ -> line
  | [] | [ _ ] -> ""

(* A suite that spawns no domain gives the report and the verdict file of a
   fork when each child is a new process. These tests do not show that the
   children are new processes. [memo_in_exec] shows it. *)
let same_in_exec (_, env, args) =
  equal seen_witness
    (seen (spawn ~env (mutate :: args)))
    (seen
       (without_exec_line (spawn ~env:(exec_children :: env) (mutate :: args))))

let exec_fixtures =
  [
    ("green", [], []);
    ("green, 4 jobs", [], [ jobs 4 ]);
    ("green, retry 2", [], [ "--mutate-retry=2" ]);
    ("crash", [ suite "crash" ], []);
    ("fatal", [ suite "fatal" ], []);
    ("capped, 4 jobs", [ suite "capped" ], [ jobs 4 ]);
    ("known", [ suite "known" ], []);
    ("boundary", [ suite "boundary" ], []);
    ("pinned", [ suite "pinned" ], []);
    ("release", [ suite "release" ], []);
    ("tagged", [ suite "tagged"; ("WINDTRAP_TAG", "gated") ], []);
    ("red", [ suite "red" ], []);
    ("flaky", [ suite "flaky" ], []);
    ("skippy", [ suite "skippy" ], []);
    ("budget", [ suite "budget" ], []);
  ]

(* The dry run left the answer of [widen] in a table. A fork reads it and
   does not evaluate the site. A new process has an empty table, evaluates
   the site and fails. *)
let memo_in_exec () =
  let r = spawn ~env:[ exec_children; suite "memo" ] [ mutate ] in
  equal string "exited 0" r.status;
  equal string
    "mutants: 2 reached by this suite, 2 killed, 2 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  not_contains ~sub:"arm: " r.out

(* Each process sleeps at its module initialization. If the deadline of a
   child does not include that time, the child expires and the loop kills
   its mutant. *)
let slow_init () =
  let slow = ("MUTATE_SLOW_INIT", "2") in
  equal seen_witness
    (seen (spawn [ mutate; jobs 4 ]))
    (seen
       (without_exec_line
          (spawn ~env:[ exec_children; slow ] [ mutate; jobs 4 ])))

let child_fault fault =
  spawn ~env:[ exec_children; ("MUTATE_CHILD_FAULT", fault) ] [ mutate ]

let domain_in_auto () =
  let r = spawn ~env:[ suite "domain" ] [ mutate ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string "children: new processes, because the suite spawned a domain"
    (before_outcome r.out);
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

(* Suites that spawn a domain *)

let domain_init = ("MUTATE_DOMAIN_INIT", "1")
let auto_line = "children: new processes, because the suite spawned a domain"

(* A run in auto mode with a domain at module initialization, with its mode
   line removed. *)
let without_auto_line r =
  {
    r with
    out = String.concat "\n" (List.filter (( <> ) auto_line) (lines r.out));
  }

let domains =
  group "Domains"
    [
      test
        "a stateful test on two domains spawns no worker under mutation, and \
         the loop forks" (fun () ->
          let r = spawn ~env:[ suite "stateful_domains" ] [ mutate ] in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          not_contains ~sub:"children: " r.out;
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out));
      test
        "with --mutate-workers, a stateful test on two domains spawns its \
         workers, and each child is a new process" (fun () ->
          let r =
            spawn
              ~env:[ suite "stateful_domains" ]
              [ mutate; "--mutate-workers" ]
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string auto_line (before_outcome r.out);
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out));
      test
        "with --mutate-workers and --mutate-children=fork, the loop refuses \
         the suite" (fun () ->
          let r =
            spawn
              ~env:[ suite "stateful_domains" ]
              [ mutate; "--mutate-workers"; "--mutate-children=fork" ]
          in
          equal (pair string text)
            ( "exited 1",
              "windtrap: this process has spawned a domain, and OCaml refuses \
               Unix.fork in a process that has: run with \
               --mutate-children=auto or exec to start each child as a new \
               process\n" )
            (r.status, r.err));
      test
        "with --mutate-workers and more than one job, the report has the line \
         of a suite that spawned a domain" (fun () ->
          let r =
            spawn
              ~env:[ suite "stateful_domains" ]
              [ mutate; "--mutate-workers"; jobs 4 ]
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string auto_line (before_outcome r.out));
      test
        "with --mutate-workers, a child of a stateful test on two domains \
         counts as two jobs" (fun () ->
          let taskset = two_cpus () in
          let run n =
            let dir = temp_dir () in
            spawn ~exe:taskset
              ~env:[ suite "stateful_rendezvous"; ("MUTATE_RENDEZVOUS", dir) ]
              [ "-c"; "0,1"; suite_exe; mutate; "--mutate-workers"; jobs n ]
          in
          let two = run 2 and four = run 4 in
          List.iter
            (fun r ->
              equal (pair string text) ("exited 0", "") (r.status, r.err))
            [ two; four ];
          equal string
            "mutants: 1 survived of 2 reached by this suite, 1 killed, 2 never \
             reached, 1 filtered, score 50.0%"
            (outcome two.out);
          equal string
            "mutants: 2 survived of 2 reached by this suite, 2 never reached, \
             1 filtered, score 0.0%"
            (outcome four.out));
      test
        "with --mutate-workers and more jobs than CPUs, children of a test on \
         two domains kill no mutant that survives" (fun () ->
          let taskset = two_cpus () in
          let r =
            spawn ~exe:taskset
              ~env:[ suite "stateful_survivors" ]
              [
                "-c";
                "0,1";
                suite_exe;
                mutate;
                "--mutate-workers";
                "--mutate-retry=0";
                jobs 8;
              ]
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string
            "mutants: 4 survived of 4 reached by this suite, 1 filtered, score \
             0.0%"
            (outcome r.out));
      test
        "without --mutate-workers, no test reaches a site that only a worker \
         evaluates" (fun () ->
          let r = spawn ~env:[ suite "on_workers" ] [ mutate ] in
          equal string
            "mutants: 0 reached by this suite, 4 never reached, 1 filtered"
            (outcome r.out));
      test
        "with --mutate-workers, each child spawns its workers, which kill a \
         mutant that only a worker evaluates" (fun () ->
          let r =
            spawn ~env:[ suite "on_workers" ] [ mutate; "--mutate-workers" ]
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out));
      test
        "an armed run without --mutate-workers does not evaluate a site that \
         only a worker evaluates" (fun () ->
          let r = spawn ~env:[ suite "on_workers" ] [ "--arm"; site 15 ] in
          equal string "mutant not evaluated: no selected test ran the site."
            (outcome r.out));
      test
        "an armed run with --mutate-workers kills the mutant, and its replay \
         line keeps the flag" (fun () ->
          let r =
            spawn
              ~env:[ suite "on_workers" ]
              [ "--arm"; site 15; "--mutate-workers" ]
          in
          equal string "exited 1" r.status;
          equal string "mutant killed." (outcome r.out);
          contains ~sub:" --mutate-workers\n" r.out);
      test "with --mutate-workers, a suite that spawns no pool keeps its jobs"
        (fun () ->
          let r =
            spawn
              ~env:[ suite "forked" ]
              [ mutate; "--mutate-workers"; "--mutate-children=exec"; jobs 4 ]
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string exec_line (before_outcome r.out));
      test "an armed run with --mutate-workers keeps the flag in its JUnit file"
        (fun () ->
          let junit = Filename.concat (temp_dir ()) "junit.xml" in
          let r =
            spawn
              ~env:[ suite "on_workers" ]
              [ "--arm"; site 15; "--mutate-workers"; "--junit"; junit ]
          in
          equal string "mutant killed." (outcome r.out);
          contains ~sub:" --mutate-workers\n" (read junit));
      test "an armed run reads the mirror of --mutate-workers" (fun () ->
          let r =
            spawn
              ~env:[ suite "on_workers"; ("WINDTRAP_MUTATE_WORKERS", "1") ]
              [ "--arm"; site 15 ]
          in
          equal string "mutant killed." (outcome r.out));
      cases
        "a domain at module initialization gives the report of a fork, with \
         one job and with four, as a fork does with two retries"
        ~name:(fun (name, _, _) -> name)
        [
          ("green", [], []);
          ("green, 4 jobs", [], [ jobs 4 ]);
          ("crash", [ suite "crash" ], [ jobs 4 ]);
          ("known", [ suite "known" ], []);
          ("release", [ suite "release" ], []);
        ]
        (fun (_, env, args) ->
          let r = spawn ~env:(domain_init :: env) (mutate :: args) in
          contains ~sub:("\n" ^ auto_line ^ "\n") r.out;
          equal seen_witness
            (seen (spawn ~env (mutate :: "--mutate-retry=2" :: args)))
            (seen (without_auto_line r)));
      test
        "a result that the dry run cached does not reach a new process, with \
         one job and with four" (fun () ->
          let r = spawn ~env:[ domain_init; suite "memo" ] [ mutate ] in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string
            "mutants: 2 reached by this suite, 2 killed, 2 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out);
          equal seen_witness (seen r)
            (seen (spawn ~env:[ domain_init; suite "memo" ] [ mutate; jobs 4 ])));
      test
        "a new process that blocks is killed at its deadline, and no process \
         of its group stays" (fun () ->
          let pidfile = Filename.concat (temp_dir ()) "grandchild"
          and tmpdir = temp_dir () in
          let r =
            finish_within ~what:"the deadline of the blocked new process"
              (start
                 ~env:
                   [
                     domain_init;
                     suite "block";
                     ("MUTATE_GRANDCHILD_PIDFILE", pidfile);
                     ("TMPDIR", tmpdir);
                   ]
                 [ mutate ])
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out);
          equal (list string) [ "gone" ] (List.map fate (pids (read pidfile)));
          equal (list string) [] (entries tmpdir));
      test "SIGINT stops a run in new processes, and nothing stays"
        (stopped_with [ domain_init ]);
      test "a test tree that changes in each process is refused" (fun () ->
          let tmpdir = temp_dir () in
          let r =
            spawn
              ~env:[ domain_init; suite "tree"; ("TMPDIR", tmpdir) ]
              [ mutate ]
          in
          equal (list string) [] (entries tmpdir);
          equal string "exited 1" r.status;
          starts_with
            ~affix:
              "windtrap: the determinism probe refused to run: the tests \
               changed after the dry run: this process has no test \"tree \
               \u{203a} sub, in process "
            r.err;
          equal (option (list string)) None (rows r));
    ]

(* The second test of [slow_order] needs the state of the first, which
   sleeps 3 seconds in each run. In exec mode, the child of the mutant runs
   the two tests, so its deadline must have the time of the first. *)
let slow_prefix () =
  let r =
    finish_within ~seconds:30. ~what:"the child of a slow prefix"
      (start ~env:[ exec_children; suite "slow_order" ] [ mutate ])
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  contains ~sub:exec_line r.out;
  equal string one_survivor (outcome r.out);
  equal
    (option (list string))
    (Some
       ("subject.ml:15 survived by order \u{203a} needs the state and watches \
         sub" :: other_rows))
    (rows r)

(* The second test of [warm_up] fills again, in a new process, the table that
   the first test filled in the dry run. This takes 2.5 seconds, but the dry
   run measured the second test as fast. The deadline of a child in exec mode
   has the time of the dry run up to its last test, so the child that runs
   the second test alone passes. Thus the first test runs in one child, the
   probe. Without that time, the deadline is about 1.5 seconds, the child
   expires, and the child of the mutant runs the two tests: two children run
   the first test. *)
let warm_up_in_exec () =
  let marker = Filename.concat (temp_dir ()) "marker" in
  let r =
    finish_within ~seconds:30. ~what:"the children of a warm-up"
      (start
         ~env:[ exec_children; suite "warm_up"; ("MUTATE_WARM_MARKER", marker) ]
         [ mutate ])
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  contains ~sub:exec_line r.out;
  equal string one_survivor (outcome r.out);
  equal
    (option (list string))
    (Some
       ("subject.ml:15 survived by warm_up \u{203a} uses the table and watches \
         sub" :: other_rows))
    (rows r);
  equal (list string) [ "ran"; "" ] (lines (read marker))

let exec_group =
  group "Exec mode"
    [
      test
        "in exec mode, the deadline of the child of a slow test before its \
         reaching test has the time of that test"
        slow_prefix;
      test
        "in exec mode, the deadline of a child has the time of the dry run up \
         to its last test"
        warm_up_in_exec;
      cases "a suite with no domain gives the report of a fork"
        ~name:(fun (name, _, _) -> name)
        exec_fixtures same_in_exec;
      test
        "a result that the dry run left in memory does not reach a new process"
        memo_in_exec;
      test "the deadline of a new process includes its module initialization"
        slow_init;
      test
        "the loop refuses to run when a new process ends before it serves its \
         request" (fun () ->
          let r = child_fault "exit" in
          equal (pair string text)
            ( "exited 1",
              "windtrap: a new process of the suite ended without a ready line\n"
            )
            (r.status, r.err));
      test
        "the loop refuses to run when no call of a new process is for its suite"
        (fun () ->
          let r = child_fault "rename" in
          equal (pair string text)
            ( "exited 1",
              "windtrap: a new process of the suite ended without a ready line\n"
            )
            (r.status, r.err));
      test "a main with two suites serves each request in the call of its suite"
        (fun () ->
          let r = spawn ~env:[ exec_children; suite "two_suites" ] [ mutate ] in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string green_outcome (outcome r.out));
      test "a signal stops the startup child" (fun () ->
          let tmpdir = temp_dir () in
          remove (verdict_path suite_exe);
          let run =
            start
              ~env:
                [
                  exec_children;
                  ("MUTATE_CHILD_FAULT", "hang");
                  ("TMPDIR", tmpdir);
                ]
              [ mutate ]
          in
          until ~what:"the start of the startup child" run (fun () ->
              List.exists
                (fun scratch ->
                  Sys.file_exists
                    (Filename.concat
                       (Filename.concat tmpdir scratch)
                       "startup.request"))
                (entries tmpdir));
          Unix.sleepf 0.2;
          Unix.kill run.pid Sys.sigint;
          let r = finish run in
          equal (pair string text)
            ( "killed by SIGINT",
              "windtrap: interrupted while a new process of the suite started\n"
            )
            (r.status, r.err);
          equal (option (list string)) None (rows r);
          equal (list string) [] (entries tmpdir));
      test "a suite that spawned a domain gets a full run in auto mode"
        domain_in_auto;
      test
        "the report of exec mode tells the mode above the outcome line and its \
         reproduce line" (fun () ->
          let r = spawn ~env:[ exec_children ] [ mutate ] in
          let last =
            match List.rev (List.filter (fun l -> l <> "") (lines r.out)) with
            | outcome :: reproduce :: mode :: _ -> [ mode; reproduce; outcome ]
            | _ -> []
          in
          equal (list string)
            [
              exec_line;
              strf "reproduce: %s --arm %s" suite_exe (site 18);
              green_outcome;
            ]
            last);
      test
        "in exec mode, reaching tests that need an earlier test run after the \
         tests of the dry run before them" (fun () ->
          let fork = spawn ~env:[ suite "order" ] [ mutate ] in
          let fork_killers = killers (verdict_path suite_exe) in
          let exec = spawn ~env:[ exec_children; suite "order" ] [ mutate ] in
          equal seen_witness (seen fork) (seen (without_exec_line exec));
          equal (list string) [ site 18 ] (survivors exec.out);
          equal (list string)
            [ "subject.ml:15 order \u{203a} needs the state and pins sub" ]
            (killers (verdict_path suite_exe));
          equal (list string) fork_killers (killers (verdict_path suite_exe)));
      test
        "a suite that spawns a domain and whose tests need earlier tests gets \
         the verdicts of a fork, with one job and with four" (fun () ->
          let one = spawn ~env:[ suite "order_domain" ] [ mutate ] in
          let four = spawn ~env:[ suite "order_domain" ] [ mutate; jobs 4 ] in
          equal (pair string text) ("exited 0", "") (one.status, one.err);
          contains
            ~sub:
              "\nchildren: new processes, because the suite spawned a domain\n"
            one.out;
          equal (list string) [ site 18 ] (survivors one.out);
          equal seen_witness (seen one) (seen four);
          equal
            (option (list string))
            (rows (spawn ~env:[ suite "order" ] [ mutate; "--mutate-retry=2" ]))
            (rows one));
      test
        "in exec mode, a test before the last reaching test can kill the \
         mutant, and the verdict names it, also in the next run" (fun () ->
          let path = verdict_path suite_exe in
          let fork = spawn ~env:[ suite "order_kill" ] [ mutate ] in
          equal (list string) [ site 15 ] (survivors fork.out);
          let killed_by_reader =
            [ "subject.ml:15 order \u{203a} reads what sub stored" ]
          in
          let exec () =
            let r =
              spawn ~env:[ exec_children; suite "order_kill" ] [ mutate ]
            in
            equal (pair string text) ("exited 0", "") (r.status, r.err);
            equal (list string) [] (survivors r.out);
            killers path
          in
          equal (list string) killed_by_reader (exec ());
          equal (list string) killed_by_reader (exec ()));
      test
        "in exec mode, a test marked xfail does not stop the child before the \
         reaching tests after it" (fun () ->
          let path = verdict_path suite_exe in
          let pinned =
            [ "subject.ml:15 order \u{203a} needs the state and pins sub" ]
          in
          let fork = spawn ~env:[ suite "order_xfail" ] [ mutate ] in
          equal (pair string text) ("exited 0", "") (fork.status, fork.err);
          equal (list string) pinned (killers path);
          let exec =
            spawn ~env:[ exec_children; suite "order_xfail" ] [ mutate ]
          in
          equal (pair string text) ("exited 0", "") (exec.status, exec.err);
          equal (list string) pinned (killers path));
      test "the report of fork mode does not tell the mode" (fun () ->
          let r = spawn [ mutate ] in
          not_contains ~sub:"children:" r.out);
      test "an inline suite serves its requests in new processes"
        (inline_loop_with [ exec_children ]);
      test "no at_exit function runs in a new process"
        (no_at_exit_with [ exec_children ]);
      test "a new process checks baselines read-only" (fun () ->
          let b =
            baseline_run ~env:[ exec_children ] [ mutate; "-u" ] ~stale:"5\n"
          in
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome b.ran.out);
          equal text "6\n" b.baseline);
      test "a first child is a new process too"
        (first_tests_with [ exec_children ]);
      test
        "the loop removes the request file and the temporary directory of a \
         new process when it reaps the process" (fun () ->
          nothing_left_with ~env:[ exec_children ] ~per_child:3 ());
      test "new processes of several jobs run at once" (fun () ->
          let r = rendezvous [ exec_children ] [ jobs 2 ] in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string
            "mutants: 2 survived of 2 reached by this suite, 2 never reached, \
             1 filtered, score 0.0%"
            (outcome r.out));
      test "a new process that blocks is killed at its deadline, with its group"
        (fun () ->
          let pidfile = Filename.concat (temp_dir ()) "grandchild" in
          let r =
            finish_within ~what:"the deadline of the blocked new process"
              (start
                 ~env:
                   [
                     exec_children;
                     suite "block";
                     ("MUTATE_GRANDCHILD_PIDFILE", pidfile);
                   ]
                 [ mutate ])
          in
          equal (pair string text) ("exited 0", "") (r.status, r.err);
          equal string
            "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 \
             filtered, score 100.0%"
            (outcome r.out);
          equal (list string) [ "gone" ] (List.map fate (pids (read pidfile))));
      (* The startup child has a deadline of 60 seconds or more, so no test
         lets it expire. *)
      test "a signal stops the new processes as it stops forks"
        (stopped_with [ exec_children ]);
    ]

(* Killed elsewhere *)

(* A scratch project: a copy of the suite below [root/_build], the data
   directory of its verdict files, and the source of the mutants. The loop
   names a file by the real path of its executable, so [root] has no
   symbolic link. *)
type project = {
  root : string;
  exe : string;
  data : string;
  digest : string option;
}

let skip_project ?(plant = true) () =
  let root = Unix.realpath (temp_dir ()) in
  let exe = copied_suite root in
  let data = directory root "_build/_mutants" in
  let digest =
    if not plant then None
    else
      let path = Filename.concat (directory root scope) "subject.ml" in
      write path "(* the scratch subject *)\n";
      Some (Digest.to_hex (Digest.file path))
  in
  { root; exe; data; digest }

let other_record ?source_digest id verdict =
  {
    Verdicts.id;
    before = "b";
    after = "a";
    source_digest;
    verdict;
    previous = None;
  }

(* The verdict file [name] of the executable [exe], with a stand-in
   executable. The file records the digest of the stand-in, so it is fresh,
   unless [writer] gives another digest. A [digest] replaces the source
   digest of each record, and [records] adds whole records. *)
let plant_other ?(exe = "default/other.exe") ?(orphan = false) ?(named = true)
    ?suite ?writer ?digest ?(records = []) p name verdicts =
  let source_digest =
    match digest with None -> p.digest | Some digest -> digest
  in
  let build = Filename.dirname p.data in
  let stand_in = Filename.concat build exe in
  if named && (not orphan) && not (Sys.file_exists stand_in) then begin
    ignore (directory build (Filename.dirname exe));
    write stand_in "an executable\n"
  end;
  let writer =
    match writer with
    | Some writer -> writer
    | None ->
        Option.value (Instr.file_digest stand_in) ~default:(String.make 32 'f')
  in
  let identity =
    if named then Some { Verdicts.exe; digest = writer } else None
  in
  Verdicts.save ?identity ?suite
    (Filename.concat p.data name)
    (List.fold_left Verdicts.add Verdicts.empty
       (List.map
          (fun (line, verdict) ->
            other_record ?source_digest (site_id line) verdict)
          verdicts
       @ records))

let killed_by_pins = Verdicts.Killed { by = Some [ "ordered"; "pins sub" ] }

(* A run of the copy in the root of its project, with the words that the
   children of [ordered] wrote. It removes the verdict file of the suite
   [calc] of the copy first, unless [keep], and leaves the other files. *)
let skip_run ?(fixture = "ordered") ?(env = []) ?(keep = false)
    ?(prefix = [ mutate ]) p args =
  let own = verdict_path p.exe in
  if not keep then remove own;
  let ran = Filename.concat (temp_dir ()) "ran" in
  let r =
    Child.run ~cwd:p.root
      ~env:(quiet (suite fixture :: ("MUTATE_RAN", ran) :: env))
      p.exe (prefix @ args)
  in
  ( {
      status = ended r.Child.status;
      out = r.Child.out;
      err = r.Child.err;
      file = saved own;
    },
    List.filter (( <> ) "") (lines (read ran)) )

let elsewhere_line out =
  List.find_opt (String.starts_with ~prefix:"killed elsewhere: ") (lines out)

let one_skip exe =
  "killed elsewhere: 1 mutant, not tested, from the verdict file of " ^ exe
  ^ " (1)"

let no_skip exe =
  "killed elsewhere: 0 mutants, not tested, from the verdict file of " ^ exe
  ^ " (0)"

let no_file =
  "killed elsewhere: 0 mutants, not tested, from no other verdict file"

let skip_killed = "--mutate-skip-killed"

(* The rows of [ordered] when the loop tests its one mutant. *)
let ordered_rows =
  [
    "subject.ml:15 killed";
    "subject.ml:18 unreached";
    "subject.ml:21 unreached";
    "subject.ml:27 unreached";
    "subject.ml:38 filtered: zero operand";
  ]

let skipped_rows exe =
  ("subject.ml:15 killed elsewhere by " ^ exe) :: List.tl ordered_rows

let skipped_outcome =
  "mutants: 1 reached by this suite, 3 never reached, 1 filtered, 1 not tested"

let last_lines n out =
  List.rev
    (List.filteri
       (fun i _ -> i < n)
       (List.rev (List.filter (( <> ) "") (lines out))))

let old_name = "windtrap-old.mutants"

(* A verdict file of the previous format. *)
let plant_old p =
  write (Filename.concat p.data old_name) "windtrap-mutants-v6\n0\n"

let old_warning p =
  strf
    "windtrap: warning: --mutate-skip-killed ignores %s/%s: not a windtrap \
     verdict file (expected header \"windtrap-mutants-v10\", found \
     \"windtrap-mutants-v6\"); files written by other windtrap versions are \
     not readable - delete the stale verdict files, then re-run the mutation \
     tests\n"
    p.data old_name

(* The project of the regression of issue 25: another executable killed the
   mutant of [sub], and a file of the previous format lies beside its
   file. *)
let issue_25_project () =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants" [ (15, killed_by_pins) ];
  plant_old p;
  p

let tested ((r : ran), words) =
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal (list string) [ "watches"; "pins" ] words;
  equal (option string) None (elsewhere_line r.out);
  equal (option (list string)) (Some ordered_rows) (rows r);
  equal string ordered_outcome (outcome r.out)

let skipped p ((r : ran), words) =
  equal string "exited 0" r.status;
  equal text (old_warning p) r.err;
  equal (list string) [] words;
  equal (option string)
    (Some (one_skip "default/other.exe"))
    (elsewhere_line r.out);
  equal (list string)
    [ one_skip "default/other.exe"; skipped_outcome ]
    (last_lines 2 r.out);
  equal
    (option (list string))
    (Some (skipped_rows "default/other.exe"))
    (rows r)

let issue_25 () =
  let p = issue_25_project () in
  tested (skip_run p []);
  skipped p (skip_run p [ skip_killed ])

let mirror () =
  let p = issue_25_project () in
  skipped p (skip_run ~env:[ ("WINDTRAP_MUTATE_SKIP_KILLED", "1") ] p []);
  let r, words = skip_run ~env:[ ("WINDTRAP_MUTATE_SKIP_KILLED", "0") ] p [] in
  tested (r, words)

let survivor_killed_elsewhere () =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants"
    [ (18, Verdicts.Killed { by = Some [ "other"; "pins widen" ] }) ];
  let r, _ = skip_run ~fixture:"green" p [ skip_killed ] in
  equal (list string) [] (survivors r.out);
  equal (option string) None (reproduce r.out);
  equal string
    "mutants: 2 reached by this suite, 1 killed, 2 never reached, 1 filtered, \
     1 not tested, score 100.0%"
    (outcome r.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 killed elsewhere by default/other.exe";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r)

let no_chain () =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants"
    [ (15, Verdicts.Killed_elsewhere { exe = "default/third.exe" }) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [ "watches"; "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r);
  equal (option string)
    (Some (no_skip "default/other.exe"))
    (elsewhere_line r.out)

let not_a_kill =
  [
    ("a survivor", Verdicts.survived [ [ "ordered"; "pins sub" ] ]);
    ("not evaluated", Verdicts.Not_evaluated);
    ("outside tests", Verdicts.Outside_tests);
    ("unreached", Verdicts.Unreached);
    ("filtered", Verdicts.Filtered "zero operand");
    ("flaky", Verdicts.Flaky { test = [ "ordered"; "pins sub" ]; failure = "x" });
  ]

let only_a_kill (_, verdict) =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants" [ (15, verdict) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [ "watches"; "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r);
  equal (option string)
    (Some (no_skip "default/other.exe"))
    (elsewhere_line r.out)

let kill_without_test () =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants" [ (15, Verdicts.Killed { by = None }) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [] words;
  equal
    (option (list string))
    (Some (skipped_rows "default/other.exe"))
    (rows r)

let other_digests =
  [ ("a digest that differs", Some (String.make 32 '0')); ("no digest", None) ]

let other_digest (_, digest) =
  let p = skip_project () in
  plant_other ~digest p "windtrap-other.mutants" [ (15, killed_by_pins) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [ "watches"; "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r)

let unreadable_source () =
  let p = skip_project ~plant:false () in
  plant_other
    ~digest:(Some (String.make 32 'a'))
    p "windtrap-other.mutants"
    [ (15, killed_by_pins) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [ "watches"; "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r)

let own_file () =
  let p = skip_project () in
  ignore (skip_run p []);
  let r, words = skip_run ~keep:true p [ skip_killed ] in
  equal text "" r.err;
  equal (list string) [ "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r);
  equal (option string) (Some no_file) (elsewhere_line r.out)

(* The loop reads the files in name order. Each order of the two executables
   fails a loop that keeps the first or the last killer. *)
let smaller_executable first =
  let p = skip_project () in
  let kill = Verdicts.Killed { by = None } in
  let a = ("default/a.exe", [ (18, kill) ])
  and b = ("default/b.exe", [ (15, kill); (18, kill) ]) in
  List.iteri
    (fun i (exe, verdicts) ->
      plant_other ~exe p (strf "windtrap-%d.mutants" (i + 1)) verdicts)
    (if first = "a.exe" then [ a; b ] else [ b; a ]);
  let r, _ = skip_run ~fixture:"green" p [ skip_killed ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed elsewhere by default/b.exe";
         "subject.ml:18 killed elsewhere by default/a.exe";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r);
  equal (option string)
    (Some
       "killed elsewhere: 2 mutants, not tested, from the verdict files of \
        default/a.exe (1), default/b.exe (1)")
    (elsewhere_line r.out);
  equal string
    "mutants: 2 reached by this suite, 2 never reached, 1 filtered, 2 not \
     tested"
    (outcome r.out)

let ignored_files () =
  let p = skip_project () in
  let kill = Verdicts.Killed { by = None } in
  plant_other ~named:false p "windtrap-anon.mutants" [ (15, kill) ];
  Sys.mkdir (Filename.concat p.data "windtrap-dir.mutants") 0o755;
  plant_other ~exe:"default/good.exe" p "windtrap-good.mutants.123abc.tmp"
    [ (15, kill) ];
  write (Filename.concat p.data "notes.txt") "notes\n";
  plant_old p;
  let warnings =
    strf
      "windtrap: warning: --mutate-skip-killed ignores \
       %s/windtrap-anon.mutants: the file names no executable\n\
       %s"
      p.data (old_warning p)
  in
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [ "watches"; "pins" ] words;
  equal (option string) (Some no_file) (elsewhere_line r.out);
  equal text warnings r.err;
  plant_other p "windtrap-other.mutants" [ (15, kill) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [] words;
  equal text warnings r.err;
  equal (option string)
    (Some (one_skip "default/other.exe"))
    (elsewhere_line r.out)

let orphan_file () =
  let p = skip_project () in
  plant_other ~exe:"default/gone.exe" ~orphan:true p "windtrap-gone.mutants"
    [ (15, Verdicts.Killed { by = None }) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [ "watches"; "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r);
  equal (option string) (Some no_file) (elsewhere_line r.out);
  equal text
    ("windtrap: warning: --mutate-skip-killed ignores " ^ p.data
   ^ "/windtrap-gone.mutants: its executable (_build/default/gone.exe) no \
      longer exists\n")
    r.err;
  write (Filename.concat p.root "_build/default/gone.exe") "an executable\n";
  plant_other ~exe:"default/gone.exe" p "windtrap-gone.mutants"
    [ (15, Verdicts.Killed { by = None }) ];
  let r, words = skip_run p [ skip_killed ] in
  equal (list string) [] words;
  equal text "" r.err;
  equal (option string)
    (Some (one_skip "default/gone.exe"))
    (elsewhere_line r.out)

(* A loop that read the executable to judge the file would block. *)
let fifo_executable () =
  let p = skip_project () in
  plant_other ~exe:"default/fifo.exe" ~orphan:true p "windtrap-fifo.mutants"
    [ (15, Verdicts.Killed { by = None }) ];
  Unix.mkfifo (Filename.concat p.root "_build/default/fifo.exe") 0o644;
  remove (verdict_path p.exe);
  let run =
    start ~exe:p.exe ~writer:p.exe
      ~env:[ suite "ordered"; ("TMPDIR", temp_dir ()) ]
      [ mutate; skip_killed ]
  in
  let r =
    finish_within ~seconds:30. ~what:"a verdict file of a FIFO executable" run
  in
  equal string "exited 0" r.status;
  equal (option string) (Some no_file) (elsewhere_line r.out);
  equal text
    ("windtrap: warning: --mutate-skip-killed ignores " ^ p.data
   ^ "/windtrap-fifo.mutants: its executable (_build/default/fifo.exe) is not \
      a regular file\n")
    r.err

(* A loop that opened the FIFO would block. *)
let fifo () =
  let p = skip_project () in
  Unix.mkfifo (Filename.concat p.data "windtrap-fifo.mutants") 0o644;
  remove (verdict_path p.exe);
  let run =
    start ~exe:p.exe ~writer:p.exe
      ~env:[ suite "ordered"; ("TMPDIR", temp_dir ()) ]
      [ mutate; skip_killed ]
  in
  let r = finish_within ~seconds:30. ~what:"a FIFO in the data directory" run in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (option string) (Some no_file) (elsewhere_line r.out)

let scope_of_the_skip () =
  let p = skip_project () in
  let kill = Verdicts.Killed { by = None } in
  let outside =
    other_record ?source_digest:p.digest
      { Mutate.file = "elsewhere/other.ml"; line = 1; col = 0; rewrite = "add" }
      kill
  in
  plant_other p "windtrap-other.mutants"
    [ (15, kill); (21, kill); (38, kill) ]
    ~records:[ outside ];
  let r, _ = skip_run ~fixture:"green" p [ skip_killed ] in
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed elsewhere by default/other.exe";
         "subject.ml:18 survived by widen \u{203a} widen is nonzero, widen \
          \u{203a} widen is not 99";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (rows r);
  equal (list string) [ site 18 ] (survivors r.out);
  equal string
    "mutants: 1 survived of 2 reached by this suite, 2 never reached, 1 \
     filtered, 1 not tested, score 0.0%"
    (outcome r.out);
  equal (option string)
    (Some (one_skip "default/other.exe"))
    (elsewhere_line r.out)

(* Under --mutate-since, a mutant on a line that did not change is out of the
   scope. The other file kills the mutants of the lines 15 and 18. *)
let since changed =
  let root = changed_subject changed in
  let p = skip_project ~plant:false () in
  let digest =
    Digest.to_hex
      (Digest.file (Filename.concat (directory root scope) "subject.ml"))
  in
  let kill = Verdicts.Killed { by = None } in
  plant_other ~digest:(Some digest) p "windtrap-other.mutants"
    [ (15, kill); (18, kill) ];
  skip_run ~fixture:"green"
    ~env:[ ("WINDTRAP_PROJECT_ROOT", root) ]
    ~prefix:[ "--mutate=" ^ subject_scope; "--mutate-since=HEAD" ]
    p [ skip_killed ]

let skipped_since () =
  let r, _ = since [ 15 ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal
    (option (list string))
    (Some [ "subject.ml:15 killed elsewhere by default/other.exe" ]) (rows r);
  equal string "mutants: 1 reached by this suite, 1 not tested" (outcome r.out);
  equal (option string)
    (Some (one_skip "default/other.exe"))
    (elsewhere_line r.out);
  let r, _ = since [ 15; 18 ] in
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed elsewhere by default/other.exe";
         "subject.ml:18 killed elsewhere by default/other.exe";
       ])
    (rows r);
  equal string "mutants: 2 reached by this suite, 2 not tested" (outcome r.out);
  equal (option string)
    (Some
       "killed elsewhere: 2 mutants, not tested, from the verdict file of \
        default/other.exe (2)")
    (elsewhere_line r.out)

let same_children mode =
  let p = issue_25_project () in
  let r, words = skip_run p [ skip_killed; "--mutate-children=" ^ mode ] in
  equal (list string) [] words;
  equal
    (option (list string))
    (Some (skipped_rows "default/other.exe"))
    (rows r);
  if mode = "exec" then
    equal (list string)
      [ exec_line; one_skip "default/other.exe"; skipped_outcome ]
      (last_lines 3 r.out)

let jobs_of_the_skip () =
  let answer n =
    let p = skip_project () in
    plant_other p "windtrap-other.mutants"
      [ (18, Verdicts.Killed { by = Some [ "other"; "pins widen" ] }) ];
    let r, _ = skip_run ~fixture:"green" p [ skip_killed; jobs n ] in
    (masked r.out, rows r)
  in
  equal (pair string (option (list string))) (answer 1) (answer 4)

(* [hung] reaches two mutants, and the other file kills the mutant of [sub].
   On one CPU, the one child blocks until its deadline, about 1.5 seconds
   after the stamp of [hang]. With 16 jobs, the one tested mutant gives one
   child for each CPU, as 1 job does. A share from the two reached mutants
   doubles the deadline. *)
let share_of_the_skip () =
  let taskset = one_cpu () in
  let p = skip_project () in
  plant_other p "windtrap-other.mutants" [ (15, Verdicts.Killed { by = None }) ];
  let hung n =
    remove (verdict_path p.exe);
    let stamp = Filename.concat (temp_dir ()) "stamp" in
    let r =
      Child.run ~cwd:p.root
        ~env:(quiet [ suite "hung"; ("MUTATE_HANG_STAMP", stamp) ])
        taskset
        [ "-c"; "0"; p.exe; mutate; skip_killed; jobs n ]
    in
    let hung =
      Unix.gettimeofday () -. float_of_string (String.trim (read stamp))
    in
    equal (pair string text) ("exited 0", "") (ended r.Child.status, r.Child.err);
    equal string
      "mutants: 2 reached by this suite, 1 killed, 2 never reached, 1 \
       filtered, 1 not tested, score 100.0%"
      (outcome r.Child.out);
    hung
  in
  let one = hung 1 in
  at_least float_exact ~than:1.0 one;
  less float_exact ~than:(one +. 0.75) (hung 16)

let narrowed_skip () =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants" [ (15, killed_by_pins) ];
  let r, words = skip_run p [ "-f"; "pins"; skip_killed ] in
  equal (list string) [] words;
  equal text not_saved r.err;
  equal (option (list string)) None (rows r);
  equal string
    "mutants: 1 reached by the 1 selected test, 3 never reached, 1 filtered, 1 \
     not tested"
    (outcome r.out)

let interrupted_skip () =
  let p = skip_project () in
  plant_other p "windtrap-other.mutants" [ (21, Verdicts.Killed { by = None }) ];
  let r, grandchildren, left =
    interrupted_by ~exe:p.exe ~args:[ mutate; skip_killed ] Sys.sigint
  in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 18)) r.err;
  contains ~sub:("\n" ^ one_skip "default/other.exe" ^ "\nreproduce: ") r.out;
  equal string interrupted_outcome (outcome r.out);
  equal (option (list string)) None (rows r);
  equal (list string) [] left;
  equal (list string) [ "gone" ] grandchildren

let killed_elsewhere_lines out =
  List.filter (String.starts_with ~prefix:"killed elsewhere: ") (lines out)

(* The mutant of [sub] that the first suite of the process killed gets no
   child in the second suite. The record names the executable, which is the
   executable of the run. *)
let sibling_suite_run () =
  let p = skip_project () in
  let me = "default/suite_main.exe" in
  let r, words =
    skip_run ~fixture:"two_reach" ~env:[ weak ] p [ skip_killed ]
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string) [] words;
  equal (list string) [ no_file; one_skip me ] (killed_elsewhere_lines r.out);
  equal
    (option (list string))
    (Some [ "subject.ml:15 killed" ])
    (Option.map
       (fun (f : file) ->
         List.filter (String.starts_with ~prefix:"subject.ml:15 ") f.rows)
       (saved (verdict_path ~suite:"first" p.exe)));
  equal (option (list string)) (Some (skipped_rows me)) (rows r);
  equal string skipped_outcome (outcome r.out);
  p

(* Two suites that skip one mutant because of each other do not: the record
   of a skip never skips. *)
let sibling_suites_do_not_chain () =
  let p = sibling_suite_run () in
  let me = "default/suite_main.exe" in
  let r, _ =
    skip_run ~fixture:"two_reach" ~env:[ weak ] ~keep:true p [ skip_killed ]
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string) [ no_skip me; one_skip me ] (killed_elsewhere_lines r.out);
  equal
    (option (list string))
    (Some [ "subject.ml:15 killed" ])
    (Option.map
       (fun (f : file) ->
         List.filter (String.starts_with ~prefix:"subject.ml:15 ") f.rows)
       (saved (verdict_path ~suite:"first" p.exe)));
  equal (option (list string)) (Some (skipped_rows me)) (rows r)

(* A file of another build gives no skip and no warning, for the executable
   of the run and for another one. Fresh, the same file skips. *)
let stale_files =
  let kill = [ (15, killed_by_pins) ] in
  [
    ( "of this executable, a suite that no longer runs",
      "default/suite_main.exe",
      fun writer p ->
        plant_other ~exe:"default/suite_main.exe" ~suite:"renamed" ?writer p
          (Filename.basename (verdict_path ~suite:"renamed" p.exe))
          kill );
    ( "of another executable",
      "default/other.exe",
      fun writer p -> plant_other ?writer p "windtrap-other.mutants" kill );
  ]

let another_build (_, killer, plant) =
  let p = skip_project () in
  plant (Some (String.make 32 'f')) p;
  let r, words = skip_run p [ skip_killed ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string) [ "watches"; "pins" ] words;
  equal (option (list string)) (Some ordered_rows) (rows r);
  equal (option string) (Some no_file) (elsewhere_line r.out);
  plant None p;
  let r, words = skip_run p [ skip_killed ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string) [] words;
  equal (option string) (Some (one_skip killer)) (elsewhere_line r.out);
  equal (option (list string)) (Some (skipped_rows killer)) (rows r)

let killed_elsewhere =
  group "Killed elsewhere"
    [
      test
        "a mutant that another suite of the same executable killed gets no \
         child, and the record names this executable" (fun () ->
          ignore (sibling_suite_run ()));
      test
        "two suites of one process do not skip one mutant because of each other"
        sibling_suites_do_not_chain;
      cases "a verdict file of another build gives no skip and no warning"
        ~name:(fun (name, _, _) -> name)
        stale_files another_build;
      test
        "a mutant that the verdict file of another executable killed gets no \
         child, and the run records and counts it"
        issue_25;
      test "the mirror of --mutate-skip-killed sets the option" mirror;
      test "a survivor that another executable killed is not a survivor"
        survivor_killed_elsewhere;
      test "a mutant that another run skipped does not skip this run" no_chain;
      cases "only a kill skips a mutant" ~name:fst not_a_kill only_a_kill;
      test "a kill that names no test skips the mutant too" kill_without_test;
      cases "a kill with another source digest, or none, does not skip"
        ~name:fst other_digests other_digest;
      test "a source that this run cannot read does not skip" unreadable_source;
      test "the own verdict file of the run is not used" own_file;
      cases
        "of two files that kill a mutant, the smaller executable is the one \
         that the record names, in each order of the files"
        ~name:(strf "%s first") [ "a.exe"; "b.exe" ] smaller_executable;
      test
        "a file with no executable, a file of an old format, a directory and a \
         temporary file are not used, and the run names the first two"
        ignored_files;
      test "a file whose executable no longer exists is not used" orphan_file;
      test ~timeout:60. "a FIFO in the data directory is not opened" fifo;
      test ~timeout:60.
        "a file whose executable is a FIFO is not used, and the FIFO is not \
         opened"
        fifo_executable;
      test "only the reached mutants of the scope are skipped" scope_of_the_skip;
      test "--mutate-since keeps its scope under the option" skipped_since;
      cases "fork and exec give one answer" ~name:Fun.id [ "fork"; "exec" ]
        same_children;
      test "the number of jobs does not change the answer" jobs_of_the_skip;
      test
        "the deadline of a child counts only the CPUs of the mutants that get \
         a child"
        share_of_the_skip;
      test "a narrowed run skips the mutant and writes no verdict file"
        narrowed_skip;
      test "an interrupted run prints the line of the skipped mutants"
        interrupted_skip;
    ]

(* Unstable verdicts *)

let weak_outcome =
  "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
   filtered, score 0.0%"

(* A loop that ran whole: its exit code, its error stream and its outcome
   line. A section of unstable verdicts changes none of them. *)
let whole ?(outcome_line = green_outcome) (r : ran) =
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string outcome_line (outcome r.out)

(* The previous verdict of the records of line [line]. *)
let previous_of line r =
  Option.map
    (List.filter (String.starts_with ~prefix:(strf "subject.ml:%d " line)))
    (previous_rows r)

(* The verdict file with [verdict] in the records of line [line]. *)
let at_line line verdict (r : Verdicts.record) =
  if r.id.line = line then { r with verdict } else r

(* The first run has no file, so it lists nothing and its records have no
   previous verdict. The second run does not kill [sub] any more, and its
   file keeps the old verdict. The third run is the same. The fourth run kills
   again. *)
let changed_verdict () =
  remove (verdict_path suite_exe);
  let r1 = rerun ~env:[ flagged ] [ mutate ] in
  whole ~outcome_line:ordered_outcome r1;
  equal (option (list string)) None (unstable r1.out);
  equal (option (list string)) (Some none_rows) (previous_rows r1);
  let r2 = rerun ~env:[ flagged; weak ] [ mutate ] in
  whole ~outcome_line:weak_outcome r2;
  equal
    (option (list string))
    (listed [ (15, "killed \u{2192} survived") ])
    (unstable r2.out);
  is_true
    (require_some (index_of ~sub:"\u{2500} unstable (" r2.out)
    < require_some (index_of ~sub:"never reached (" r2.out));
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 killed";
         "subject.ml:18 unreached";
         "subject.ml:21 unreached";
         "subject.ml:27 unreached";
         "subject.ml:38 filtered: zero operand";
       ])
    (previous_rows r2);
  let r3 = rerun ~env:[ flagged; weak ] [ mutate ] in
  whole ~outcome_line:weak_outcome r3;
  equal (option (list string)) None (unstable r3.out);
  equal
    (option (list string))
    (Some
       [
         "subject.ml:15 survived by flagged \u{203a} needs the flag, flagged \
          \u{203a} raises the flag";
       ])
    (previous_of 15 r3);
  let r4 = rerun ~env:[ flagged ] [ mutate ] in
  whole ~outcome_line:ordered_outcome r4;
  equal
    (option (list string))
    (listed [ (15, "survived \u{2192} killed") ])
    (unstable r4.out)

let unchanged_verdict () =
  remove (verdict_path suite_exe);
  whole (rerun [ mutate ]);
  let r = rerun [ mutate ] in
  whole r;
  equal (option (list string)) None (unstable r.out);
  equal (option (list string)) (Some green_rows) (previous_rows r)

(* The verdict of [sub] changes between the two runs, but the source digest
   of the file in between is not the digest of the run. *)
let new_source () =
  remove (verdict_path suite_exe);
  ignore (rerun ~env:[ flagged ] [ mutate ]);
  rewrite (fun r -> { r with source_digest = Some (String.make 32 '0') });
  let r = rerun ~env:[ flagged; weak ] [ mutate ] in
  whole ~outcome_line:weak_outcome r;
  equal (option (list string)) None (unstable r.out);
  equal (option (list string)) (Some none_rows) (previous_rows r)

let another_killing_test () =
  remove (verdict_path suite_exe);
  let ordered = suite "ordered" in
  whole ~outcome_line:ordered_outcome (rerun ~env:[ ordered ] [ mutate ]);
  rewrite (killed_by [ "ordered"; "watches sub again without pinning it" ]);
  let r = rerun ~env:[ ordered ] [ mutate ] in
  whole ~outcome_line:ordered_outcome r;
  equal (option (list string)) None (unstable r.out);
  equal
    (option (list string))
    (Some [ "subject.ml:15 killed" ]) (previous_of 15 r)

(* Other reaching tests of a survivor, and a change from or to a mutant that
   no test reached, are not a change of class. *)
let same_class () =
  remove (verdict_path suite_exe);
  whole (rerun [ mutate ]);
  rewrite (at_line 18 (Verdicts.survived [ [ "widen"; "another test" ] ]));
  let r1 = rerun [ mutate ] in
  whole r1;
  equal (option (list string)) None (unstable r1.out);
  rewrite (fun r ->
      at_line 18 Verdicts.Unreached
        (at_line 21 (Verdicts.survived [ [ "widen"; "widen is nonzero" ] ]) r));
  let r2 = rerun [ mutate ] in
  whole r2;
  equal (option (list string)) None (unstable r2.out);
  equal (list string)
    [
      "subject.ml:18 unreached";
      "subject.ml:21 survived by widen \u{203a} widen is nonzero";
    ]
    (List.concat_map
       (fun line -> require_some (previous_of line r2))
       [ 18; 21 ])

let killed_elsewhere_rows =
  let other = Verdicts.Killed_elsewhere { exe = "default/test/other.exe" } in
  [
    ("a killed mutant", 15, other, None);
    ("a survivor", 18, other, listed [ (18, "killed \u{2192} survived") ]);
  ]

let killed_elsewhere_is_killed (_, line, verdict, expected) =
  remove (verdict_path suite_exe);
  whole (rerun [ mutate ]);
  rewrite (at_line line verdict);
  let r = rerun [ mutate ] in
  whole r;
  equal (option (list string)) expected (unstable r.out)

(* The mutant of [widen] is killed in a new process, which evaluates its
   site, and is not evaluated in a fork, which reads the answer of the dry
   run. *)
let memo_orders =
  [
    ( "killed, then not evaluated",
      [ exec_children ],
      [],
      listed [ (18, "killed \u{2192} not evaluated") ] );
    ( "not evaluated, then killed",
      [],
      [ exec_children ],
      listed [ (18, "not evaluated \u{2192} killed") ] );
  ]

let not_evaluated_class (_, first, second, expected) =
  remove (verdict_path suite_exe);
  let fixture = suite "memo" in
  ignore (rerun ~env:(fixture :: first) [ mutate ]);
  let r = rerun ~env:(fixture :: second) [ mutate ] in
  equal string "exited 0" r.status;
  equal (option (list string)) expected (unstable r.out)

let catalogue_order () =
  let path = verdict_path suite_exe in
  remove path;
  whole (rerun [ mutate ]);
  rewrite (fun r ->
      at_line 15
        (Verdicts.survived [ [ "calc"; "sub of two positives" ] ])
        (at_line 18 (Verdicts.Killed { by = None }) r));
  let planted = read path in
  let one = rerun [ mutate ] in
  whole one;
  write path planted;
  let four = rerun [ mutate; jobs 4 ] in
  whole four;
  equal
    (option (list string))
    (listed
       [ (15, "survived \u{2192} killed"); (18, "killed \u{2192} survived") ])
    (unstable one.out);
  equal (option (list string)) (unstable one.out) (unstable four.out)

(* The writer of the file in between is another build. *)
let other_build () =
  remove (verdict_path suite_exe);
  whole (rerun [ mutate ]);
  rewrite ~digest:(String.make 32 '0')
    (at_line 15 (Verdicts.survived [ [ "calc"; "sub of two positives" ] ]));
  let r = rerun [ mutate ] in
  whole r;
  equal
    (option (list string))
    (listed [ (15, "survived \u{2192} killed") ])
    (unstable r.out)

(* The file at the path of the suite records another suite, so the run takes
   no previous verdict from it. *)
let two_suites () =
  remove_suite_files suite_exe;
  let env = [ suite "ordered" ] in
  let first = rerun ~env [ mutate ] in
  equal (pair string text) ("exited 0", "") (first.status, first.err);
  rewrite ~suite:"other" Fun.id;
  let r = rerun ~env [ mutate ] in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (option (list string)) None (unstable r.out);
  equal (option (list string)) (Some none_rows) (previous_rows r);
  equal (option string) (Some "calc") (recorded_suite (verdict_path suite_exe))

(* Each suite of a main compares with its own file. *)
let suites_compare_alone () =
  remove_suite_files suite_exe;
  let env = [ suite "two_flagged" ] in
  let r1 = rerun ~env [ mutate ] in
  let r2 = rerun ~env:(weak :: env) [ mutate ] in
  List.iter
    (fun (r : ran) ->
      equal (pair string text) ("exited 0", "") (r.status, r.err))
    [ r1; r2 ];
  equal (list (list string)) [] (sections ~title:"unstable" r1.out);
  let change = require_some (listed [ (15, "killed \u{2192} survived") ]) in
  equal
    (list (list string))
    [ change; change ]
    (sections ~title:"unstable" r2.out);
  List.iter
    (fun name ->
      let f = require_some (saved (verdict_path ~suite:name suite_exe)) in
      equal (list string) [ "subject.ml:15 killed" ]
        (List.filter (String.starts_with ~prefix:"subject.ml:15 ") f.previous))
    [ "first"; "calc" ]

(* The selection kills [sub], so a run that wrote its file would list it. *)
let narrowed_run () =
  let path = verdict_path suite_exe in
  remove path;
  whole (rerun [ mutate ]);
  rewrite
    (at_line 15 (Verdicts.survived [ [ "calc"; "sub of two positives" ] ]));
  let planted = read path in
  let r = rerun [ mutate; "-f"; "calc" ] in
  equal (pair string text) ("exited 0", not_saved) (r.status, r.err);
  equal (option (list string)) None (unstable r.out);
  equal text planted (read path)

(* [interrupted] commits [sub] as a survivor before the signal. *)
let stopped_run () =
  let planted = (require_some (Lazy.force green).file).raw in
  let r, grandchildren, left = interrupted_by ~planted Sys.sigint in
  equal string "killed by SIGINT" r.status;
  equal (option (list string)) None (unstable r.out);
  equal text planted (read (verdict_path suite_exe));
  equal (list string) [] left;
  equal (list string) [ "gone" ] grandchildren

(* The first run kills [sub], and a weak run lets it survive. The second
   run cannot write into the read-only directory of the file, so it lists
   nothing. The third run can, and lists the change. *)
let unwritable_with_prior () =
  if Unix.geteuid () = 0 then skip ~reason:"root writes any directory" ();
  let p = skip_project () in
  let weak_run () =
    fst (skip_run ~fixture:"flagged" ~env:[ weak ] ~keep:true p [])
  in
  equal string "exited 0" (fst (skip_run ~fixture:"flagged" p [])).status;
  let planted = read (verdict_path p.exe) in
  Unix.chmod p.data 0o555;
  let r = Fun.protect ~finally:(fun () -> Unix.chmod p.data 0o755) weak_run in
  equal string "exited 0" r.status;
  starts_with ~affix:"windtrap: could not write the verdict file: " r.err;
  equal (option (list string)) None (unstable r.out);
  equal text planted (read (verdict_path p.exe));
  let r = weak_run () in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal
    (option (list string))
    (listed [ (15, "killed \u{2192} survived") ])
    (unstable r.out)

(* The partitions of an inline runner *)

let partition_suite name = "partitions/" ^ name
let part_a = "part_a.ml"
let part_b = "part_b.ml"

let partition_file name =
  verdict_path ~suite:(partition_suite name) partitions_exe

let partition_args name =
  [ "inline-test-runner"; "partitions"; "-partition"; name ]

(* A partition run in the scratch directory [cwd], with its verdict file. *)
let partition ?(env = []) ~cwd name =
  let r =
    Child.run ~cwd
      ~env:(quiet (mutate_mirror :: env))
      partitions_exe (partition_args name)
  in
  {
    status = ended r.Child.status;
    out = r.Child.out;
    err = r.Child.err;
    file = saved (partition_file name);
  }

let part_a_rows = first_rows

let part_b_rows =
  [
    "subject.ml:15 unreached";
    "subject.ml:18 killed";
    "subject.ml:21 unreached";
    "subject.ml:27 unreached";
    "subject.ml:38 filtered: zero operand";
  ]

let partition_files () =
  List.sort String.compare [ partition_file part_a; partition_file part_b ]

(* Three rounds over the two partitions, which dune runs at the same time.
   Each partition lists its own change, whatever the order of the runs. *)
let partition_rounds () =
  remove_suite_files partitions_exe;
  let cwd = temp_dir () in
  let round ?env order =
    let runs = List.map (fun name -> (name, partition ?env ~cwd name)) order in
    List.iter
      (fun (_, (r : ran)) ->
        equal (pair string text) ("exited 0", "") (r.status, r.err))
      runs;
    equal (list string) (partition_files ()) (suite_files partitions_exe);
    equal (list string) [] (entries cwd);
    fun name -> List.assoc name runs
  in
  let r = round [ part_a; part_b ] in
  equal (option (list string)) None (unstable (r part_a).out);
  equal (option (list string)) None (unstable (r part_b).out);
  equal (option (list string)) (Some part_a_rows) (rows (r part_a));
  equal (option (list string)) (Some part_b_rows) (rows (r part_b));
  let r = round ~env:[ weak ] [ part_a; part_b ] in
  equal
    (option (list string))
    (listed [ (15, "killed \u{2192} survived") ])
    (unstable (r part_a).out);
  equal
    (option (list string))
    (listed [ (18, "killed \u{2192} survived") ])
    (unstable (r part_b).out);
  let r = round [ part_b; part_a ] in
  equal
    (option (list string))
    (listed [ (15, "survived \u{2192} killed") ])
    (unstable (r part_a).out);
  equal
    (option (list string))
    (listed [ (18, "survived \u{2192} killed") ])
    (unstable (r part_b).out)

let concurrent_partitions () =
  remove_suite_files partitions_exe;
  let started =
    List.map
      (fun name ->
        start ~exe:partitions_exe ~writer:partitions_exe
          ~suite:(partition_suite name) ~env:[ mutate_mirror ]
          (partition_args name))
      [ part_a; part_b ]
  in
  let finished = List.map finish started in
  List.iter
    (fun (r : ran) ->
      equal (pair string text) ("exited 0", "") (r.status, r.err))
    finished;
  equal (list string) (partition_files ()) (suite_files partitions_exe);
  equal
    (list (option (list string)))
    [ Some part_a_rows; Some part_b_rows ]
    (List.map (fun (r : ran) -> rows r) finished)

let suites =
  group "Suites"
    [
      test
        "the partitions of an inline runner each keep their file and list \
         their own rows"
        partition_rounds;
      test "two partitions that run at the same time each write their file"
        concurrent_partitions;
    ]

let unstable_verdicts =
  group "Unstable verdicts"
    [
      test
        "a verdict that changed is listed, and the file keeps the previous \
         verdict"
        changed_verdict;
      test
        "a verdict that did not change is not listed, and is its own previous \
         verdict"
        unchanged_verdict;
      test "a changed source digest gives no previous verdict" new_source;
      test "another killing test is not a change" another_killing_test;
      test
        "other reaching tests, and a change from or to unreached, are not a \
         change"
        same_class;
      cases "killed elsewhere is killed"
        ~name:(fun (name, _, _, _) -> name)
        killed_elsewhere_rows killed_elsewhere_is_killed;
      cases "not evaluated is a class of its own"
        ~name:(fun (name, _, _, _) -> name)
        memo_orders not_evaluated_class;
      test
        "the rows are in catalogue order, and the same for each value of jobs"
        catalogue_order;
      test "a file of another build gives the previous verdicts" other_build;
      test "a file of another suite gives no previous verdict" two_suites;
      test
        "a main with two suites lists the unstable rows of each suite on the \
         next run"
        suites_compare_alone;
      test "a narrowed run lists nothing and leaves the file" narrowed_run;
      test
        "a run that a signal stopped before its last verdict lists nothing and \
         leaves the file"
        stopped_run;
      test "a run whose file cannot be written lists nothing"
        unwritable_with_prior;
    ]

(* Survivors that run again *)

(* A run of [intermittent], and the lines of the file of MUTATE_RUNS. With
   [~keep:true], the run reads the verdict file of the run before it. *)
let intermittent ?(keep = false) ?(env = []) args =
  let runs = Filename.concat (temp_dir ()) "runs" in
  let env = [ suite "intermittent"; ("MUTATE_RUNS", runs) ] @ env in
  let r =
    if not keep then spawn ~env (mutate :: args)
    else
      let c = Child.run ~env:(quiet env) suite_exe (mutate :: args) in
      {
        status = ended c.Child.status;
        out = c.Child.out;
        err = c.Child.err;
        file = saved (verdict_path suite_exe);
      }
  in
  (r, if Sys.file_exists runs then List.length (lines (read runs)) - 1 else 0)

let survived_outcome =
  "mutants: 1 survived of 1 reached by this suite, 3 never reached, 1 \
   filtered, score 0.0%"

let killed_outcome =
  "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
   score 100.0%"

let not_evaluated_outcome =
  "mutants: 1 reached by this suite, 1 not evaluated, 3 never reached, 1 \
   filtered, score 0.0%"

let not_tested_outcome =
  "mutants: 1 reached by this suite, 3 never reached, 1 filtered, 1 not tested"

let survived_by_both =
  "survived by intermittent \u{203a} widen is reached again, intermittent \
   \u{203a} widen survives each run that is not the kill"

(* The rows of [intermittent], with [verdict] on line 18. *)
let intermittent_rows verdict =
  Some
    [
      "subject.ml:15 unreached";
      "subject.ml:18 " ^ verdict;
      "subject.ml:21 unreached";
      "subject.ml:27 unreached";
      "subject.ml:38 filtered: zero operand";
    ]

let survived_rows runs =
  intermittent_rows
    (if runs > 1 then strf "%s (%d runs)" survived_by_both runs
     else survived_by_both)

(* The title of the survivor of [line] in a report. *)
let title_of line out =
  let prefix = strf "  SURVIVED  %s" (site line) in
  require_some (List.find_opt (String.starts_with ~prefix) (lines out))

let ended_well (r : ran) =
  equal (pair string text) ("exited 0", "") (r.status, r.err)

(* A run of [intermittent] that ends well, with its outcome line, the runs
   of the changed [widen] and the rows. *)
let retried ?keep ?env ~outcome_line ~runs ~rows:expected args =
  let r, n = intermittent ?keep ?env args in
  ended_well r;
  equal string outcome_line (outcome r.out);
  equal int runs n;
  equal (option (list string)) expected (rows r);
  r

let fork_default () =
  let r =
    retried ~outcome_line:survived_outcome ~runs:1 ~rows:(survived_rows 1) []
  in
  not_contains ~sub:"runs)" r.out;
  is_false (String.ends_with ~suffix:")" (title_of 18 r.out))

let survives_each_run () =
  let r =
    retried ~outcome_line:survived_outcome ~runs:3 ~rows:(survived_rows 3)
      [ "--mutate-retry=2" ]
  in
  equal (list string) [ site 18 ] (survivors r.out);
  is_true (String.ends_with ~suffix:"  (3 runs)" (title_of 18 r.out))

let killers_of_the_file () = killers (verdict_path suite_exe)

let killed_in_a_retry () =
  ignore
    (retried
       ~env:[ ("MUTATE_KILL_AT", "2") ]
       ~outcome_line:killed_outcome ~runs:2
       ~rows:(intermittent_rows "killed")
       [ "--mutate-retry=2" ]);
  equal (list string)
    [
      "subject.ml:18 intermittent \u{203a} widen survives each run that is not \
       the kill";
    ]
    (killers_of_the_file ())

let kill_past_the_bound () =
  ignore
    (retried
       ~env:[ ("MUTATE_KILL_AT", "4") ]
       ~outcome_line:survived_outcome ~runs:3 ~rows:(survived_rows 3)
       [ "--mutate-retry=2" ])

let killed_in_the_first_run () =
  ignore
    (retried
       ~env:[ ("MUTATE_KILL_AT", "1") ]
       ~outcome_line:killed_outcome ~runs:1
       ~rows:(intermittent_rows "killed")
       [ "--mutate-retry=2" ])

let mirror_of_retry () =
  let r =
    retried
      ~env:[ ("WINDTRAP_MUTATE_RETRY", "1") ]
      ~outcome_line:survived_outcome ~runs:2 ~rows:(survived_rows 2) []
  in
  is_true (String.ends_with ~suffix:"  (2 runs)" (title_of 18 r.out));
  ignore
    (retried
       ~env:[ ("WINDTRAP_MUTATE_RETRY", "5") ]
       ~outcome_line:survived_outcome ~runs:1 ~rows:(survived_rows 1)
       [ "--mutate-retry=0" ])

(* The default of a suite that spawned a domain is 2. *)
let default_with_a_domain () =
  let r =
    retried
      ~env:[ domain_init; ("MUTATE_KILL_AT", "2") ]
      ~outcome_line:killed_outcome ~runs:2
      ~rows:(intermittent_rows "killed")
      []
  in
  contains ~sub:("\n" ^ auto_line ^ "\n") r.out;
  let r =
    retried ~env:[ domain_init ] ~outcome_line:survived_outcome ~runs:3
      ~rows:(survived_rows 3) []
  in
  contains ~sub:("\n" ^ auto_line ^ "\n") r.out;
  is_true (String.ends_with ~suffix:"  (3 runs)" (title_of 18 r.out))

let domain_without_retry () =
  let r =
    retried ~env:[ domain_init ] ~outcome_line:survived_outcome ~runs:1
      ~rows:(survived_rows 1) [ "--mutate-retry=0" ]
  in
  not_contains ~sub:"runs)" r.out

let retry_in_exec_mode () =
  let r =
    retried ~env:[ exec_children ] ~outcome_line:survived_outcome ~runs:1
      ~rows:(survived_rows 1) []
  in
  contains ~sub:("\n" ^ exec_line ^ "\n") r.out;
  let r =
    retried ~env:[ exec_children ] ~outcome_line:survived_outcome ~runs:3
      ~rows:(survived_rows 3) [ "--mutate-retry=2" ]
  in
  contains ~sub:("\n" ^ exec_line ^ "\n") r.out;
  is_true (String.ends_with ~suffix:"  (3 runs)" (title_of 18 r.out))

(* The probe is the first child that runs the first test, and run 1 and run
   2 follow it. Run 2 does not evaluate the site. *)
let not_evaluated_in_a_retry () =
  let child_runs = Filename.concat (temp_dir ()) "child-runs" in
  ignore
    (retried
       ~env:[ ("MUTATE_CHILD_RUNS", child_runs); ("MUTATE_SKIP_AT", "3") ]
       ~outcome_line:not_evaluated_outcome ~runs:1
       ~rows:(intermittent_rows "not evaluated")
       [ "--mutate-retry=2" ])

(* A retry that hangs has the deadline of the first run, and a deadline kill
   names no test. *)
let hanging_retry () =
  let runs = Filename.concat (temp_dir ()) "runs" in
  remove (verdict_path suite_exe);
  let r =
    finish_within ~what:"the deadline of the retry"
      (start
         ~env:
           [
             suite "intermittent"; ("MUTATE_RUNS", runs); ("MUTATE_HANG_AT", "2");
           ]
         [ mutate; "--mutate-retry=2" ])
  in
  ended_well r;
  equal string killed_outcome (outcome r.out);
  equal int 2 (List.length (lines (read runs)) - 1);
  equal (option (list string)) (intermittent_rows "killed") (rows r);
  equal (list string) [] (killers_of_the_file ())

(* The first child runs the killing test of the file alone, and is not a
   run. *)
let first_child_is_no_run () =
  let path = verdict_path suite_exe in
  let kill_by_the_second_test () =
    rewrite (fun r ->
        if r.id = site_id 18 then
          {
            r with
            verdict =
              Verdicts.Killed
                { by = Some [ "intermittent"; "widen is reached again" ] };
          }
        else r)
  in
  remove path;
  ignore (intermittent []);
  kill_by_the_second_test ();
  let r =
    retried ~keep:true ~outcome_line:survived_outcome ~runs:3
      ~rows:(survived_rows 3) [ "--mutate-retry=2" ]
  in
  is_true (String.ends_with ~suffix:"  (3 runs)" (title_of 18 r.out));
  remove path;
  ignore (intermittent []);
  kill_by_the_second_test ();
  let r =
    retried ~keep:true ~outcome_line:survived_outcome ~runs:1
      ~rows:(survived_rows 1) []
  in
  not_contains ~sub:"runs)" r.out

(* The live line names a mutant when it has its verdict, not for each run
   of its child. *)
let live_line_of_retries () =
  let seen = Buffer.create 4096 in
  let master, slave = openpty () in
  Unix.set_nonblock master;
  remove (verdict_path suite_exe);
  let run =
    Fun.protect
      ~finally:(fun () -> Unix.close slave)
      (fun () ->
        start ~stdout:slave
          ~env:[ ("WINDTRAP_COLOR", "always") ]
          [ mutate; "--mutate-retry=2"; jobs 1 ])
  in
  let r =
    finish_within ~what:"the run on a terminal"
      ~meanwhile:(fun () -> drain master seen)
      run
  in
  drain master seen;
  Unix.close master;
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string)
    [ strf "[0/2] %s\u{2026}" (site 15); strf "[1/2] %s\u{2026}" (site 18) ]
    (List.sort_uniq String.compare (mutation_live (Buffer.contents seen)))

(* A signal that stops a retry leaves its mutant with no verdict. *)
let interrupted_retry () =
  let gates = temp_dir () and tmpdir = temp_dir () in
  let runs = Filename.concat (temp_dir ()) "runs" in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:
        [
          suite "intermittent";
          ("MUTATE_RUNS", runs);
          ("MUTATE_GATES", gates);
          ("MUTATE_GATE_AT", "2");
          ("TMPDIR", tmpdir);
        ]
      [ mutate; "--mutate-retry=2" ]
  in
  ignore (gate ~gates run "widen");
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 18)) r.err;
  equal (list string) [] (survivors r.out);
  equal string not_tested_outcome (outcome r.out);
  equal (option (list string)) None (rows r);
  equal int 2 (List.length (lines (read runs)) - 1);
  equal (list string) [] (entries tmpdir)

(* A kill in a retry gives no unstable row, because a record keeps the verdict
   alone. The runs of a survivor are not a change either. *)
let retry_and_unstable_rows () =
  let r =
    retried
      ~env:[ ("MUTATE_KILL_AT", "2") ]
      ~outcome_line:killed_outcome ~runs:2
      ~rows:(intermittent_rows "killed")
      [ "--mutate-retry=2" ]
  in
  not_contains ~sub:"unstable (" r.out;
  equal (option (list string)) (Some none_rows) (previous_rows r);
  let r =
    retried ~keep:true ~outcome_line:survived_outcome ~runs:1
      ~rows:(survived_rows 1) [ "--mutate-retry=0" ]
  in
  equal
    (option (list string))
    (listed [ (18, "killed \u{2192} survived") ])
    (unstable r.out);
  let r =
    retried ~keep:true ~outcome_line:survived_outcome ~runs:3
      ~rows:(survived_rows 3) [ "--mutate-retry=2" ]
  in
  equal (option (list string)) None (unstable r.out)

let retry =
  group "Retry"
    [
      test "a suite that spawned no domain runs the child of a survivor once"
        fork_default;
      test
        "--mutate-retry runs the child of a survivor that many more times, and \
         the report gives its runs"
        survives_each_run;
      test
        "a kill in a retry is the verdict, names its test and stops the retries"
        killed_in_a_retry;
      test "a kill past the last retry leaves the mutant a survivor"
        kill_past_the_bound;
      test "a kill in the first run ends the child without a retry"
        killed_in_the_first_run;
      test "the mirror gives the retry, and the flag hides it" mirror_of_retry;
      test
        "a suite that spawned a domain runs a survivor 3 times, and finds the \
         kill of a later run"
        default_with_a_domain;
      test "--mutate-retry=0 stops the retry of a suite that spawned a domain"
        domain_without_retry;
      test
        "in exec mode, a suite with no domain has no retry, and a retry is a \
         new process"
        retry_in_exec_mode;
      test "a retry that does not evaluate the site gives not evaluated"
        not_evaluated_in_a_retry;
      test "a retry that hangs is killed at the deadline of the first run"
        hanging_retry;
      test
        "the first child of a mutant with a history is no run, and raises \
         nothing"
        first_child_is_no_run;
      test "the live line counts a mutant once, with its retries"
        live_line_of_retries;
      test "a signal that stops a retry leaves its mutant with no verdict"
        interrupted_retry;
      test "a retry gives no unstable row" retry_and_unstable_rows;
    ]

(* Flaky kills *)

(* The test [B] of [flaky_kill] kills the mutant, and the child run that it
   fails is the line of its failure. Run 1 is the probe, 2 the alone run of
   the reaching tests, 3 the child of the mutant, and 4 to 6 the check runs.
   In fork mode, run 2 is the child. *)

let b = "kill \u{203a} fails at the given child runs"
let flaky_by n = strf "flaky by %s: child run %d" b n
let kill_rows = intermittent_rows
let killed_by_b = [ "subject.ml:18 " ^ b ]
let one_job = [ jobs 1 ]

let flaky_outcome =
  "mutants: 1 reached by this suite, 1 flaky, 3 never reached, 1 filtered"

(* The flaky section of the mutant on line 18, with the failure of run [n]. *)
let widen_flaky n =
  [
    "  A test killed each mutant, and then failed in a run with no mutant.";
    "  The score does not count these mutants.";
    strf "  %s  a + b \u{2192} a - b" (site 18);
    "    test: " ^ b;
    strf "    failure with no mutant: child run %d" n;
  ]

(* The lines of a file of counts, without the empty line at its end. *)
let line_count path =
  if Sys.file_exists path then List.length (lines (read path)) - 1 else 0

type kill_ran = {
  r : ran;
  b_runs : int; (* The runs of [B] in children. *)
  a_runs : int; (* The runs of [A] in children. *)
}

(* A run of [flaky_kill] with the counters of [A] and [B] in new files. With
   [~keep:true], the run reads the verdict file of the run before it. *)
let kill_run ?(keep = false) ?(env = []) args =
  let dir = temp_dir () in
  let b_file = Filename.concat dir "b-runs"
  and a_file = Filename.concat dir "a-runs" in
  let env =
    [
      suite "flaky_kill";
      ("MUTATE_CHILD_RUNS", b_file);
      ("MUTATE_FIRST_RUNS", a_file);
    ]
    @ env
  in
  let r =
    if keep then rerun ~env (mutate :: args) else spawn ~env (mutate :: args)
  in
  { r; b_runs = line_count b_file; a_runs = line_count a_file }

let fail_at runs = ("MUTATE_FAIL_AT", runs)

(* The previous verdict of the record on line 18. *)
let previous_of_widen r =
  Option.map
    (List.filter (String.starts_with ~prefix:"subject.ml:18 "))
    (previous_rows r)

let flaky_regression () =
  let k = kill_run ~env:[ domain_init; fail_at "3,5" ] one_job in
  equal (pair string text) ("exited 0", "") (k.r.status, k.r.err);
  equal string flaky_outcome (outcome k.r.out);
  equal int 5 k.b_runs;
  equal (option (list string)) (kill_rows (flaky_by 5)) (rows k.r);
  equal (option (list string)) (Some (widen_flaky 5)) (flaky_lines k.r.out);
  equal (list string) [] (killers_of_the_file ());
  contains ~sub:("\n" ^ auto_line ^ "\n") k.r.out

let clean_check () =
  let k = kill_run ~env:[ domain_init; fail_at "3" ] one_job in
  equal (pair string text) ("exited 0", "") (k.r.status, k.r.err);
  equal string killed_outcome (outcome k.r.out);
  equal int 6 k.b_runs;
  equal (option (list string)) (kill_rows "killed") (rows k.r);
  equal (list string) killed_by_b (killers_of_the_file ());
  equal (option (list string)) None (flaky_lines k.r.out)

let first_failing_run_stops () =
  let k = kill_run ~env:[ domain_init; fail_at "3,4" ] one_job in
  equal int 4 k.b_runs;
  equal (option (list string)) (kill_rows (flaky_by 4)) (rows k.r)

let last_run_fails () =
  let k = kill_run ~env:[ domain_init; fail_at "3,6" ] one_job in
  equal int 6 k.b_runs;
  equal (option (list string)) (kill_rows (flaky_by 6)) (rows k.r)

let no_domain_no_check () =
  let k = kill_run ~env:[ fail_at "2,3,4,5" ] one_job in
  equal string killed_outcome (outcome k.r.out);
  equal int 2 k.b_runs;
  equal (list string) killed_by_b (killers_of_the_file ());
  not_contains ~sub:auto_line k.r.out

let exec_without_domain_no_check () =
  let k = kill_run ~env:[ exec_children; fail_at "3,4,5,6" ] one_job in
  equal string killed_outcome (outcome k.r.out);
  equal int 3 k.b_runs;
  contains ~sub:exec_line k.r.out

(* Run 3 is a survivor, run 4 the first retry. *)
let kill_in_a_retry () =
  let k = kill_run ~env:[ domain_init; fail_at "4,5" ] one_job in
  equal int 5 k.b_runs;
  equal (option (list string)) (kill_rows (flaky_by 5)) (rows k.r);
  not_contains ~sub:"runs)" k.r.out

let two_killed =
  Some
    [
      "subject.ml:15 killed";
      "subject.ml:18 killed";
      "subject.ml:21 unreached";
      "subject.ml:27 unreached";
      "subject.ml:38 filtered: zero operand";
    ]

let two_flaky n =
  Some
    [
      "subject.ml:15 " ^ flaky_by n;
      "subject.ml:18 " ^ flaky_by n;
      "subject.ml:21 unreached";
      "subject.ml:27 unreached";
      "subject.ml:38 filtered: zero operand";
    ]

let kill_sub = ("MUTATE_KILL_SUB", "1")

(* Run 3 is the child of [sub], runs 4 to 6 its check, and run 7 the child of
   [widen], which gets the result of the check. *)
let one_check_clean () =
  let k = kill_run ~env:[ domain_init; kill_sub; fail_at "3,7" ] one_job in
  equal int 7 k.b_runs;
  equal string
    "mutants: 2 reached by this suite, 2 killed, 2 never reached, 1 filtered, \
     score 100.0%"
    (outcome k.r.out);
  equal (option (list string)) two_killed (rows k.r);
  equal (list string)
    [ "subject.ml:15 " ^ b; "subject.ml:18 " ^ b ]
    (killers_of_the_file ())

(* Run 4 is the first check run, and run 5 the child of [widen]. *)
let one_check_flaky () =
  let k = kill_run ~env:[ domain_init; kill_sub; fail_at "3,4,5" ] one_job in
  equal int 5 k.b_runs;
  equal string
    "mutants: 2 reached by this suite, 2 flaky, 2 never reached, 1 filtered"
    (outcome k.r.out);
  equal (option (list string)) (two_flaky 4) (rows k.r)

(* Runs 3 and 4 are the two children, and run 5 is the first check run. The
   two children wait at their gates before run 3 ends. Run 4 ends while run 5
   waits at its gate, so its mutant waits for the check. *)
let two_jobs_one_check () =
  let gates = temp_dir () in
  let b_file = Filename.concat (temp_dir ()) "b-runs" in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:
        [
          suite "flaky_kill";
          ("MUTATE_CHILD_RUNS", b_file);
          domain_init;
          kill_sub;
          fail_at "3,4,5";
          ("MUTATE_WAIT_AT", "3,4");
          ("MUTATE_HOLD_AT", "5");
          ("MUTATE_GATES", gates);
        ]
      [ mutate; jobs 2 ]
  in
  let _, open_first = gate ~gates run "kill3" in
  let second, open_second = gate ~gates run "kill4" in
  open_first ();
  let _, open_check = gate ~gates run "hold" in
  open_second ();
  reaped ~what:"the reaping of the second child" run second;
  open_check ();
  let r = finish_within ~what:"the end of the check" run in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal int 5 (line_count b_file);
  equal (option (list string)) (two_flaky 5) (rows r)

(* [A] kills the mutant and stops the child. [B] fails if it runs in the child
   or in the check, but the check runs only [A], so the kill stays. *)
let check_through_the_killing_test () =
  let k =
    kill_run
      ~env:[ domain_init; ("MUTATE_FIRST_PINS", "1"); fail_at "3,4,5,6" ]
      one_job
  in
  equal (pair string text) ("exited 0", "") (k.r.status, k.r.err);
  equal string killed_outcome (outcome k.r.out);
  equal int 2 k.b_runs;
  equal int 6 k.a_runs;
  equal (option (list string)) (kill_rows "killed") (rows k.r);
  equal (list string)
    [ "subject.ml:18 kill \u{203a} reaches widen" ]
    (killers_of_the_file ())

let check_past_its_deadline () =
  let dir = temp_dir () in
  let b_file = Filename.concat dir "b-runs" in
  remove (verdict_path suite_exe);
  let r =
    finish_within ~what:"the deadline of a check run"
      (start
         ~env:
           [
             suite "flaky_kill";
             ("MUTATE_CHILD_RUNS", b_file);
             domain_init;
             fail_at "3";
             ("MUTATE_WAIT_AT", "4");
             ("MUTATE_GATES", dir);
           ]
         [ mutate; jobs 1 ])
  in
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal string killed_outcome (outcome r.out);
  equal int 6 (line_count b_file);
  equal (list string) killed_by_b (killers_of_the_file ())

let interrupted_check () =
  let gates = temp_dir () and tmpdir = temp_dir () in
  let b_file = Filename.concat (temp_dir ()) "b-runs" in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:
        [
          suite "flaky_kill";
          ("MUTATE_CHILD_RUNS", b_file);
          domain_init;
          fail_at "3";
          ("MUTATE_WAIT_AT", "4");
          ("MUTATE_GATES", gates);
          ("TMPDIR", tmpdir);
        ]
      [ mutate; jobs 1 ]
  in
  ignore (gate ~gates run "kill4");
  Unix.kill run.pid Sys.sigint;
  let r = finish run in
  equal string "killed by SIGINT" r.status;
  equal text (strf "windtrap: interrupted while testing %s\n" (site 18)) r.err;
  equal string not_tested_outcome (outcome r.out);
  equal (option (list string)) None (rows r);
  equal int 4 (line_count b_file);
  equal (list string) [] (entries tmpdir)

(* Runs 3 and 4 are the children of [sub] and [widen], and run 5 is the
   first check run, which waits at its gate. The child of [widen] ends first
   and starts the check. The child of [sub] ends next, so [sub] waits for the
   check. [stop] gets the pid of the check run and the function that opens
   its gate, and sends SIGINT. *)
let stopped_check stop =
  let gates = temp_dir () and tmpdir = temp_dir () in
  let b_file = Filename.concat (temp_dir ()) "b-runs" in
  remove (verdict_path suite_exe);
  let run =
    start
      ~env:
        [
          suite "flaky_kill";
          ("MUTATE_CHILD_RUNS", b_file);
          domain_init;
          kill_sub;
          fail_at "3,4";
          ("MUTATE_WAIT_ARMED", "1");
          ("MUTATE_HOLD_AT", "5");
          ("MUTATE_GATES", gates);
          ("TMPDIR", tmpdir);
        ]
      [ mutate; jobs 2 ]
  in
  let _, open_widen = gate ~gates run "widen" in
  let sub, open_sub = gate ~gates run "sub" in
  open_widen ();
  let check, open_check = gate ~gates run "hold" in
  open_sub ();
  reaped ~what:"the reaping of the child of sub" run sub;
  stop run check open_check;
  let r = finish run in
  equal string "killed by SIGINT" r.status;
  equal int 5 (line_count b_file);
  equal (option (list string)) None (rows r);
  equal (list string) [] (entries tmpdir);
  r

let interrupted_shared_check () =
  let r = stopped_check (fun run _ _ -> Unix.kill run.pid Sys.sigint) in
  equal text
    (strf "windtrap: interrupted while testing %s, %s\n" (site 15) (site 18))
    r.err

(* The first check run ends while the loop is stopped, and the signal comes
   before the loop reads its end. The next check run of [widen] then never
   starts, and [sub] is the first mutant with no verdict. *)
let interrupted_between_check_runs () =
  let r =
    stopped_check (fun run check open_check ->
        Unix.kill run.pid Sys.sigstop;
        Fun.protect
          ~finally:(fun () ->
            try Unix.kill run.pid Sys.sigcont with Unix.Unix_error _ -> ())
          (fun () ->
            open_check ();
            exited ~what:"the end of the first check run" run check;
            Unix.kill run.pid Sys.sigint))
  in
  equal text (strf "windtrap: interrupted before testing %s\n" (site 15)) r.err

(* New process 1 is the startup child, 2 the probe, 3 the alone run, 4 the
   child of the mutant, and 5 the first check run. *)
let refused_check () =
  let exec_file = Filename.concat (temp_dir ()) "exec-runs" in
  remove (verdict_path suite_exe);
  let k =
    kill_run
      ~env:
        [
          domain_init;
          fail_at "3";
          ("MUTATE_EXEC_RUNS", exec_file);
          ("MUTATE_REFUSE_AT", "5");
        ]
      one_job
  in
  equal string "exited 1" k.r.status;
  equal text
    (strf
       "windtrap: %s: the tests changed after the dry run: this process has no \
        test \"%s\"\n"
       (site 18) b)
    k.r.err;
  equal int 3 k.b_runs;
  equal int 5 (line_count exec_file);
  equal bool false (Sys.file_exists (verdict_path suite_exe))

let live_line_of_a_check () =
  let seen = Buffer.create 4096 in
  let master, slave = openpty () in
  Unix.set_nonblock master;
  let b_file = Filename.concat (temp_dir ()) "b-runs" in
  remove (verdict_path suite_exe);
  let run =
    Fun.protect
      ~finally:(fun () -> Unix.close slave)
      (fun () ->
        start ~stdout:slave
          ~env:
            [
              ("WINDTRAP_COLOR", "always");
              suite "flaky_kill";
              ("MUTATE_CHILD_RUNS", b_file);
              domain_init;
              fail_at "3,5";
            ]
          [ mutate; jobs 1 ])
  in
  let r =
    finish_within ~what:"the run on a terminal"
      ~meanwhile:(fun () -> drain master seen)
      run
  in
  drain master seen;
  Unix.close master;
  equal (pair string text) ("exited 0", "") (r.status, r.err);
  equal (list string)
    [ strf "[0/1] %s\u{2026}" (site 18) ]
    (List.sort_uniq String.compare (mutation_live (Buffer.contents seen)))

(* The first child runs [B] alone, so its check does too. Runs 2 and 3 are the
   alone runs of [A; B] and [B], run 4 is the first child, and runs 5 and 6
   are its check runs. *)
let kill_of_a_first_child () =
  ignore (kill_run ~env:[ domain_init; fail_at "3" ] one_job);
  equal (list string) killed_by_b (killers_of_the_file ());
  let k = kill_run ~keep:true ~env:[ domain_init; fail_at "4,6" ] one_job in
  equal int 6 k.b_runs;
  equal int 2 k.a_runs;
  equal (option (list string)) (kill_rows (flaky_by 6)) (rows k.r);
  equal (option (list string)) None (unstable k.r.out);
  equal
    (option (list string))
    (Some [ "subject.ml:18 killed" ]) (previous_of_widen k.r)

(* A flaky record gives no first child, so the next run tests the mutant from
   a full child, and checks again. *)
let after_a_flaky_verdict () =
  ignore (kill_run ~env:[ domain_init; fail_at "3,5" ] one_job);
  let k = kill_run ~keep:true ~env:[ domain_init; fail_at "3" ] one_job in
  equal string killed_outcome (outcome k.r.out);
  equal int 6 k.b_runs;
  equal int 6 k.a_runs;
  equal (option (list string)) None (unstable k.r.out);
  equal
    (option (list string))
    (Some [ "subject.ml:18 " ^ flaky_by 5 ])
    (previous_of_widen k.r)

let flaky_kills =
  group "Flaky kills"
    [
      test
        "a kill by a test that also fails with no mutant is flaky, and the \
         report lists it"
        flaky_regression;
      test "a check with no failure keeps the kill" clean_check;
      test "the first check run that fails stops the check"
        first_failing_run_stops;
      test "a failure in the last check run gives flaky" last_run_fails;
      test "a suite that spawned no domain gets no check" no_domain_no_check;
      test "exec mode with no domain gets no check" exec_without_domain_no_check;
      test "a kill in a retry gets the check" kill_in_a_retry;
      test "one list of tests has one check, and a clean check keeps each kill"
        one_check_clean;
      test
        "one list of tests has one check, and its failure is flaky for each \
         mutant"
        one_check_flaky;
      test "two jobs share one check" two_jobs_one_check;
      test "the check runs the tests up to and with the killing test"
        check_through_the_killing_test;
      test "a check run that passes its deadline gives no failure"
        check_past_its_deadline;
      test "a signal that stops a check leaves its mutant with no verdict"
        interrupted_check;
      test
        "a signal that stops a check leaves each mutant that waits for it with \
         no verdict"
        interrupted_shared_check;
      test
        "a signal between two runs of a check stops before the first mutant \
         that waits for it"
        interrupted_between_check_runs;
      test "a check run that refuses its request ends the run" refused_check;
      test "the live line counts a mutant once, with its check"
        live_line_of_a_check;
      test "a kill of a first child gets the check over its one test"
        kill_of_a_first_child;
      test
        "after a flaky verdict, the next run tests the mutant from a full \
         child, and checks again"
        after_a_flaky_verdict;
    ]

(* The fixtures' verdict files land in the real _build/_mutants, where
   [windtrap mutants] would merge them into the tree's answer, and no rule
   runs these executables but this suite. A forked child ends past
   [at_exit], so only this process removes them. *)
let () =
  at_exit (fun () ->
      List.iter
        (fun exe ->
          remove_suite_files exe;
          remove (Instr.output_file Verdicts.format ~exe))
        [
          suite_exe;
          inline_exe;
          partitions_exe;
          runaway_exe;
          plain_exe;
          scoped_exe;
        ])

let () =
  exit
    (run "mutate loop"
       [
         running;
         population;
         dry_run;
         probe;
         children;
         requests;
         verdicts;
         xfail;
         limits;
         verdict_file;
         history;
         unstable_verdicts;
         suites;
         retry;
         flaky_kills;
         killed_elsewhere;
         environment;
         refusals;
         armed;
         reproducing;
         forks;
         jobs_group;
         exec_group;
         domains;
         signals;
         effects;
       ])
