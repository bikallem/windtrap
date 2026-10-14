(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Not mutated. The scheduler, the run state, the report and this loop judge
   mutants, and a mutant armed among them does not fail the tests that reach
   it: it hangs them or corrupts the verdict. Coverage still measures these
   files. *)
[@@@mutate exclude_file]

module Mutate = Windtrap_runtime.Mutate
module Verdicts = Windtrap_runtime.Verdicts

let strf = Printf.sprintf

type run = Ran of (Run.outcome, Run.startup_error) result | Reported of int

let refuse message =
  Os.say message;
  Reported 1

let ordinary ~suite (config : Run.config) tests =
  Ran (Report.run ~suite { config with mutation = Run.No_mutation } tests)

(* Population *)

(* The mutants that a run tests: those whose file starts with one of
   [prefixes], every one for none, and then only those on a line that
   changed since the revision of [since]. *)
type scope = {
  prefixes : string list;
  since : (string * Changed_lines.t) option; (* the revision and its lines *)
}

let in_scope ~scope (id : Mutate.id) =
  (scope.prefixes = []
  || List.exists
       (fun prefix -> String.starts_with ~prefix id.file)
       scope.prefixes)
  &&
  match scope.since with
  | None -> true
  | Some (_, lines) -> Changed_lines.mem lines ~file:id.file ~line:id.line

(* The changed lines are read only for a catalogue that has a mutant: an
   executable with none has no line to keep, and it must not need git. *)
let resolve_scope ~prefixes ~since =
  match since with
  | None -> Ok { prefixes; since = None }
  | Some _ when Mutate.catalogue () = [] -> Ok { prefixes; since = None }
  | Some rev -> (
      let lines =
        match Os.project_root () with
        | root -> Changed_lines.of_git ~root rev
        | exception Sys_error reason -> Error reason
      in
      match lines with
      | Ok lines -> Ok { prefixes; since = Some (rev, lines) }
      | Error reason -> Error (strf "--mutate-since=%s: %s" rev reason))

type no_mutant = Uninstrumented | Out_of_scope | All_dismissed

let population ~scope =
  let catalogue = Mutate.catalogue () in
  let scoped =
    List.filter (fun (m : Mutate.mutant) -> in_scope ~scope m.id) catalogue
  in
  let undismissed =
    List.filter (fun (m : Mutate.mutant) -> Option.is_none m.dismissed) scoped
  in
  match (catalogue, scoped, undismissed) with
  | [], _, _ when scope.prefixes = [] -> Error Uninstrumented
  | _, [], _ -> Error Out_of_scope
  | _, _, [] -> Error All_dismissed
  | _, _, population -> Ok population

(* The mutants of the scope that the rewriter filtered, each with its
   reason. They are not tested, and their verdicts say why. *)
let filtered ~scope =
  List.filter_map
    (fun (m : Mutate.mutant) ->
      match m.dismissed with
      | Some (Mutate.Filtered reason) when in_scope ~scope m.id ->
          Some (m, reason)
      | Some (Mutate.Off _ | Mutate.Filtered _) | None -> None)
    (Mutate.catalogue ())

(* A prefix that leaves nothing is one sentence whatever the catalogue holds:
   the prefix is what the reader typed, and a build that is instrumented and
   fine must not be blamed for it. *)
let refusal ~scope = function
  | Uninstrumented ->
      "this executable links no instrumented module, so there is nothing to \
       mutate: instrument the library under test with ppx_windtrap.mutate and \
       re-run"
  | Out_of_scope -> (
      match (scope.prefixes, scope.since) with
      | prefixes, None ->
          strf
            "--mutate=%s leaves no mutant in this executable's catalogue: no \
             instrumented file matches the prefix (is the library under test \
             instrumented with ppx_windtrap.mutate?), or the matched files \
             have no mutation sites"
            (String.concat "," prefixes)
      | [], Some (rev, _) ->
          strf
            "--mutate-since=%s leaves no mutant in this executable's \
             catalogue: no mutation site is on a line that changed since %s"
            rev rev
      | prefixes, Some (rev, _) ->
          strf
            "--mutate=%s and --mutate-since=%s leave no mutant in this \
             executable's catalogue: no mutation site under the prefix is on a \
             line that changed since %s"
            (String.concat "," prefixes)
            rev rev)
  | All_dismissed ->
      "every mutant this run could test is dismissed by [@mutate off] or \
       filtered by the rewriter; there is nothing to test"

let unmutated ~scope reason =
  let why =
    match reason with
    | Uninstrumented -> "this executable links no instrumented module"
    | Out_of_scope -> (
        match (scope.prefixes, scope.since) with
        | prefixes, None ->
            strf "no mutant of this executable's catalogue is under %s"
              (String.concat "," prefixes)
        | [], Some (rev, _) ->
            strf
              "no mutant of this executable's catalogue is on a line that \
               changed since %s"
              rev
        | prefixes, Some (rev, _) ->
            strf
              "no mutant of this executable's catalogue under %s is on a line \
               that changed since %s"
              (String.concat "," prefixes)
              rev)
    | All_dismissed ->
        "every mutant this run could test is dismissed by [@mutate off] or \
         filtered by the rewriter"
  in
  strf "WINDTRAP_MUTATE is set, but %s, so the suite runs without mutation" why

(* The reach map *)

type site = {
  mutable tests : string list list; (* the reaching tests, newest first *)
  mutable hits : int; (* the drained evaluations, saturating at [max_int] *)
}

(* Filled by the dry run's observer, which only writes: an observer that
   raises ends the run. *)
type reach = {
  sites : (Mutate.id, site) Hashtbl.t;
  outside : (Mutate.id, unit) Hashtbl.t; (* evaluated outside every test *)
  durations : (string, float) Hashtbl.t; (* seconds, by path string *)
  mutable executed : string list list; (* newest first *)
  mutable skipped : int;
}

let is_skip (r : Run.result) =
  match r.outcome with
  | Failure.Skip _ -> true
  | Failure.Pass | Failure.Fail _ -> false

(* What a drain outside every test collected: module initialization and
   fixture releases, which a warm-forked child cannot arm. *)
let evaluated_outside reach =
  List.iter
    (fun (r : Mutate.reached) -> Hashtbl.replace reach.outside r.mutant.id ())
    (Mutate.drain ())

(* The drain at [Test_started] precedes the epoch bump, so it collects what
   ran outside any test. A test marked xfail reaches no mutant, so what it
   evaluated is drained and dropped. *)
let observe reach (event : Run.event) =
  match event with
  | Run.Run_started _ | Run.Shrinking _ | Run.Shrunk _ | Run.Fixture_release _
  | Run.Interrupted _ ->
      ()
  | Run.Test_started _ ->
      evaluated_outside reach;
      Mutate.next_epoch ()
  | Run.Test_finished result ->
      let add (reached : Mutate.reached) =
        match Hashtbl.find_opt reach.sites reached.mutant.id with
        | None ->
            Hashtbl.add reach.sites reached.mutant.id
              { tests = [ result.path ]; hits = reached.hits }
        | Some site ->
            site.tests <- result.path :: site.tests;
            site.hits <-
              (if site.hits > max_int - reached.hits then max_int
               else site.hits + reached.hits)
      in
      let reached = Mutate.drain () in
      if Option.is_none result.xfail then List.iter add reached;
      reach.executed <- result.path :: reach.executed;
      Hashtbl.replace reach.durations
        (Test_tree.path_to_string result.path)
        result.duration;
      if is_skip result then reach.skipped <- reach.skipped + 1

