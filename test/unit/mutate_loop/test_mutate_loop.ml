(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The loop forks, so it is observed from outside its process: each
   scenario starts suite_main.exe (or a sibling fixture) in a stated
   environment and reads what the loop decided from the dry run's summary,
   the outcome line, the survivors it named and the verdict file. How a
   report lays these out is Report_sections'. Only [drain], which reads the
   pipes of the children, and [next_look], which times the looks at a
   child, are called in this process ([never_empty], [looks]). *)

open Windtrap
module Mutate = Windtrap_runtime.Mutate
module Verdicts = Windtrap_runtime.Verdicts
module Child = Windtrap_test_support.Child

let strf = Printf.sprintf
let exe_dir = Filename.dirname Windtrap_runtime.Instr.executable
let suite_exe = Filename.concat exe_dir "suite_main.exe"
let plain_exe = Filename.concat exe_dir "plain_main.exe"
let runaway_exe = Filename.concat exe_dir "runaway/runaway_main.exe"
let inline_exe = Filename.concat exe_dir "inline/runner_main.exe"
let scoped_exe = Filename.concat exe_dir "scoped/scoped_main.exe"

(* Under --instrument-with the fixtures link an instrumented core, so every
   loop scenario passes this directory as its scope: the counts below are
   those of subject.ml, spinner.ml, inline_armed.ml and quiet.ml alone. *)
let scope = "test/unit/mutate_loop/"
let mutate = "--mutate=" ^ scope
let mutate_mirror = ("WINDTRAP_MUTATE", scope)
let jobs n = strf "--mutate-jobs=%d" n
let suite name = ("MUTATE_FIXTURE", name)

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
  | Verdicts.Survived { first; others } ->
      "survived by "
      ^ String.concat ", "
          (List.map (String.concat " \u{203a} ") (first :: others))
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