(* Signals *)

(* A child is a session of its own, which a terminal's signal does not reach,
   so the handler kills the group of every running child. It prints nothing:
   it runs at a safepoint of whatever the parent was doing, the report
   included. *)
type interrupt = {
  mutable signal : int option; (* the first signal received *)
  mutable children : int list; (* the running children, until each is reaped *)
}

let interrupt = { signal = None; children = [] }

(* The group exists once the child has run [setsid]. *)
let kill_group pid =
  (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ());
  try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

(* SIGPIPE's default action would kill the parent inside a write of the
   report, past every [Fun.protect]; handled, the write fails with
   [Sys_error] and unwinds. *)
let with_interrupts fn =
  interrupt.signal <- None;
  interrupt.children <- [];
  let handle signal =
    if Option.is_none interrupt.signal then interrupt.signal <- Some signal;
    List.iter kill_group interrupt.children
  in
  Os.with_signals [ Sys.sigpipe; Sys.sigint; Sys.sigterm; Sys.sighup ] handle fn

(* The signals by which a child dies when an interrupt stops it: the one of
   the handler, and those that reach every process of the tree. *)
let interrupting = [ Sys.sigkill; Sys.sigint; Sys.sigterm; Sys.sighup ]

(* Children *)

(* The parent lost track of a child: a score over children it does not
   supervise is no score. *)
exception Supervision of string

let failed call error =
  Supervision (strf "%s failed: %s" call (Unix.error_message error))

let domain_refusal =
  "this process has spawned a domain, and OCaml refuses Unix.fork in a process \
   that has: mutation testing runs every mutant in a forked child, so it \
   cannot run in this one. Exclude the tests that spawn a domain (-e) to test \
   the rest"

(* Buffered bytes duplicated into a child would print twice. *)
let flush_descriptors () =
  Format.pp_print_flush Format.std_formatter ();
  Format.pp_print_flush Format.err_formatter ();
  (try flush Stdlib.stdout with Sys_error _ -> ());
  try flush Stdlib.stderr with Sys_error _ -> ()

(* A mutated program can print from anywhere, and hundreds of children would
   bury the report. The verdict pipe is a descriptor of its own. *)
let silence_output () =
  match Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o600 with
  | exception Unix.Unix_error _ -> ()
  | fd ->
      Unix.dup2 fd Unix.stdout;
      Unix.dup2 fd Unix.stderr;
      if fd <> Unix.stdout && fd <> Unix.stderr then Unix.close fd