type file = {
  raw : string;
  rows : string list;
  identity : (string * string) option; (* The writer's path and digest. *)
}

let identity (i : Verdicts.identity) = (i.exe, i.digest)

let saved path =
  if not (Sys.file_exists path) then None
  else
    let raw = read path in
    match Verdicts.load path with
    | Ok (t, writer) ->
        Some
          {
            raw;
            rows = List.map row (Verdicts.records t);
            identity = Option.map identity writer;
          }
    | Error e ->
        let reason = Format.asprintf "unreadable: %a" Verdicts.pp_error e in
        Some { raw; rows = [ reason ]; identity = None }

type ran = {
  status : string;
  out : string;
  err : string;
  file : file option; (* The executable's verdict file as the run left it. *)
}

let rows r = Option.map (fun (f : file) -> f.rows) r.file

(* No test is ever reported slow, so the dry run's report is the same on
   any machine. *)
let quiet env = ("WINDTRAP_SLOW_THRESHOLD", "0") :: env

(* The executable's verdict file is removed first, so a stale file cannot
   pass a test the loop failed to write. *)
let spawn ?(exe = suite_exe) ?cwd ?(env = []) args =
  let path = Verdicts.output_file ~exe in
  remove path;
  let r = Child.run ?cwd ~env:(quiet env) exe args in
  {
    status = ended r.Child.status;
    out = r.Child.out;
    err = r.Child.err;
    file = saved path;
  }

(* A run the test watches while it goes. [stdout], when given, replaces
   the file and stays the caller's to close. *)
type started = { pid : int; out_path : string; err_path : string }

let start ?(exe = suite_exe) ?stdout ~env args =
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
  { pid; out_path; err_path }

let finish started =
  let _, status = Unix.waitpid [] started.pid in
  {
    status = ended status;
    out = read started.out_path;
    err = read started.err_path;
    file = saved (Verdicts.output_file ~exe:suite_exe);
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
        file = saved (Verdicts.output_file ~exe:suite_exe);
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

let baseline_run args ~stale =
  let root = temp_dir () in
  let file = Filename.concat root "sub.expected" in
  write file stale;
  let ran =
    spawn
      ~env:[ suite "baseline"; ("WINDTRAP_PROJECT_ROOT", root) ]
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
let no_at_exit () =
  let log = Filename.concat (temp_dir ()) "atexit" in
  let r = spawn ~env:[ suite "fatal"; ("MUTATE_ATEXIT_LOG", log) ] [ mutate ] in
  equal string "exited 0" r.status;
  equal text "" r.err;
  equal string
    "mutants: 1 survived of 3 reached by this suite, 2 killed, 1 never \
     reached, 1 filtered, score 66.7%"
    (outcome r.out);
  equal int 1 (List.length (pids (read log)))

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

let inline_loop () =
  let r, left = inline_run [ mutate_mirror ] in
  equal string "exited 0" r.status;
  equal text "" r.err;
  contains ~sub:"inline_armed: 1 passed" r.out;
  equal string
    "mutants: 1 reached by this suite, 1 killed, 3 never reached, 1 filtered, \
     score 100.0%"
    (outcome r.out);
  equal (list string) [ "inline_armed.ml" ] left

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
   microseconds, where a kill by the deadline waits out its one-second
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
     remove (Verdicts.output_file ~exe:suite_exe);
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  remove (Verdicts.output_file ~exe:suite_exe);
  taskset

(* [hung] reaches two mutants, so on one CPU 16 jobs give two children,
   which share the CPU, and each child of [hung] blocks until its deadline,
   two seconds or more. With the 16 jobs of the command line, the deadline
   would be sixteen seconds or more. *)
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
  at_least float_exact ~than:2.0 elapsed;
  less float_exact ~than:8.0 elapsed

(* [spinners] reaches two mutants, and each child uses the CPU until its
   deadline, about one second for one job. On one CPU, 2 jobs give two
   children for each CPU. Thus each deadline is two seconds, and each child
   gets half of the CPU, so it uses about one second of CPU time. The wait
   of each child for the other one does not move its deadline again: with
   that wait, each child used two seconds. The loop reaps its children and
   this test reaps the loop, so [tms_cutime] and [tms_cstime] hold their CPU
   time. *)
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
  less float_exact ~than:3.0 used

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
   deadlines of about 1 second. The time that a child waits for a CPU does
   not count, so the probe agrees and the mutant survives. *)
let starve fixture test_name =
  if not (Sys.file_exists "/proc/self/schedstat") then
    skip ~reason:"the system does not give the time that a process waits" ();
  let taskset = one_cpu () in
  let hogs =
    List.init 4 (fun _ ->
        Unix.create_process_env taskset
          [| taskset; "-c"; "0"; suite_exe |]
          (Child.environment [ suite "hog" ])
          Unix.stdin Unix.stdout Unix.stderr)
  in
  let stop pid =
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    ignore (Unix.waitpid [] pid)
  in
  let r =
    Fun.protect ~finally:(fun () -> List.iter stop hogs) @@ fun () ->
    finish_within ~seconds:30. ~what:"the starved probe and child"
      (start ~exe:taskset
         ~env:[ suite fixture ]
         [ "-c"; "0"; suite_exe; mutate ])
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

(* In [burn_then_sleep], the deadline is about 2.2 seconds. The subprocess
   of the child waits for the CPU 4 times as long as it uses it, and ends
   after about 3.5 seconds. Then the child sleeps 0.9 seconds, and ends
   after about 4.4 seconds. The loop keeps the wait of the subprocess from
   its last read, and loses the wait after that read. The loop reads at
   least every 0.1 seconds, so it loses little of the wait. A loop that
   read again only when the wait of its last read was used up read at 2.2
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
      test "a child's deadline is at least one second" (fun () ->
          let b = Lazy.force blocked in
          equal string "exited 0" b.run.status;
          at_least float_exact ~than:1.0 b.elapsed);
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
  let path = Verdicts.output_file ~exe:suite_exe in
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
    source_digest = None;
    verdict = Verdicts.Killed { by = None };
  }

let rerun_over ?identity collection =
  let path = Verdicts.output_file ~exe:suite_exe in
  Verdicts.save ?identity path (Verdicts.add collection elsewhere);
  let r = Child.run ~env:(quiet []) suite_exe [ mutate ] in
  equal string "exited 0" (ended r.Child.status);
  equal text "" r.Child.err;
  Option.map (fun (f : file) -> f.rows) (saved path)

let kept_by_build () =
  let whole = require_some (Lazy.force green).file in
  let path = Verdicts.output_file ~exe:suite_exe in
  write path whole.raw;
  let collection, identity =
    require_ok ~pp:Verdicts.pp_error (Verdicts.load path)
  in
  let other_build =
    Option.map
      (fun (i : Verdicts.identity) -> { i with digest = String.make 32 '0' })
      identity
  in
  equal
    (option (list string))
    (Some ("elsewhere/other.ml:1 killed" :: green_rows))
    (rerun_over ?identity collection);
  equal
    (option (list string))
    (Some green_rows)
    (rerun_over ?identity:other_build collection);
  equal (option (list string)) (Some green_rows) (rerun_over collection)

let failed_run () =
  let log = temp_dir () in
  let first = spawn ~env:[ suite "flip"; ("MUTATE_FLIP", "1") ] [ "-o"; log ] in
  let r = spawn ~env:[ suite "flip" ] [ mutate; "--failed"; "-o"; log ] in
  equal string "exited 1" first.status;
  equal string "exited 0" r.status;
  contains ~sub:"reached by the 1 selected test" (outcome r.out);
  equal text not_saved r.err

(* A copy of the suite under a scratch build directory whose _mutants is a
   file. *)
let unwritable () =
  let root = temp_dir () in
  let build = Filename.concat root "_build" in
  let exe = Filename.concat build "default/suite_main.exe" in
  Sys.mkdir build 0o755;
  Sys.mkdir (Filename.dirname exe) 0o755;
  write exe (read suite_exe);
  Unix.chmod exe 0o755;
  write (Filename.concat build "_mutants") "a file\n";
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
  | Ok (t, _) ->
      List.filter_map
        (fun (r : Verdicts.record) ->
          match r.verdict with
          | Verdicts.Killed { by = Some test } ->
              Some
                (strf "%s:%d %s" (local r.id.file) r.id.line
                   (String.concat " \u{203a} " test))
          | Verdicts.Killed { by = None }
          | Verdicts.Survived _ | Verdicts.Not_evaluated
          | Verdicts.Outside_tests | Verdicts.Filtered _ | Verdicts.Unreached ->
              None)
        (Verdicts.records t)

(* The verdict file of [suite_main.exe] with [change] applied to each
   record, written by the same build. *)
let rewrite change =
  let path = Verdicts.output_file ~exe:suite_exe in
  let t, identity = require_ok ~pp:Verdicts.pp_error (Verdicts.load path) in
  Verdicts.save ?identity path
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

let first_tests () =
  let path = Verdicts.output_file ~exe:suite_exe in
  remove path;
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path);
  equal
    (pair string (list string))
    (ordered_outcome, [ "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

let changed_source () =
  let path = Verdicts.output_file ~exe:suite_exe in
  remove path;
  ignore (ordered_run ());
  rewrite (fun r -> { r with source_digest = Some (String.make 32 '0') });
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

(* The record [r] with [test] as its killing test, when it is killed. *)
let killed_by test (r : Verdicts.record) =
  match r.verdict with
  | Verdicts.Killed _ -> { r with verdict = Verdicts.Killed { by = Some test } }
  | Verdicts.Survived _ | Verdicts.Not_evaluated | Verdicts.Outside_tests
  | Verdicts.Filtered _ | Verdicts.Unreached ->
      r

let first_test_passes () =
  let path = Verdicts.output_file ~exe:suite_exe in
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
  let path = Verdicts.output_file ~exe:suite_exe in
  remove path;
  ignore (ordered_run ());
  rewrite (killed_by [ "ordered"; "pinned sub" ]);
  equal
    (pair string (list string))
    (ordered_outcome, [ "watches"; "pins" ])
    (ordered_run ());
  equal (list string) [ pinned_by ] (killers path)

let not_evaluated_first () =
  let path = Verdicts.output_file ~exe:suite_exe in
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
  let path = Verdicts.output_file ~exe:suite_exe in
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
  let path = Verdicts.output_file ~exe:suite_exe in
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
      cases
        "a verdict file that does not load gives no history, and the run \
         replaces it"
        ~name:fst
        [
          ("a file of 0.2.0", fun _ -> "windtrap-mutants-v3\n");
          ("bytes after the last record", fun raw -> raw ^ "junk\n");
        ]
        (fun (_, damage) -> unloadable damage ());
    ]

let verdict_file =
  group "The verdict file"
    [
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
        "a suite that spawned a domain is refused, since the loop cannot fork"
        (fun () ->
          let r = spawn ~env:[ suite "domain" ] [ mutate ] in
          equal (pair string text)
            ("exited 1", "calc: 1 passed in <time>.\n")
            (r.status, masked r.out);
          equal text
            "windtrap: this process has spawned a domain, and OCaml refuses \
             Unix.fork in a process that has: mutation testing runs every \
             mutant in a forked child, so it cannot run in this one. Exclude \
             the tests that spawn a domain (-e) to test the rest\n"
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
   it reaps the child, while the other child continues to run. *)
let nothing_left () =
  let gates = temp_dir () and tmpdir = temp_dir () in
  let run =
    start
      ~env:[ suite "stalled"; ("MUTATE_GATES", gates); ("TMPDIR", tmpdir) ]
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
  equal int 2 (List.length both);
  open_first ();
  reaped ~what:"the reaping of the first child" run first;
  until ~what:"the removal of the first child's log directory" run (fun () ->
      List.length (logs ()) = 1);
  let left = logs () in
  is_true (List.for_all (fun entry -> List.mem entry both) left);
  open_second ();
  let r = finish_within ~what:"the end of the second child" run in
  equal string "exited 0" r.status;
  equal (list string) [] (entries tmpdir)

(* The two children of [fixture], [stalled] or [queued], wait at their
   gates, and standard output is a pipe that this test fills. The child of
   [sub] ends first, and the loop blocks in the write of its survivor. The
   child of [widen] then ends while the loop is blocked, except when
   [widen_ends] is false. [meanwhile] gets the pid of that child, and acts
   before this test reads the pipe to its end. The result holds what the
   loop wrote. *)
let stalled_report ?(fixture = "stalled") ?(widen_ends = true) meanwhile =
  let gates = temp_dir () and tmpdir = temp_dir () in
  remove (Verdicts.output_file ~exe:suite_exe);
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
  let r, tmpdir = stalled_report (fun _ _ -> Unix.sleepf (1.5 *. share)) in
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
      test "children of several jobs run at once" at_once;
      test "children of one job run one at a time" one_at_a_time;
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  let path = Verdicts.output_file ~exe:suite_exe in
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
let interrupted_by signal =
  let pidfile = Filename.concat (temp_dir ()) "hanging"
  and tmpdir = temp_dir () in
  remove (Verdicts.output_file ~exe:suite_exe);
  let run =
    start
      ~env:
        [
          suite "interrupted";
          ("MUTATE_GRANDCHILD_PIDFILE", pidfile);
          ("TMPDIR", tmpdir);
        ]
      [ mutate ]
  in
  await ~what:"the hanging child" run pidfile;
  Unix.kill run.pid signal;
  let r = finish run in
  (r, List.map fate (pids (read pidfile)), entries tmpdir)

let interrupted_outcome =
  "mutants: 1 survived of 3 reached by this suite, 1 never reached, 1 \
   filtered, 2 not tested, score 0.0%"

let stopped () =
  let r, grandchildren, left = interrupted_by Sys.sigint in
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
  let path = Verdicts.output_file ~exe:suite_exe in
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  remove (Verdicts.output_file ~exe:suite_exe);
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
  let path = Verdicts.output_file ~exe:suite_exe in
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

(* The fixtures' verdict files land in the real _build/_mutants, where
   [windtrap mutants] would merge them into the tree's answer, and no rule
   runs these executables but this suite. A forked child ends past
   [at_exit], so only this process removes them. *)
let () =
  at_exit (fun () ->
      List.iter
        (fun exe -> remove (Verdicts.output_file ~exe))
        [ suite_exe; inline_exe; runaway_exe; plain_exe; scoped_exe ])

let () =
  exit
    (run "mutate loop"
       [
         running;
         population;
         dry_run;
         probe;
         children;
         verdicts;
         xfail;
         limits;
         verdict_file;
         history;
         environment;
         refusals;
         armed;
         reproducing;
         forks;
         jobs_group;
         signals;
         effects;
       ])