let rec write_all fd s offset =
  if offset < String.length s then
    match Unix.write_substring fd s offset (String.length s - offset) with
    | written -> write_all fd s (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd s offset

(* No exception, a fatal one included, reaches Stdlib's exit machinery: its
   [at_exit] functions, the coverage dump among them, would write over the
   parent's files. *)
let in_child fd body =
  let line =
    match
      silence_output ();
      body ()
    with
    | line -> line
    | exception _ -> "crashed"
  in
  (try write_all fd (line ^ "\n") 0 with _ -> ());
  Unix._exit 0

(* A child that the parent started and did not reap. *)
type running = {
  pid : int;
  pipe : Unix.file_descr; (* the read end of the child's verdict pipe *)
  output : Buffer.t;
      (* what the parent read from [pipe], [output_limit] at most *)
  started : Os.counter;
  deadline : float; (* seconds after [started] *)
  share : float; (* the children for each CPU that [deadline] pays for *)
  log_dir : string; (* removed once the child is reaped *)
  threads : (int, float * float) Hashtbl.t;
      (* the last CPU time and wait for a CPU that the parent read of each
         thread of the group of the child, by thread id ([read_threads]) *)
}

(* How a child ended: it closed its pipe, or the parent killed its group at
   its deadline or on a signal. *)
type ending = Closed | Expired | Interrupted

type child = {
  line : string; (* the first newline-terminated line, or [""] *)
  status : Unix.process_status;
  ending : ending;
}

(* [setsid] puts the child and whatever its tests spawn in one group, which
   one signal kills. The pipe is close-on-exec: a process a test execs must
   not hold it open past its group's death. A child closes the pipes of its
   [siblings] and forgets their pids: it reads no pipe, and kills no group.

   XXX a second signal between [fork] returning and the pid being recorded
   kills the parent with the child alive. *)
let start ~deadline ~share ~log_dir ~siblings body =
  flush_descriptors ();
  let read_fd, write_fd =
    try Unix.pipe ~cloexec:true ()
    with Unix.Unix_error (e, _, _) -> raise (failed "pipe" e)
  in
  match Unix.fork () with
  | exception Unix.Unix_error (e, _, _) ->
      Unix.close read_fd;
      Unix.close write_fd;
      raise (failed "fork" e)
  | exception Failure _ ->
      (* OCaml 5 refuses to fork a process that has ever spawned a domain. *)
      Unix.close read_fd;
      Unix.close write_fd;
      raise (Supervision domain_refusal)
  | 0 ->
      interrupt.children <- [];
      (try Unix.close read_fd with _ -> ());
      List.iter
        (fun sibling -> try Unix.close sibling.pipe with _ -> ())
        siblings;
      (try ignore (Unix.setsid ()) with _ -> ());
      in_child write_fd body
  | pid ->
      interrupt.children <- pid :: interrupt.children;
      Unix.close write_fd;
      {
        pid;
        pipe = read_fd;
        output = Buffer.create 128;
        started = Os.counter ();
        deadline;
        share;
        log_dir;
        threads = Hashtbl.create 8;
      }

(* XXX a signal between [waitpid] and the removal of the pid from
   [interrupt.children] goes to a reaped pid. *)
let reap running ending =
  (try Unix.close running.pipe with _ -> ());
  let rec wait () =
    match Unix.waitpid [] running.pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
    | exception Unix.Unix_error (e, _, _) -> raise (failed "waitpid" e)
  in
  let status =
    Fun.protect
      ~finally:(fun () ->
        interrupt.children <-
          List.filter (fun pid -> pid <> running.pid) interrupt.children)
      wait
  in
  Run.remove_tree running.log_dir;
  let output = Buffer.contents running.output in
  (* Bytes without their newline are a torn write, which must not read as a
     survivor. *)
  let line =
    match String.index_opt output '\n' with
    | Some i -> String.sub output 0 i
    | None -> ""
  in
  { line; status; ending }

(* The most reads of each pipe in one [drain]. A child that ended left at
   most the capacity of a pipe, 64 KiB on Linux, which 16 reads and the read
   of the end take. Thus a writer that never stops cannot keep a deadline
   from its check. *)
let drain_rounds = 17

(* The most bytes of the output of a child that the parent keeps. Only the
   first line counts, and a child that writes and never stops must not
   fill the memory of the parent before its deadline. *)
let output_limit = 65536

let drain pipes =
  let chunk = Bytes.create 4096 in
  let rec drain closed rounds pipes =
    match pipes with
    | [] -> closed
    | _ :: _ when rounds = 0 -> closed
    | _ :: _ -> (
        match Unix.select (List.map fst pipes) [] [] 0. with
        | [], _, _ -> closed
        | ready, _, _ ->
            let at_end (pipe, output) =
              List.mem pipe ready
              &&
              match Unix.read pipe chunk 0 (Bytes.length chunk) with
              | 0 -> true
              | n ->
                  let room = output_limit - Buffer.length output in
                  Buffer.add_subbytes output chunk 0
                    (Int.max 0 (Int.min n room));
                  false
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> false
            in
            let ended, pipes = List.partition at_end pipes in
            drain (List.map fst ended @ closed) (rounds - 1) pipes
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> closed
        | exception Unix.Unix_error (e, _, _) -> raise (failed "select" e))
  in
  drain [] drain_rounds pipes

(* The first line of the file [path], if it can be read. *)
let first_line path =
  match In_channel.with_open_bin path input_line with
  | line -> Some line
  | exception (Sys_error _ | End_of_file) -> None

(* The numeric entries of the directory [dir]: the pids of /proc, or the
   thread ids of /proc/<pid>/task. *)
let ids dir =
  match Sys.readdir dir with
  | names -> List.filter_map int_of_string_opt (Array.to_list names)
  | exception Sys_error _ -> []

(* The process group of the process [pid], from /proc/<pid>/stat. The
   second field, the name of the command, is in parentheses and can contain
   spaces. The group is the third field after it. *)
let group_of pid =
  match first_line (strf "/proc/%d/stat" pid) with
  | None -> None
  | Some line -> (
      match String.rindex_opt line ')' with
      | None -> None
      | Some i -> (
          let rest = String.sub line (i + 1) (String.length line - i - 1) in
          match String.split_on_char ' ' (String.trim rest) with
          | _ :: _ :: group :: _ -> int_of_string_opt group
          | _ -> None))

(* The seconds that the thread [tid] of the process [pid] used a CPU, and
   the seconds that it waited for a CPU while it could run. Linux gives the
   two in nanoseconds, as the first two fields of
   /proc/<pid>/task/<tid>/schedstat. *)
let thread_times pid tid =
  let seconds field =
    Option.map (fun ns -> ns /. 1e9) (float_of_string_opt field)
  in
  match first_line (strf "/proc/%d/task/%d/schedstat" pid tid) with
  | None -> None
  | Some line -> (
      match String.split_on_char ' ' line with
      | used :: waited :: _ -> (
          match (seconds used, seconds waited) with
          | Some used, Some waited -> Some (used, waited)
          | _ -> None)
      | [] | [ _ ] -> None)

(* [read_threads children] reads the times of each thread of each process
   in the group of each child of [children] ([thread_times]). The group is
   the child and the processes that its tests start ([start]), which
   [kill_group] kills. One read of /proc serves all of [children].

   The child keeps the last times of each thread in [threads]. Thus the
   times of a process that ends after a read stay in [threads], but its wait
   after its last read is not there. The times of a process that ended
   before the first read are not in [threads]. Other systems do not give
   these times, and [threads] stays empty there. *)
let read_threads children =
  let member pid =
    match List.find_opt (fun child -> child.pid = pid) children with
    | Some child -> Some child
    | None -> (
        match group_of pid with
        | None -> None
        | Some group -> List.find_opt (fun child -> child.pid = group) children)
  in
  let read pid child =
    List.iter
      (fun tid ->
        Option.iter (Hashtbl.replace child.threads tid) (thread_times pid tid))
      (ids (strf "/proc/%d/task" pid))
  in
  if children <> [] then
    List.iter (fun pid -> Option.iter (read pid) (member pid)) (ids "/proc")

(* The seconds that the group of [child] waited for a CPU, [elapsed] seconds
   after its start, at the last [read_threads]. It is the sum of the waits of
   its threads, because a test can do its work in a subprocess and wait for
   it. But it is at most the [elapsed] seconds less [child.share] times the
   CPU time of these threads.

   Threads that use the CPUs at the same time, for example 8 processes that
   each use the CPU, wait at the same time. Then the sum of their waits grows
   faster than the clock, and without this limit the deadline never comes.
   Children that outnumber the CPUs also wait for each other, and their
   deadlines are already [share] times longer for this wait. Without [share]
   in this limit, the wait moves their deadlines a second time, and a child
   that uses the CPU uses [share] times the CPU time of the deadline of one
   job. With the limit, the deadline comes at the latest when the group used
   as much CPU time as the deadline of one job. *)
let waited_for_cpu child ~elapsed =
  let used, waited =
    Hashtbl.fold
      (fun _ (used, waited) (all_used, all_waited) ->
        (all_used +. used, all_waited +. waited))
      child.threads (0., 0.)
  in
  Float.max 0. (Float.min waited (elapsed -. (child.share *. used)))

(* The most seconds between two reads of the group of a child past its
   deadline ([read_threads]). When a process of the group ends, the loop
   does not get its wait after its last read. Without this limit, the next
   read comes only when the wait of the last read is used up. A test that
   waits for a subprocess and continues after the subprocess ends then gets
   its deadline at that read. With the limit, a process loses at most the
   wait of [reread] seconds. Something else that holds the loop, for
   example a write of the report, can make the time between two reads
   longer. *)
let reread = 0.1

(* [next_look ~left ~waited] is the seconds until the deadline of a child and
   the seconds until the loop looks at the child again. [left] is the seconds
   until the deadline of the dry run. Past that deadline, [waited ()] is the
   wait of the group of the child ([waited_for_cpu]), which moves the
   deadline later. *)
let next_look ~left ~waited =
  if left > 0. then (left, left)
  else
    let left = left +. waited () in
    (left, Float.min left reread)

(* [await running] is the children of [running] that ended, reaped, and
   those that continue to run, each in the order of [running], when one or
   more children end. A child ends when the parent reads its pipe to the
   end, so a child that writes more than a pipe holds cannot block. It also
   ends when the parent kills its group, at its deadline or on a signal, and
   a signal kills every child of [running].

   The parent reads each pipe that is ready, with no wait, before it looks
   at the signal and the deadlines. A write of the report can hold the
   parent for longer than a deadline while other children run, and a child
   that ended in that time keeps its verdict. On a signal, it keeps its
   verdict too, except when the handler or that signal killed it before it
   exited.

   The signal is looked for before every [select]: the handler can run
   where no system call was there to interrupt.

   The time that a child waited for a CPU does not count toward its
   deadline. Other processes, for example the children of the other suites
   of a parallel [dune runtest], can hold the CPUs for longer than the dry
   run measured, and a wait for them tells nothing about the mutant. The
   time is read only for a child past its deadline: it only moves a
   deadline later. Then it is read at least every [reread] seconds. It is
   the wait of the threads of all of the processes of the group of the
   child ([waited_for_cpu]). *)
let await running =
  let remaining running =
    let elapsed =
      List.map
        (fun ((_, child) as running) -> (running, Os.count_s child.started))
        running
    in
    read_threads
      (List.filter_map
         (fun ((_, child), elapsed) ->
           if elapsed < child.deadline then None else Some child)
         elapsed);
    (* Each child, the seconds until its deadline, and the seconds until
       the loop looks at it again. *)
    List.map
      (fun (((_, child) as running), elapsed) ->
        let left, next =
          next_look ~left:(child.deadline -. elapsed) ~waited:(fun () ->
              waited_for_cpu child ~elapsed)
        in
        (running, left, next))
      elapsed
  in
  let kill ending ((_, child) as running) =
    kill_group child.pid;
    (running, ending)
  in
  let rec watch () =
    let closed =
      drain (List.map (fun (_, child) -> (child.pipe, child.output)) running)
    in
    let is_closed (_, child) = List.mem child.pipe closed in
    if Option.is_some interrupt.signal then
      ( List.map
          (fun ((_, child) as running) ->
            if is_closed running then (running, Closed)
            else kill Interrupted running)
          running,
        [] )
    else
      match List.partition is_closed running with
      | (_ :: _ as ended), live ->
          (List.map (fun running -> (running, Closed)) ended, live)
      | [], _ -> (
          (* One read of the clock decides the expiry and the timeout of
             [select]. A second read can find a deadline that passed after
             the first, and [select] reads a negative timeout as no
             timeout. *)
          let timed = remaining running in
          match List.partition (fun (_, left, _) -> left <= 0.) timed with
          | (_ :: _ as expired), live ->
              ( List.map (fun (child, _, _) -> kill Expired child) expired,
                List.map (fun (child, _, _) -> child) live )
          | [], _ -> (
              let pipes = List.map (fun (_, child) -> child.pipe) running in
              let timeout =
                List.fold_left
                  (fun nearest (_, _, next) -> Float.min nearest next)
                  Float.infinity timed
              in
              match Unix.select pipes [] [] timeout with
              | _ -> watch ()
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> watch ()
              | exception Unix.Unix_error (e, _, _) -> raise (failed "select" e)
              ))
  in
  (* The handler kills with [SIGKILL]. A child that it killed also closes
     its pipe, and gets no verdict. A signal sent to the whole process tree,
     for example by [pkill], also reaches each child, which dies by it. *)
  let ended (key, running) ending =
    let child = reap running ending in
    match (child.ending, child.status) with
    | Closed, Unix.WSIGNALED signal
      when List.mem signal interrupting && Option.is_some interrupt.signal ->
        (key, { child with ending = Interrupted })
    | _ -> (key, child)
  in
  let finished, live = watch () in
  (List.map (fun (running, ending) -> ended running ending) finished, live)

(* Kills and reaps the children of [running] that are not reaped yet, when
   the loop leaves on an exception. It raises nothing: the exception that
   ends the loop is the one to report. A reaped child closed its pipe, and
   another child can use its descriptor number. *)
let abandon running =
  List.iter
    (fun (_, child) ->
      if List.mem child.pid interrupt.children then begin
        kill_group child.pid;
        try ignore (reap child Interrupted) with _ -> ()
      end)
    running

(* [Unix.mkdir] fails on an existing entry, a symbolic link included, so the
   loop never adopts a directory planted at a predictable path of a
   world-writable one. *)
let scratch_root () =
  let base = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let rec create n =
    let candidate = Filename.concat base (strf "windtrap-mutate-%d-%d" pid n) in
    match Unix.mkdir candidate 0o700 with
    | () -> candidate
    | exception Unix.Unix_error (Unix.EEXIST, _, _) when n < 64 -> create (n + 1)
    | exception Unix.Unix_error (e, _, _) ->
        raise
          (Supervision
             (strf "could not create the loop's scratch directory: %s"
                (Unix.error_message e)))
  in
  create 0

(* What every child of one loop is forked from. *)
type loop = {
  suite : string;
  config : Run.config;
  tests : Test_tree.t list;
  reach : reach;
  dry_run_wall : float;
  scratch : string; (* a child killed at its deadline removes nothing *)
  jobs : int; (* the most children at once, [1] or more *)
  share : float; (* the children for each CPU, [1.] or more *)
  killers : (Mutate.id, Verdicts.reaching_test) Hashtbl.t;
      (* the test that killed each mutant in the run before, when its source
         did not change since ([history]) *)
}

let deadline_multiplier = 10.

(* The dry run's wall clock bounds what a child pays before its first test:
   the fork and a whole process's module initialization. Children that
   outnumber the CPUs share them, and their deadlines grow by [share]. The
   probe runs alone, and its share is [1.]. *)
let child_deadline loop ~share paths =
  let took path =
    Hashtbl.find_opt loop.reach.durations (Test_tree.path_to_string path)
  in
  let scheduled =
    List.fold_left
      (fun acc path -> acc +. Option.value ~default:0. (took path))
      0. paths
  in
  share *. (loop.dry_run_wall +. Float.max 1. (deadline_multiplier *. scheduled))

(* A child reports on one line of fixed ASCII shape: a failed test is named
   by its index in the paths the parent handed it, and a diagnostic's line
   breaks become spaces. *)
let error_line message =
  "error " ^ String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) message

let words line =
  match String.split_on_char ' ' (String.trim line) with
  | "error" :: diagnostic -> Error (String.concat " " diagnostic)
  | words -> Ok words

let start_child loop ~share ~log ~bail ~arm ~paths ~siblings line =
  let log_dir = Filename.concat loop.scratch log in
  let config = Run.for_subset loop.config ~log_dir ~bail in
  let body () =
    match arm () with
    | Error message -> error_line message
    | Ok () -> (
        let allowlist = List.map Test_tree.path_to_string paths in
        match Run.execute ~allowlist config ~suite:loop.suite loop.tests with
        | Error error -> error_line (Run.startup_message error)
        | Ok outcome -> line outcome)
  in
  start
    ~deadline:(child_deadline loop ~share paths)
    ~share ~log_dir ~siblings body

(* The determinism probe *)

let counted_failure (r : Run.result) =
  r.counted
  &&
  match r.outcome with
  | Failure.Fail _ -> true
  | Failure.Pass | Failure.Skip _ -> false

(* The index of the test of [r] in the paths that the parent handed the
   child, or [-1]. *)
let index_in paths (r : Run.result) =
  let rec find i = function
    | [] -> -1
    | path :: paths ->
        if List.equal String.equal path r.path then i else find (i + 1) paths
  in
  find 0 paths

(* The path at the index that a child named, if the index is one. *)
let named_in paths index =
  match int_of_string_opt index with
  | Some i when i >= 0 -> List.nth_opt paths i
  | Some _ | None -> None

let probe_line ~paths (outcome : Run.outcome) =
  let results = Run.results outcome.run in
  let failures = List.filter counted_failure results in
  String.concat " "
    (strf "probe %d %d %d" (List.length results)
       (List.length (List.filter is_skip results))
       (List.length failures)
    :: List.map (fun r -> string_of_int (index_in paths r)) failures)

let not_a_number =
  "Mutation results over a non-deterministic suite are not a weaker number, \
   they are not a number"

let probe loop =
  let paths = List.rev loop.reach.executed in
  let child =
    match
      await
        [
          ( (),
            start_child loop ~share:1. ~log:"probe" ~bail:false
              ~arm:(fun () -> Ok ())
              ~paths ~siblings:[] (probe_line ~paths) );
        ]
    with
    | ((), child) :: _, _ -> child
    | [], _ -> (* [await] ends once a child ends. *) assert false
  in
  let disagreement ~executed ~skipped ~failed indices =
    let named index =
      Option.map Test_tree.path_to_string (named_in paths index)
    in
    let measured = List.length paths in
    strf
      "the suite is not deterministic: the dry run executed %d test%s, \
       skipping %d and failing none; the probe executed %d, skipping %d and \
       failing %d%s. %s"
      measured
      (if measured = 1 then "" else "s")
      loop.reach.skipped executed skipped failed
      (match List.filter_map named indices with
      | [] -> ""
      | names -> " (" ^ String.concat ", " names ^ ")")
      not_a_number
  in
  if child.ending = Expired then
    Error
      ("the determinism probe exceeded its deadline: the dry run completed and \
        its unarmed re-run did not. " ^ not_a_number)
  else
    match (words child.line, child.status) with
    | Error diagnostic, _ ->
        Error ("the determinism probe refused to run: " ^ diagnostic)
    | Ok ("probe" :: executed :: skipped :: failed :: indices), Unix.WEXITED 0
      -> (
        match
          ( int_of_string_opt executed,
            int_of_string_opt skipped,
            int_of_string_opt failed )
        with
        | Some executed, Some skipped, Some failed ->
            if
              executed = List.length paths
              && skipped = loop.reach.skipped
              && failed = 0
            then Ok ()
            else Error (disagreement ~executed ~skipped ~failed indices)
        | _ -> Error "the determinism probe reported an unreadable result")
    | Ok _, _ -> Error "the determinism probe died without reporting a result"

(* Verdicts *)

(* A failure that kills a mutant: that of a test not marked xfail. *)
let kills (r : Run.result) = Option.is_none r.xfail && counted_failure r

(* Read off the outcome and never off its exit code, which is [2] for a
   selection that ran nothing: a fact about a filter, not about a mutant.
   The unexpected pass of a test marked xfail counts as a failure of the run
   and kills no mutant. *)
let killed_by (outcome : Run.outcome) =
  outcome.release_failures <> [] || List.exists kills (Run.results outcome.run)

(* A child that recorded no test did not test its mutant: a survivor would
   send the reader to strengthen tests that never ran. A child keeps the
   dry run's state, so a site whose result the dry run cached can pass
   unevaluated. A killed mutant names the test that failed first, by its
   index in [paths], when a test failed. *)
let verdict_line ~paths (outcome : Run.outcome) =
  if killed_by outcome || Run.results outcome.run = [] then
    match List.find_opt kills (Run.results outcome.run) with
    | Some r -> strf "killed %d" (index_in paths r)
    | None -> "killed"
  else if Mutate.armed_hits () = 0 then "not_evaluated"
  else "survived"

let budget_of hits =
  if hits > (max_int - 1000) / 8 then max_int else (hits * 8) + 1000

let start_mutant loop ~index ~siblings ~paths
    ((mutant : Mutate.mutant), (site : site)) =
  let arm () =
    match Mutate.arm ~budget:(budget_of site.hits) mutant.id with
    | Error error -> Error (Pp.to_string Mutate.pp_arm_error error)
    | Ok _ ->
        (* The budget counts the child's evaluations, not the dry run's. *)
        Mutate.reset_reach ();
        Ok ()
  in
  start_child loop ~share:loop.share ~log:(strf "m%d" index) ~bail:true ~arm
    ~paths ~siblings (verdict_line ~paths)

(* A diagnostic is a child that could not arm its mutant or was refused at
   startup. [paths] are the tests that the parent handed the child. *)
let verdict_of ~paths (site : site) child =
  if child.ending = Expired then Ok (Verdicts.Killed { by = None })
  else
    match (words child.line, child.status) with
    | Error diagnostic, _ -> Error diagnostic
    | Ok [ "survived" ], Unix.WEXITED 0 ->
        Ok (Verdicts.survived (List.rev site.tests))
    | Ok [ "not_evaluated" ], Unix.WEXITED 0 -> Ok Verdicts.Not_evaluated
    | Ok [ "killed"; index ], Unix.WEXITED 0 ->
        Ok (Verdicts.Killed { by = named_in paths index })
    | Ok _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) ->
        Ok (Verdicts.Killed { by = None })

(* Recorded paths are relative to the project root; under [dune runtest] the
   working directory is inside [_build], where they do not open. *)
let read_source =
  let cache = Hashtbl.create 16 in
  let read path =
    try Some (In_channel.with_open_bin path In_channel.input_all)
    with Sys_error _ -> None
  in
  fun file ->
    match Hashtbl.find_opt cache file with
    | Some source -> source
    | None ->
        let under_root =
          match Os.project_root () with
          | root -> Result.to_option (Os.reconstruct ~root file)
          | exception Sys_error _ -> None
        in
        let source =
          match Option.bind under_root read with
          | None -> read file
          | found -> found
        in
        Hashtbl.add cache file source;
        source

(* The digest of the source of a mutant, which the verdict file keeps, so
   that the next run knows if the source changed ([history]). *)
let source_digest =
  let cache = Hashtbl.create 16 in
  fun file ->
    match Hashtbl.find_opt cache file with
    | Some digest -> digest
    | None ->
        let digest =
          Option.map
            (fun source -> Digest.to_hex (Digest.string source))
            (read_source file)
        in
        Hashtbl.add cache file digest;
        digest

let record (mutant : Mutate.mutant) verdict =
  Verdicts.record_of_mutant
    ?source_digest:(source_digest mutant.id.file)
    mutant verdict

let shown (mutant : Mutate.mutant) : Report_sections.mutant =
  {
    id = Mutate.id_to_string mutant.id;
    line = mutant.id.line;
    before = mutant.before;
    after = mutant.after;
    source = read_source mutant.id.file;
  }

let survivor ~locations (mutant : Mutate.mutant) reaching :
    Report_sections.survivor =
  let witness path : Report_sections.witness =
    let test = Test_tree.path_to_string path in
    { test; loc = Option.join (Hashtbl.find_opt locations test); exe = None }
  in
  { mutant = shown mutant; witnesses = List.map witness reaching }

type tested = {
  verdicts : Verdicts.t; (* of the children that ended *)
  survivors : Report_sections.survivor list; (* as their blocks printed *)
  not_evaluated : Report_sections.not_evaluated list; (* in catalogue order *)
  stopped : (int * Report.stopped) option;
      (* the signal that stopped the forks, and what it stopped *)
}

(* The tests that one child of a mutant runs. A first child runs the test
   that killed the mutant before, alone ([first_test]), and a full child
   runs every reaching test. *)
type attempt = {
  index : int; (* the catalogue index of the mutant *)
  paths : string list list;
      (* the tests of the child, in the order of the run *)
  first : bool;
      (* a first child, which a full child follows when it kills nothing *)
}

(* What the loop committed: the verdicts of the mutants before
   [committed], in the order of the catalogue. *)
type pool = {
  mutable verdicts : Verdicts.t;
  mutable survivors : Report_sections.survivor list; (* newest first *)
  mutable not_evaluated : Report_sections.not_evaluated list; (* newest first *)
  mutable committed : int;
  mutable completed : int; (* the mutants whose last child ended *)
  mutable running : (attempt * running) list; (* in the order of the starts *)
  mutable again : int list;
      (* the mutants whose first child killed nothing, in catalogue order *)
}

(* The test that the first child of a mutant runs alone: the test that
   killed it in the run that wrote the verdict file before, when its source
   did not change since. The test must reach the mutant, and not be the
   first test that does: a full child runs that test first, and stops at
   its failure. *)
let first_test loop ((mutant : Mutate.mutant), (site : site)) =
  match (Hashtbl.find_opt loop.killers mutant.id, List.rev site.tests) with
  | Some killer, first :: _ :: _
    when (not (List.equal String.equal killer first))
         && List.exists (List.equal String.equal killer) site.tests ->
      Some killer
  | Some _, _ | None, _ -> None

let alone_line (outcome : Run.outcome) =
  if killed_by outcome || Run.results outcome.run = [] then "fails"
  else "passes"

(* A first child runs its test alone, from the state that the dry run left.
   A test that needs the state that an earlier test sets can fail alone with
   no mutant. Its first child would then kill a mutant that a full child
   lets survive. Thus, before any mutant, each [first_test] runs alone in a
   child with no mutant armed, and a test that does not pass there gets no
   first child. Up to [loop.jobs] of these children run at once. After a
   signal, no child starts, and the loop then starts no child of a
   mutant. *)
let passing_alone loop reached =
  let tests =
    List.sort_uniq
      (List.compare String.compare)
      (List.filter_map (first_test loop) reached)
  in
  let passing = Hashtbl.create 16 in
  let running = ref [] in
  let rec next index tests =
    match tests with
    | test :: rest
      when Option.is_none interrupt.signal && List.length !running < loop.jobs
      ->
        let child =
          start_child loop ~share:loop.share ~log:(strf "t%d" index) ~bail:true
            ~arm:(fun () -> Ok ())
            ~paths:[ test ] ~siblings:(List.map snd !running) alone_line
        in
        running := !running @ [ (test, child) ];
        next (index + 1) rest
    | _ when !running = [] -> ()
    | _ ->
        let finished, live = await !running in
        running := live;
        List.iter
          (fun (test, child) ->
            match (child.ending, words child.line, child.status) with
            | Closed, Ok [ "passes" ], Unix.WEXITED 0 ->
                Hashtbl.replace passing test ()
            | _ -> ())
          finished;
        next index tests
  in
  Fun.protect ~finally:(fun () -> abandon !running) (fun () -> next 0 tests);
  let killers = Hashtbl.copy loop.killers in
  Hashtbl.filter_map_inplace
    (fun _ test -> if Hashtbl.mem passing test then Some test else None)
    killers;
  { loop with killers }

(* Up to [loop.jobs] children at once, started in catalogue order. A verdict
   is kept by the catalogue index of its mutant until every mutant before it
   has one. It is then committed, and a survivor's block printed, so the
   report is the same for any number of jobs. A mutant that its child cannot
   arm ends the loop without a score, when it is committed: running on with
   nothing armed would score it a survivor.

   A mutant with a [first_test] that [passing_alone] kept has a first child,
   which runs that test alone. When the first child kills the mutant, that
   is its verdict. When it
   does not, a full child runs every reaching test, before the loop starts
   the child of a mutant after it, and its verdict is the verdict.

   The loop starts no child after a signal. The signal stops the children
   that run, and a child that exited first keeps its verdict, reaped or
   not. The verdicts that ended before it are committed in catalogue order,
   over the gaps of the mutants it stopped. When no child runs and mutants
   remain, the loop stops before the next mutant. *)
let test_mutants renderer loop reached =
  let locations = Hashtbl.create 256 in
  List.iter
    (fun (case : Test_tree.case) ->
      Hashtbl.replace locations (Test_tree.path_to_string case.path) case.loc)
    (Test_tree.flatten loop.tests);
  let reached = Array.of_list reached in
  let total = Array.length reached in
  let ended = Array.make total None in
  let pool =
    {
      verdicts = Verdicts.empty;
      survivors = [];
      not_evaluated = [];
      committed = 0;
      completed = 0;
      running = [];
      again = [];
    }
  in
  let commit index verdict =
    let mutant, _ = reached.(index) in
    (match verdict with
    | Verdicts.Survived { first; others } ->
        let found = survivor ~locations mutant (first :: others) in
        Report.mutation_survivor renderer found;
        pool.survivors <- found :: pool.survivors
    | Verdicts.Not_evaluated ->
        let missed : Report_sections.not_evaluated =
          { mutant = shown mutant; invocation = loop.config.invocation }
        in
        pool.not_evaluated <- missed :: pool.not_evaluated
    | Verdicts.Killed _ | Verdicts.Outside_tests | Verdicts.Filtered _
    | Verdicts.Unreached ->
        ());
    pool.verdicts <- Verdicts.add pool.verdicts (record mutant verdict)
  in
  let rec commit_ready () =
    if pool.committed < total then
      match ended.(pool.committed) with
      | None -> ()
      | Some (Error diagnostic) ->
          let mutant, _ = reached.(pool.committed) in
          raise
            (Supervision
               (strf "%s: %s" (Mutate.id_to_string mutant.id) diagnostic))
      | Some (Ok verdict) ->
          commit pool.committed verdict;
          pool.committed <- pool.committed + 1;
          commit_ready ()
  in
  (* After a signal: the verdicts after the gaps, in catalogue order. *)
  let commit_rest () =
    Array.iteri
      (fun index verdict ->
        match verdict with
        | Some (Ok verdict) when index >= pool.committed -> commit index verdict
        | Some _ | None -> ())
      ended
  in
  let tested stopped =
    {
      verdicts = pool.verdicts;
      survivors = List.rev pool.survivors;
      not_evaluated = List.rev pool.not_evaluated;
      stopped;
    }
  in
  let id index = Mutate.id_to_string (fst reached.(index)).id in
  let start attempt =
    let child =
      start_mutant loop ~index:attempt.index
        ~siblings:(List.map snd pool.running)
        ~paths:attempt.paths reached.(attempt.index)
    in
    pool.running <- pool.running @ [ (attempt, child) ]
  in
  let full index =
    { index; paths = List.rev (snd reached.(index)).tests; first = false }
  in
  let rec next index =
    if Option.is_none interrupt.signal && List.length pool.running < loop.jobs
    then
      match pool.again with
      | again :: rest ->
          pool.again <- rest;
          start (full again);
          next index
      | [] when index < total ->
          start
            (match first_test loop reached.(index) with
            | Some test -> { index; paths = [ test ]; first = true }
            | None -> full index);
          next (index + 1)
      | [] -> wait index
    else wait index
  and wait index =
    match (pool.running, interrupt.signal) with
    | [], Some signal when index < total || pool.again <> [] ->
        commit_rest ();
        let untested = List.fold_left Int.min index pool.again in
        tested (Some (signal, Report.Before (id untested)))
    | [], _ -> tested None
    | running, _ -> (
        Report.mutation_testing renderer ~completed:pool.completed ~total
          ~running:(List.map (fun (attempt, _) -> id attempt.index) running);
        let finished, live = await running in
        (* On a signal [await] gives every child. A signal that comes
           after it stops the children that continue to run. *)
        let finished, live =
          match (interrupt.signal, live) with
          | Some _, _ :: _ -> (finished @ fst (await live), [])
          | Some _, [] | None, _ -> (finished, live)
        in
        pool.running <- live;
        let stopped, finished =
          List.partition (fun (_, child) -> child.ending = Interrupted) finished
        in
        List.iter
          (fun (attempt, child) ->
            match
              verdict_of ~paths:attempt.paths
                (snd reached.(attempt.index))
                child
            with
            | Ok (Verdicts.Survived _ | Verdicts.Not_evaluated)
              when attempt.first ->
                pool.again <-
                  List.merge Int.compare pool.again [ attempt.index ]
            | verdict ->
                ended.(attempt.index) <- Some verdict;
                pool.completed <- pool.completed + 1)
          finished;
        match (interrupt.signal, stopped) with
        | Some signal, _ :: _ ->
            commit_rest ();
            let stopped =
              List.sort Int.compare
                (List.map (fun (attempt, _) -> attempt.index) stopped)
            in
            tested (Some (signal, Report.Testing (List.map id stopped)))
        | Some _, [] | None, _ ->
            commit_ready ();
            next index)
  in
  Fun.protect ~finally:(fun () -> abandon pool.running) @@ fun () -> next 0

(* The scratch directory is removed however the forks end. A signal
   outranks the disagreement of a probe it killed. *)
let fork renderer loop reached =
  Fun.protect ~finally:(fun () -> Run.remove_tree loop.scratch) @@ fun () ->
  match (probe loop, interrupt.signal) with
  | Ok (), _ -> Ok (test_mutants renderer (passing_alone loop reached) reached)
  | Error _, Some signal ->
      Ok
        {
          verdicts = Verdicts.empty;
          survivors = [];
          not_evaluated = [];
          stopped = Some (signal, Report.Probe);
        }
  | (Error _ as refused), None -> refused

(* The loop *)

let narrows_suite (config : Run.config) ~focus =
  config.filter <> [] || config.exclude <> [] || config.tags <> []
  || config.exclude_tags <> [] || config.failed_only || focus
  || config.shard <> None

(* Writes [verdicts], the verdicts of the scope, to the verdict file. Under
   a scope, the records of the other files stay when this build wrote them.
   The result is the note on a file that cannot be written. *)
let save ~scope verdicts =
  let exe = Windtrap_runtime.Instr.executable in
  let path = Verdicts.output_file ~exe in
  let identity = Verdicts.writer_identity ~exe in
  let kept =
    match (identity, Verdicts.load path) with
    | Some identity, Ok (prior, Some writer) when writer = identity ->
        List.filter
          (fun (r : Verdicts.record) -> not (in_scope ~scope r.id))
          (Verdicts.records prior)
    | _ -> []
  in
  match
    Verdicts.save ?identity path (List.fold_left Verdicts.add verdicts kept)
  with
  | () -> None
  | exception Sys_error message ->
      Some (strf "could not write the verdict file: %s" message)

(* What the loop has to say about its verdict file, above the outcome line. *)
let save_verdicts ~scope ~narrowed ~outside ~unreached ~filtered tested =
  match tested.stopped with
  | Some _ -> None
  | None when narrowed ->
      Some
        "verdicts not saved: this run's selection narrows the suite, and a \
         partial run's verdicts would stand in the project merge as the whole."
  | None ->
      let recorded verdict = List.map (fun m -> record m verdict) in
      save ~scope
        (List.fold_left Verdicts.add tested.verdicts
           (recorded Verdicts.Outside_tests outside
           @ recorded Verdicts.Unreached unreached
           @ List.map
               (fun (m, reason) -> record m (Verdicts.Filtered reason))
               filtered))

(* A signal that came once the last child had ended stopped nothing: the
   report ends as usual, and the loop still dies by it. *)
let finish renderer ~narrowed ~reach ~reached ~outside ~unreached ~filtered
    forks =
  match forks with
  | Error message ->
      Report.mutation_refused renderer message;
      Reported 1
  | Ok _ when interrupt.signal = Some Sys.sigpipe -> Os.die_by Sys.sigpipe
  | Ok ({ verdicts; survivors; not_evaluated; stopped }, note) -> (
      let records = Verdicts.records verdicts in
      let is_killed (r : Verdicts.record) =
        match r.verdict with
        | Verdicts.Killed _ -> true
        | Verdicts.Survived _ | Verdicts.Not_evaluated | Verdicts.Outside_tests
        | Verdicts.Filtered _ | Verdicts.Unreached ->
            false
      in
      let lines =
        List.map (fun (m : Mutate.mutant) -> (m.id.file, m.id.line))
      in
      let report : Report_sections.mutation =
        {
          survivors;
          not_evaluated;
          unreached = lines unreached;
          outside_tests = lines outside;
          filtered = List.map snd filtered;
          killed = List.length (List.filter is_killed records);
          not_tested = List.length reached - List.length records;
          scope =
            (if narrowed then
               Report_sections.Selected (List.length reach.executed)
             else Report_sections.Suite);
        }
      in
      match stopped with
      | Some (signal, stopped) ->
          Report.mutation_interrupted renderer stopped report;
          flush_descriptors ();
          Os.die_by signal
      | None -> (
          Report.mutation_finish ?note renderer report;
          flush_descriptors ();
          match interrupt.signal with
          | Some signal -> Os.die_by signal
          | None -> Reported 0))

(* The test that killed each mutant in the run that wrote the verdict file
   before, for the mutants whose source has the digest that it had then. Any
   build counts, an earlier one included: a child runs the test, so the
   history gives no verdict without a run. A file that is
   not a regular file, or that does not load, gives no history. The loop
   does not open a file of another kind, which can block. Only the mutants
   in [reached] have children, and only their sources are read. *)
let history reached =
  let killers = Hashtbl.create 64 in
  let path = Verdicts.output_file ~exe:Windtrap_runtime.Instr.executable in
  let regular =
    match Unix.stat path with
    | { Unix.st_kind; _ } -> st_kind = Unix.S_REG
    | exception Unix.Unix_error _ -> false
  in
  (if regular then
     match Verdicts.load path with
     | Error _ -> ()
     | Ok (prior, _) ->
         List.iter
           (fun (r : Verdicts.record) ->
             match (r.verdict, r.source_digest) with
             | Verdicts.Killed { by = Some test }, Some digest
               when Hashtbl.mem reached r.id
                    && source_digest r.id.file = Some digest ->
                 Hashtbl.replace killers r.id test
             | ( ( Verdicts.Killed _ | Verdicts.Survived _
                 | Verdicts.Not_evaluated | Verdicts.Outside_tests
                 | Verdicts.Filtered _ | Verdicts.Unreached ),
                 _ ) ->
                 ())
           (Verdicts.records prior));
  killers

let loop renderer ~scope ~jobs ~suite (config : Run.config) tests =
  let population = population ~scope in
  let filtered = filtered ~scope in
  let reach =
    {
      sites = Hashtbl.create 256;
      outside = Hashtbl.create 16;
      durations = Hashtbl.create 256;
      executed = [];
      skipped = 0;
    }
  in
  let started = Os.counter () in
  match
    Report.run ~on_event:(observe reach) ~suite
      { config with junit = None }
      tests
  with
  | Error _ -> Reported 1
  | Ok outcome -> (
      (* The last test's teardown and the fixture releases. *)
      evaluated_outside reach;
      if outcome.exit_code = 2 then
        refuse "no test ran, so there is nothing to mutate"
      else if outcome.exit_code <> 0 then
        refuse
          "the dry run is red. Mutation scores a passing suite; a score over a \
           failing one is not a score"
      else
        match population with
        | Error reason -> refuse (refusal ~scope reason)
        | Ok population ->
            let reached, unreached =
              List.partition_map
                (fun (m : Mutate.mutant) ->
                  match Hashtbl.find_opt reach.sites m.id with
                  | Some site -> Either.Left (m, site)
                  | None -> Either.Right m)
                population
            in
            let outside, unreached =
              List.partition
                (fun (m : Mutate.mutant) -> Hashtbl.mem reach.outside m.id)
                unreached
            in
            let dry_run_wall = Float.max 0.01 (Os.count_s started) in
            let narrowed = narrows_suite config ~focus:outcome.focus_active in
            (* Signals are handled until the verdict file is written, so a
               loop that ended has its file whatever becomes of its
               report. *)
            let forks =
              try
                with_interrupts @@ fun () ->
                let loop =
                  let scratch = scratch_root () in
                  let jobs = max 1 (min jobs (List.length reached)) in
                  let share =
                    Float.max 1.
                      (float_of_int jobs
                      /. float_of_int (Domain.recommended_domain_count ()))
                  in
                  {
                    suite;
                    config;
                    tests;
                    reach;
                    dry_run_wall;
                    scratch;
                    jobs;
                    share;
                    killers = history reach.sites;
                  }
                in
                Result.map
                  (fun tested ->
                    ( tested,
                      save_verdicts ~scope ~narrowed ~outside ~unreached
                        ~filtered tested ))
                  (fork renderer loop reached)
              with
              | Supervision message -> Error message
              | Sys_error _ when interrupt.signal = Some Sys.sigpipe ->
                  Os.die_by Sys.sigpipe
            in
            finish renderer ~narrowed ~reach ~reached ~outside ~unreached
              ~filtered forks)

(* The armed run *)

(* The evaluations of the armed site inside tests marked xfail, which reach
   no mutant, saturating at [max_int]. *)
type xfail_hits = { mutable at_start : int; mutable hits : int }

let count_xfail_hits counter (event : Run.event) =
  match event with
  | Run.Test_started _ -> counter.at_start <- Mutate.armed_hits ()
  | Run.Test_finished { xfail = Some _; _ } ->
      let hits = Mutate.armed_hits () - counter.at_start in
      counter.hits <-
        (if counter.hits > max_int - hits then max_int else counter.hits + hits)
  | Run.Test_finished { xfail = None; _ }
  | Run.Run_started _ | Run.Shrinking _ | Run.Shrunk _ | Run.Fixture_release _
  | Run.Interrupted _ ->
      ()

let xfail_failed (outcome : Run.outcome) =
  List.exists
    (fun (r : Run.result) -> Option.is_some r.xfail && counted_failure r)
    (Run.results outcome.run)

(* A dismissed site has no guard, so an armed run of its mutant is the
   unarmed run, and would end on a false "not evaluated". *)
let unarmable (id : Mutate.id) dismissal =
  let id = Mutate.id_to_string id in
  match dismissal with
  | Mutate.Off _ ->
      strf
        "%s: [@mutate off] dismisses this mutant, so its site has no guard and \
         no run can arm it"
        id
  | Mutate.Filtered reason ->
      strf
        "%s: the rewriter filtered this mutant (%s), so its site has no guard \
         and no run can arm it; give -no-filter after ppx_windtrap.mutate to \
         test it"
        id reason

let armed renderer ~spec ~suite (config : Run.config) tests =
  match Result.bind (Mutate.id_of_string spec) Mutate.arm with
  | Error (Mutate.Uncatalogued _ as error) ->
      Os.say (Pp.to_string Mutate.pp_arm_error error);
      ordinary ~suite config tests
  | Error error -> refuse (Pp.to_string Mutate.pp_arm_error error)
  | Ok ({ id; dismissed = Some dismissal; _ } : Mutate.mutant) ->
      refuse (unarmable id dismissal)
  | Ok mutant ->
      let id = Mutate.id_to_string mutant.id in
      let config =
        { config with baseline = Baseline.Check; mutation = Run.Armed id }
      in
      Report.mutation_armed renderer ~id ~before:mutant.before
        ~after:mutant.after;
      flush_descriptors ();
      Mutate.reset_reach ();
      let xfail = { at_start = 0; hits = 0 } in
      let result =
        Report.run ~on_event:(count_xfail_hits xfail) ~suite config tests
      in
      (match result with
      | Ok outcome when killed_by outcome -> Report.mutation_killed renderer
      | Ok outcome when outcome.exit_code <> 2 -> (
          let hits = Mutate.armed_hits () in
          match (hits - xfail.hits, xfail.hits) with
          | 0, 0 -> Report.mutation_not_evaluated renderer
          | 0, _ -> Report.mutation_not_reached renderer
          | _ ->
              Report.mutation_survived renderer ~hits
                ~xfail_failed:(xfail_failed outcome))
      | Ok _ | Error _ -> ());
      flush_descriptors ();
      Ran result

(* A revision that leaves no mutant of the catalogue to test still writes
   the verdict file, with no verdict of a child on a changed line. Thus
   [windtrap mutants --since] finds a file for each such executable, also
   after a new build, and a change that no tested mutant is on passes the
   gate. As in a loop, the file holds a [Filtered] record for each mutant of
   the scope that the rewriter filtered. No test gives these verdicts, so a
   narrowed selection does not stop the save. *)
let save_unmutated ~scope reason =
  match (reason, scope.since) with
  | (Out_of_scope | All_dismissed), Some _ ->
      let filtered =
        List.map
          (fun (m, reason) -> record m (Verdicts.Filtered reason))
          (filtered ~scope)
      in
      Option.iter Os.say
        (save ~scope (List.fold_left Verdicts.add Verdicts.empty filtered))
  | Uninstrumented, _ | (Out_of_scope | All_dismissed), None -> ()

let execute_and_report ~suite (config : Run.config) tests =
  match config.mutation with
  | Run.No_mutation -> ordinary ~suite config tests
  | Run.Armed spec -> armed (Report.terminal config) ~spec ~suite config tests
  | Run.Loop _ when Sys.win32 ->
      refuse "mutation testing needs Unix.fork, which Windows does not have"
  | Run.Loop { scope = prefixes; jobs; since } -> (
      match resolve_scope ~prefixes ~since with
      | Error message -> refuse message
      | Ok scope when not config.broadcast.mutate ->
          loop (Report.terminal config) ~scope ~jobs ~suite config tests
      | Ok scope -> (
          match (population ~scope, Run.list_selection config ~suite tests) with
          | Error reason, _ ->
              Os.say (unmutated ~scope reason);
              save_unmutated ~scope reason;
              ordinary ~suite config tests
          | Ok _, Ok [] -> ordinary ~suite config tests
          | Ok _, (Ok (_ :: _) | Error _) ->
              loop (Report.terminal config) ~scope ~jobs ~suite config tests))
