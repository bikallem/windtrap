(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The executable under test: an ordinary windtrap suite over an
   instrumented module, so that the whole mutation loop runs in a real
   process with a real catalogue. Which tests it DECLARES is chosen by
   MUTATE_FIXTURE, because the loop's refusals are properties of a suite
   and not of a build. The catalogue is the binary and is the same in
   every fixture.

   [catalogue] prints the mutant identifiers instead of running: the
   driver needs them to spell --arm, and reading them from the binary is
   the only spelling that cannot go stale when a line moves in
   subject.ml. *)

open Windtrap
module Subject = Mutate_loop_subject.Subject

(* The child-hygiene rule's witness. Every process reaching Stdlib's exit machinery
   appends its pid here; a mutation child must never appear, because it
   leaves through [Unix._exit] and its whole body is wrapped so that not
   even a fatal exception escapes to the toplevel handler, which runs
   [at_exit] before it prints. This is the general form of "no child
   overwrote the parent's .coverage dump": the coverage dump IS an at_exit
   handler, and so is this. *)
let () =
  match Sys.getenv_opt "MUTATE_ATEXIT_LOG" with
  | None | Some "" -> ()
  | Some path ->
      at_exit (fun () ->
          let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
          output_string oc (string_of_int (Unix.getpid ()) ^ "\n");
          close_out oc)

let strong =
  [
    test "sub of two positives" (fun () -> equal int 6 (Subject.sub 10 4));
    test "sub to zero" (fun () -> equal int 0 (Subject.sub 4 4));
    test "sub of two negatives" (fun () ->
        equal int (-6) (Subject.sub (-10) (-4)));
  ]

(* Weak on purpose: true of [a + b] and of [a - b] alike, which is what
   makes the mutant survive and the survivor block a defect report about
   these two tests. *)
let weak =
  [
    test "widen is nonzero" (fun () -> is_true (Subject.widen 3 4 <> 0));
    test "widen is not 99" (fun () -> is_true (Subject.widen 1 2 <> 99));
  ]

(* Reaches the [@mutate off] site and pins nothing about it. Only the
   dismissal keeps it out of the survivor blocks and out of the
   denominator. *)
let dismissed =
  [
    test "the dismissed site is run and not pinned" (fun () ->
        is_true (Subject.dismissed 1 2 <> 99));
  ]

(* A second survivor: [orphan] is weakly reached by one test, where
   [widen] is by two. Every survivor gets a block. *)
let two_survivors =
  [ test "orphan is nonzero" (fun () -> is_true (Subject.orphan 3 4 <> 0)) ]

let red = [ test "always red" (fun () -> equal int 1 2) ]

(* Spawns a domain and joins it: green, and from then on the process can
   no longer fork. *)
let domain =
  [
    test "sub in a domain of its own" (fun () ->
        equal int 6 (Domain.join (Domain.spawn (fun () -> Subject.sub 10 4))));
  ]

(* Green in the process that measured the reach map and red in every fork
   of it, the sharpest possible non-determinism, and the one the probe
   exists to catch: without it the loop would score every mutant against a
   suite that fails for reasons of its own. *)
let dry_run_pid = Unix.getpid ()

let flaky =
  [
    test "passes where it was measured and fails where it is re-run" (fun () ->
        is_true (Unix.getpid () = dry_run_pid));
  ]

(* Runs where it was measured and skips in every fork of it: the same
   tests execute and none fails, so only the skip count disagrees. *)
let skippy =
  [
    test "runs where it was measured and skips where it is re-run" (fun () ->
        if Unix.getpid () <> dry_run_pid then skip ());
  ]

(* Leaves through [Unix._exit], which the runner's exit guard does not
   intercept: armed, the child dies with no verdict on the pipe. *)
let crash =
  [
    test "crasher leaves without a word" (fun () ->
        if Subject.crasher 3 1 <> 2 then Unix._exit 3;
        equal int 2 (Subject.crasher 3 1));
  ]

(* Leaves through a FATAL exception, which no failure boundary in the
   runner may swallow ({!Failure.catch} never returns it): armed, it escapes
   [Run.execute] and reaches the mutation child's own wrapper, which is
   the only thing between it and OCaml's uncaught-exception handler, and
   that handler runs [at_exit]. Unarmed the answer is 2 and nothing
   raises, so the dry run is green. *)
let fatal =
  [
    test "crasher raises a fatal exception when the answer changes" (fun () ->
        if Subject.crasher 3 1 <> 2 then raise Out_of_memory;
        equal int 2 (Subject.crasher 3 1));
  ]

(* The reach map's boundaries, in one suite.

   - [orphan] is evaluated at module initialization below, before any test
     starts. It must stay unreached: a warm-fork loop can never arm it
     (module initialization ran before the fork), so folding that window
     into the first test would report a permanent false survivor.
   - [widen] is evaluated by the first and third tests and by no other, so
     the survivor block's reaching tests are a claim with four wrong answers
     available.
   - the first test needs a retry, and both attempts run the line: a
     retried test contributes one window, not two, and does not desync the
     determinism probe.
   - [crasher] is evaluated by a FIXTURE RELEASE, which runs after the
     last test finishes and belongs to no test. It must stay unreached
     too.

   [sub] is pinned by three tests and [widen] reached by two. *)

(* The per-child deadline's fixtures.

   - [block] pairs a watcher of [sub] that pins nothing with a test that
     BLOCKS when [sub]'s answer changes, a pipe read with no writer, the
     measured shape: a blocked child spends its deadline at 0% CPU, where
     the runaway hit-count budget sees nothing. Unarmed nothing blocks,
     so the dry run and the probe are green and fast, which is what keeps
     the derived deadline short. Under MUTATE_GRANDCHILD_PIDFILE the
     blocking test first spawns a subprocess that IGNORES SIGTERM (it
     outlives its inner sleeps for as long as its bounded loop respawns
     them, thirty seconds at most, so only an unignorable signal to the
     whole group clears it) and records its pid: the file is how the
     harness finds the grandchild to poll.
   - [slow] sleeps on every run, armed and unarmed alike, and pins nothing
     about [sub]: the dry run measures the sleep, so the derived deadline
     grows tenfold with it, and the mutant survives unless the clock
     kills the child. The sleep is short: it only has to be a test that
     takes time, since any deadline that priced in less than the test
     itself would end it.
   - [probe_block] is green where the reach map is measured and BLOCKED
     where it is re-run: the dry run leaves the marker, the probe's
     unarmed re-run finds it and hangs. No mutant is armed in a probe,
     so only its own deadline can end it, and what an expiry proves is
     non-determinism.
   - [probe_jobs] is [probe_block] beside [stalled], so it reaches two
     mutants, and 16 jobs on one CPU give two children for that CPU. *)

let hang () =
  (match Sys.getenv_opt "MUTATE_GRANDCHILD_PIDFILE" with
  | None | Some "" -> ()
  | Some path ->
      let pid =
        Unix.create_process "sh"
          [|
            "sh";
            "-c";
            "trap '' TERM; n=0; while [ $n -lt 30 ]; do sleep 1; n=$((n+1)); \
             done";
          |]
          Unix.stdin Unix.stdout Unix.stderr
      in
      let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
      output_string oc (string_of_int pid ^ "\n");
      close_out oc);
  let never_written, _held_open = Unix.pipe () in
  ignore (Unix.read never_written (Bytes.create 1) 0 1)

let block =
  [
    test "watches sub without pinning it" (fun () ->
        is_true (Subject.sub 10 4 < 100));
    test "blocks when sub changes" (fun () ->
        if Subject.sub 10 4 <> 6 then hang ();
        equal int 6 (Subject.sub 10 4));
  ]

(* What a loop prints while it runs.

   - [held] has two survivors, and the catalogue's order is not the
     most-watched one: [sub] comes first and one test watches it, [widen]
     second and two do. The child that has [widen]'s mutant armed waits
     at the gate ([wait_at_gate]), so the harness can read what the parent
     has printed, or leave, while the second child provably runs. Unarmed
     nothing waits.
   - [interrupted] puts a child that hangs between a survivor and a
     mutant the loop never gets to: [sub] survives, [widen]'s child
     blocks until a signal to the parent ends it, [orphan] is reached and
     left untested.
   - [pinned] kills every mutant of the catalogue that is not dismissed:
     a loop with nothing to report but its outcome line, which is then
     the one write a reader that left at the gate can fail. *)

(* Under MUTATE_GATE, says the child started (MUTATE_STARTED) and waits
   for the gate file. *)
let wait_at_gate () =
  match (Sys.getenv_opt "MUTATE_STARTED", Sys.getenv_opt "MUTATE_GATE") with
  | Some started, Some gate ->
      let oc = open_out started in
      output_string oc "started\n";
      close_out oc;
      while not (Sys.file_exists gate) do
        Unix.sleepf 0.005
      done
  | _ -> ()

let held =
  [
    test "watches sub without pinning it" (fun () ->
        is_true (Subject.sub 10 4 < 100));
    test "widen is nonzero, once the gate opens" (fun () ->
        if Subject.widen 3 4 <> 7 then wait_at_gate ();
        is_true (Subject.widen 3 4 <> 0));
    test "widen is not 99" (fun () -> is_true (Subject.widen 1 2 <> 99));
  ]

let interrupted =
  [
    test "watches sub without pinning it" (fun () ->
        is_true (Subject.sub 10 4 < 100));
    test "hangs when widen changes" (fun () ->
        if Subject.widen 3 4 <> 7 then hang ();
        is_true (Subject.widen 3 4 <> 0));
    test "orphan is nonzero" (fun () -> is_true (Subject.orphan 3 4 <> 0));
  ]

let pinned =
  [
    test "widen adds, once the gate opens" (fun () ->
        if Subject.widen 3 4 <> 7 then wait_at_gate ();
        equal int 7 (Subject.widen 3 4));
    test "orphan adds" (fun () -> equal int 7 (Subject.orphan 3 4));
    test "crasher subtracts" (fun () -> equal int 2 (Subject.crasher 3 1));
  ]

(* The fixtures of children that run at once (--mutate-jobs).

   - [rendezvous] passes only where the children of [sub] and [widen] run at
     the same time: each armed child leaves its mark in MUTATE_RENDEZVOUS
     and waits for the mark of the other. One at a time, the first child
     waits until its deadline kills it, and the second finds the mark.
   - [hung] hangs the children of [sub] and of [widen], so a signal finds
     two children running. Under MUTATE_GRANDCHILD_PIDFILE each records the
     subprocess it starts, as [block] does.
   - [gap] hangs the child of [sub], first in the catalogue, while the child
     of [widen] survives and writes its pid to MUTATE_ENDED as its test
     ends: a verdict that waits for the one before it.
   - [stalled] holds the children of [sub] and of [widen] each at a gate
     of its own ([wait_at]), so the harness can end them one at a time.
     The two mutants survive.
   - [queued] is [stalled] with a third test, which reaches [orphan]. Under
     two jobs, the child of [orphan] starts only when a gate opens.
   - [siblings] reaches [sub] and [widen], and pins nothing about them.
     Under MUTATE_PIPES, each armed child writes the number of its pipes
     ([fifos]) to the file [sub] or [widen] of that directory. Under two
     jobs, the loop starts the child of [widen] while it holds the pipe of
     the child of [sub].
   - [closing] hangs the child of [sub]. Under MUTATE_CLOSED, the child of
     [widen] closes its pipes and continues to run ([close_and_hang]). Thus
     the loop reads the end of its pipe, and waits for it to exit. *)

(* The descriptors from 3 to 255 that are pipes. A descriptor is an [int] on
   Unix, and a child has no other name for its verdict pipe. *)
let fifos () =
  List.filter_map
    (fun n ->
      let fd : Unix.file_descr = Obj.magic n in
      match Unix.fstat fd with
      | { Unix.st_kind = Unix.S_FIFO; _ } -> Some fd
      | _ -> None
      | exception Unix.Unix_error _ -> None)
    (List.init 253 (fun n -> n + 3))

let meet ~mark ~other =
  match Sys.getenv_opt "MUTATE_RENDEZVOUS" with
  | None | Some "" -> ()
  | Some dir ->
      close_out (open_out (Filename.concat dir mark));
      while not (Sys.file_exists (Filename.concat dir other)) do
        Unix.sleepf 0.005
      done

let rendezvous =
  [
    test "sub meets widen" (fun () ->
        if Subject.sub 10 4 <> 6 then meet ~mark:"sub" ~other:"widen";
        is_true (Subject.sub 10 4 < 100));
    test "widen meets sub" (fun () ->
        if Subject.widen 3 4 <> 7 then meet ~mark:"widen" ~other:"sub";
        is_true (Subject.widen 3 4 <> 0));
  ]

let hangs_on_sub =
  test "hangs when sub changes" (fun () ->
      if Subject.sub 10 4 <> 6 then hang ();
      is_true (Subject.sub 10 4 < 100))

let hung =
  [
    hangs_on_sub;
    test "hangs when widen changes" (fun () ->
        if Subject.widen 3 4 <> 7 then hang ();
        is_true (Subject.widen 3 4 <> 0));
  ]

(* Under MUTATE_GATES, writes the pid of the child to the file [name] of
   that directory, and waits for the file [name ^ ".open"]. *)
let wait_at name =
  match Sys.getenv_opt "MUTATE_GATES" with
  | None | Some "" -> ()
  | Some dir ->
      let path = Filename.concat dir name in
      Out_channel.with_open_bin (path ^ ".tmp") (fun oc ->
          output_string oc (string_of_int (Unix.getpid ()) ^ "\n"));
      Sys.rename (path ^ ".tmp") path;
      while not (Sys.file_exists (path ^ ".open")) do
        Unix.sleepf 0.005
      done

let stalled =
  [
    test "sub waits at its gate" (fun () ->
        if Subject.sub 10 4 <> 6 then wait_at "sub";
        is_true (Subject.sub 10 4 < 100));
    test "widen waits at its gate" (fun () ->
        if Subject.widen 3 4 <> 7 then wait_at "widen";
        is_true (Subject.widen 3 4 <> 0));
  ]

let queued =
  stalled
  @ [ test "orphan is nonzero" (fun () -> is_true (Subject.orphan 3 4 <> 0)) ]

let count_pipes name =
  match Sys.getenv_opt "MUTATE_PIPES" with
  | None | Some "" -> ()
  | Some dir ->
      let count = List.length (fifos ()) in
      Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
          output_string oc (string_of_int count ^ "\n"))

let siblings =
  [
    test "sub counts its pipes" (fun () ->
        if Subject.sub 10 4 <> 6 then count_pipes "sub";
        is_true (Subject.sub 10 4 < 100));
    test "widen counts its pipes" (fun () ->
        if Subject.widen 3 4 <> 7 then count_pipes "widen";
        is_true (Subject.widen 3 4 <> 0));
  ]

(* The pipes that the process [pid] holds, from /proc/[pid]/fd: each
   descriptor with the name of its pipe, as ["pipe:[1234]"]. *)
let held_pipes pid =
  let dir = Printf.sprintf "/proc/%s/fd" pid in
  let entries = try Sys.readdir dir with Sys_error _ -> [||] in
  List.filter_map
    (fun entry ->
      match
        (int_of_string_opt entry, Unix.readlink (Filename.concat dir entry))
      with
      | Some fd, name when String.starts_with ~prefix:"pipe:" name ->
          Some (fd, name)
      | _ -> None
      | exception Unix.Unix_error _ -> None)
    (Array.to_list entries)

(* Closes the pipes of the child from descriptor 3, its verdict pipe
   included, and waits until the loop holds fewer of them. The loop closes
   its end of the verdict pipe when it reaps the child, before it waits for
   the child to exit. The child then writes its pid to MUTATE_CLOSED, and
   hangs until a signal kills it. *)
let close_and_hang () =
  match Sys.getenv_opt "MUTATE_CLOSED" with
  | None | Some "" -> ()
  | Some path ->
      let loop = string_of_int (Unix.getppid ()) in
      let own = List.filter (fun (fd, _) -> fd > 2) (held_pipes "self") in
      let shared () =
        List.length
          (List.filter
             (fun (_, name) -> List.exists (fun (_, n) -> n = name) own)
             (held_pipes loop))
      in
      let before = shared () in
      List.iter (fun (fd, _) -> Unix.close (Obj.magic fd : Unix.file_descr)) own;
      while shared () >= before do
        Unix.sleepf 0.005
      done;
      Out_channel.with_open_bin path (fun oc ->
          output_string oc (string_of_int (Unix.getpid ()) ^ "\n"));
      hang ()

let closing =
  [
    hangs_on_sub;
    test "widen closes its pipes and hangs" (fun () ->
        if Subject.widen 3 4 <> 7 then close_and_hang ();
        is_true (Subject.widen 3 4 <> 0));
  ]

let gap =
  [
    hangs_on_sub;
    test "widen is nonzero, and says when it ends" (fun () ->
        (if Subject.widen 3 4 <> 7 then
           match Sys.getenv_opt "MUTATE_ENDED" with
           | None | Some "" -> ()
           | Some path ->
               Out_channel.with_open_bin path (fun oc ->
                   output_string oc (string_of_int (Unix.getpid ()) ^ "\n")));
        is_true (Subject.widen 3 4 <> 0));
  ]

(* [late] reaches one mutant, so its child is the last. Armed, the test
   leaves a watcher behind that outlives the child. It waits until the
   loop's scratch directory, the one entry of TMPDIR, is gone, which the
   loop removes once its last child has ended, and sends SIGINT to the
   loop. The harness has put a FIFO where the verdict file goes, and the
   loop reads the file it replaces: its open blocks until the watcher,
   after the signal, holds the FIFO open, or until the signal interrupts
   it. So the signal lands after the last child and before the loop can
   restore its handlers, on any schedule. The watcher lets go once the
   loop has written its file over the FIFO, or is gone. It is an exec'd
   shell, so it holds no descriptor of the child's (the verdict pipe is
   close-on-exec). *)
let signal_the_loop_after_its_last_child () =
  let tmp = Filename.get_temp_dir_name () in
  match Array.to_list (Sys.readdir tmp) with
  | [ scratch ] ->
      let loop = Unix.getppid () in
      ignore
        (Unix.create_process "sh"
           [|
             "sh";
             "-c";
             "while [ -e \"$1\" ] && kill -0 \"$2\" 2>/dev/null; do sleep \
              0.01; done; kill -INT \"$2\"; exec 3<>\"$3\"; while [ -p \"$3\" \
              ] && kill -0 \"$2\" 2>/dev/null; do sleep 0.01; done";
             "sh";
             Filename.concat tmp scratch;
             string_of_int loop;
             Windtrap_runtime.Verdicts.output_file
               ~exe:Windtrap_runtime.Instr.executable;
           |]
           Unix.stdin Unix.stdout Unix.stderr)
  | _ -> failwith "TMPDIR holds one entry, the loop's scratch directory"

let late =
  [
    test "signals the loop once its last child ends" (fun () ->
        if Subject.sub 10 4 <> 6 then signal_the_loop_after_its_last_child ();
        is_true (Subject.sub 10 4 < 100));
  ]

let slow =
  [
    test "sleeps briefly and pins nothing about sub" (fun () ->
        Unix.sleepf 0.05;
        is_true (Subject.sub 10 4 < 100));
  ]

(* [starved] reaches [sub] and pins nothing about it. Outside the process
   that measured the reach map, in the probe and in the child, its test
   first uses 0.4 seconds of CPU time. The dry run does not, so the
   deadlines do not grow with it. Under [hog], the process gets a session
   of its own and uses the CPU until a signal kills it. *)
let use_cpu seconds =
  let start = Sys.time () in
  while Sys.time () -. start < seconds do
    ignore (Sys.opaque_identity ())
  done

let starved =
  [
    test "uses the CPU where it is re-run and pins nothing about sub" (fun () ->
        if Unix.getpid () <> dry_run_pid then use_cpu 0.4;
        is_true (Subject.sub 10 4 < 100));
  ]

(* [spawning] is [starved], but a subprocess uses the CPU ([burn]), and the
   test waits for it. Thus the main thread of the probe and of the child
   sleeps, and only the subprocess waits for the CPU. *)
let burn () =
  let fixture = "MUTATE_FIXTURE=" in
  let env =
    Unix.environment () |> Array.to_list
    |> List.filter (fun v -> not (String.starts_with ~prefix:fixture v))
  in
  let pid =
    Unix.create_process_env Sys.executable_name [| Sys.executable_name |]
      (Array.of_list ((fixture ^ "burn") :: env))
      Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> ()
  | _ -> fail "the subprocess that uses the CPU did not exit 0"

let spawning =
  [
    test "waits for a process that uses the CPU and pins nothing about sub"
      (fun () ->
        if Unix.getpid () <> dry_run_pid then burn ();
        is_true (Subject.sub 10 4 < 100));
  ]

(* [spinners] is [hung], but the test of a changed answer uses the CPU until
   its deadline. It evaluates no site in this time, so the hit budget does
   not stop it. *)
let spinners =
  [
    test "spins when sub changes" (fun () ->
        if Subject.sub 10 4 <> 6 then use_cpu Float.infinity;
        is_true (Subject.sub 10 4 < 100));
    test "spins when widen changes" (fun () ->
        if Subject.widen 3 4 <> 7 then use_cpu Float.infinity;
        is_true (Subject.widen 3 4 <> 0));
  ]

(* The probe says it started, beside the dry run's marker, before it
   blocks: a harness that signals the loop then knows the probe is the
   child that runs. *)
let probe_block =
  [
    test "blocks on its second run" (fun () ->
        is_true (Subject.sub 10 4 < 100);
        match Sys.getenv_opt "MUTATE_PROBE_MARKER" with
        | None | Some "" -> ()
        | Some path ->
            if Sys.file_exists path then begin
              Out_channel.with_open_bin (path ^ ".probe") (fun oc ->
                  output_string oc "the probe\n");
              let never_written, _held_open = Unix.pipe () in
              ignore (Unix.read never_written (Bytes.create 1) 0 1)
            end
            else close_out (open_out path));
  ]

(* [flood] reaches [sub] and pins nothing about it. Armed, the child and 7
   processes that it forks write to each pipe that the child holds open for
   writing ([fifos]), its verdict pipe included, and never stop: only the
   deadline can end the child. They do not wait for room in the pipe, so
   the pipe stays full where they run on more CPUs than the parent does. *)
let flood_pipes () =
  let chunk = Bytes.make 65536 'x' in
  let pipes = fifos () in
  List.iter
    (fun fd -> try Unix.set_nonblock fd with Unix.Unix_error _ -> ())
    pipes;
  let written fd =
    match Unix.write fd chunk 0 (Bytes.length chunk) with
    | _ -> true
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> true
    | exception Unix.Unix_error _ -> false
  in
  let rec write pipes = write (List.filter written pipes) in
  for _ = 1 to 7 do
    if Unix.fork () = 0 then write pipes
  done;
  write pipes

let flood =
  [
    test "floods its pipes when sub changes" (fun () ->
        if Subject.sub 10 4 <> 6 then flood_pipes ();
        is_true (Subject.sub 10 4 < 100));
  ]

(* What the dry run and the children do with what the suite is given.

   - [baseline] checks [sub]'s answer against a file under
     WINDTRAP_PROJECT_ROOT, and pins it: a child that checked read-only
     sees the mutant's answer as a mismatch.
   - [release] reaches [sub] and pins nothing about it; only the release
     of its fixture, at the end of the run, checks the answer. Outside
     the process that measured the reach map the release also prints on
     both standard descriptors, which is what a child's /dev/null hides.
   - [budget] evaluates [sub] [k] times unarmed and [target] times armed
     (MUTATE_BUDGET="k target"), and pins nothing: the runaway budget
     alone decides the mutant.
   - [flip] fails where MUTATE_FLIP is set, so a first run can leave a
     failure for [--failed] to select.
   - [focused] holds a focused test. *)

let baseline =
  [
    test "sub's answer, against its file" (fun () ->
        expect_file (string_of_int (Subject.sub 10 4)) "sub.expected");
  ]

let released =
  fixture
    ~teardown:(fun () ->
      if Unix.getpid () <> dry_run_pid then begin
        print_string "a child's release on stdout\n";
        prerr_string "a child's release on stderr\n";
        flush stdout;
        flush stderr
      end;
      if Subject.sub 10 4 <> 6 then failwith "the release saw sub change")
    Fun.id

let release =
  [
    test "holds a fixture and pins nothing about sub" (fun () ->
        released ();
        is_true (Subject.sub 10 4 < 100));
  ]

let budget =
  [
    test "evaluates sub as often as it is told" (fun () ->
        let k, target =
          match
            String.split_on_char ' '
              (Option.value ~default:"" (Sys.getenv_opt "MUTATE_BUDGET"))
          with
          | [ k; target ] -> (int_of_string k, int_of_string target)
          | _ -> failwith "MUTATE_BUDGET is \"k target\""
        in
        let armed = Subject.sub 10 4 <> 6 in
        for _ = 2 to if armed then target else k do
          ignore (Subject.sub 1 1)
        done);
  ]

let flip =
  [
    test "fails where it is told to" (fun () ->
        is_true (Subject.sub 10 4 < 100);
        is_true (Sys.getenv_opt "MUTATE_FLIP" = None));
  ]

let focused =
  [
    focus (test "widen is nonzero" (fun () -> is_true (Subject.widen 3 4 <> 0)));
    test "widen is not 99" (fun () -> is_true (Subject.widen 1 2 <> 99));
  ]

(* Tests marked xfail beside ordinary ones that pin nothing. [sub adds]
   asserts what [sub]'s mutant computes, so it passes where that mutant is
   armed; [widen is 99] fails armed or not; [orphan is 99] is the only test
   that runs [orphan]. None of the three reaches a mutant. *)
let known =
  [
    test "watches sub without pinning it" (fun () ->
        is_true (Subject.sub 10 4 < 100));
    xfail ~reason:"sub subtracts"
      (test "sub adds" (fun () -> equal int 7 (Subject.sub 3 4)));
    test "widen is nonzero" (fun () -> is_true (Subject.widen 3 4 <> 0));
    xfail (test "widen is 99" (fun () -> equal int 99 (Subject.widen 1 2)));
    xfail (test "orphan is 99" (fun () -> equal int 99 (Subject.orphan 1 2)));
  ]

(* [widen]'s answer, memoized. The dry run fills the table, and a child
   forked after it finds the answer there, so its armed [widen] never runs
   and the test passes. An armed run is a new process, which computes the
   answer and fails the test. *)
let memo = Hashtbl.create 1

let memoized_widen a b =
  match Hashtbl.find_opt memo (a, b) with
  | Some sum -> sum
  | None ->
      let sum = Subject.widen a b in
      Hashtbl.add memo (a, b) sum;
      sum

let memoized =
  [ test "memoized widen adds" (fun () -> equal int 7 (memoized_widen 3 4)) ]

let retried = ref 0
let handle = fixture ~teardown:(fun () -> ignore (Subject.crasher 3 1)) Fun.id

let boundary =
  [
    test ~retries:1 "first reaches widen, after a retry" (fun () ->
        is_true (Subject.widen 3 4 <> 0);
        incr retried;
        if !retried = 1 then fail "flaky on the first attempt");
    test "second reaches sub and holds a fixture released at run end" (fun () ->
        handle ();
        equal int 6 (Subject.sub 10 4));
    test "third reaches widen" (fun () -> is_true (Subject.widen 1 2 <> 99));
    test "fourth reaches sub" (fun () -> equal int 0 (Subject.sub 4 4));
    test "fifth reaches sub" (fun () -> equal int (-6) (Subject.sub (-10) (-4)));
  ]

let () =
  match Option.value ~default:"green" (Sys.getenv_opt "MUTATE_FIXTURE") with
  | "catalogue" ->
      List.iter
        (fun (m : Windtrap_runtime.Mutate.mutant) ->
          print_endline
            (Windtrap_runtime.Mutate.id_to_string m.Windtrap_runtime.Mutate.id))
        (Windtrap_runtime.Mutate.catalogue ())
  | "weak" -> exit @@ run "calc" [ group "widen" weak ]
  | "block" -> exit @@ run "calc" [ group "block" block ]
  | "held" -> exit @@ run "calc" [ group "held" held ]
  | "interrupted" -> exit @@ run "calc" [ group "held" interrupted ]
  | "rendezvous" -> exit @@ run "calc" [ group "jobs" rendezvous ]
  | "hung" -> exit @@ run "calc" [ group "jobs" hung ]
  | "gap" -> exit @@ run "calc" [ group "jobs" gap ]
  | "siblings" -> exit @@ run "calc" [ group "jobs" siblings ]
  | "closing" -> exit @@ run "calc" [ group "jobs" closing ]
  | "stalled" -> exit @@ run "calc" [ group "jobs" stalled ]
  | "queued" -> exit @@ run "calc" [ group "jobs" queued ]
  | "pinned" ->
      exit @@ run "calc" [ group "calc" strong; group "pinned" pinned ]
  | "slow" -> exit @@ run "calc" [ group "slow" slow ]
  | "starved" -> exit @@ run "calc" [ group "starved" starved ]
  | "spawning" -> exit @@ run "calc" [ group "starved" spawning ]
  | "spinners" -> exit @@ run "calc" [ group "jobs" spinners ]
  | "burn" -> use_cpu 0.4
  | "hog" ->
      ignore (Unix.setsid ());
      while true do
        ignore (Sys.opaque_identity ())
      done
  | "flood" -> exit @@ run "calc" [ group "flood" flood ]
  | "late" -> exit @@ run "calc" [ group "late" late ]
  | "probe_block" -> exit @@ run "calc" [ group "probe" probe_block ]
  | "probe_jobs" ->
      exit @@ run "calc" [ group "probe" probe_block; group "jobs" stalled ]
  | "baseline" -> exit @@ run "calc" [ group "baseline" baseline ]
  | "release" -> exit @@ run "calc" [ group "release" release ]
  | "budget" -> exit @@ run "calc" [ group "budget" budget ]
  | "flip" -> exit @@ run "calc" [ group "flip" flip ]
  | "focused" -> exit @@ run "calc" [ group "focused" focused ]
  | "known" -> exit @@ run "calc" [ group "known" known ]
  | "memo" -> exit @@ run "calc" [ group "calc" strong; group "memo" memoized ]
  | "crash" ->
      exit
      @@ run "calc"
           [ group "calc" strong; group "widen" weak; group "crash" crash ]
  | "fatal" ->
      exit
      @@ run "calc"
           [ group "calc" strong; group "widen" weak; group "crash" fatal ]
  | "capped" ->
      exit
      @@ run "calc"
           [
             group "calc" strong;
             group "widen" weak;
             group "orphan" two_survivors;
           ]
  | "red" ->
      exit @@ run "calc" [ group "calc" (strong @ red); group "widen" weak ]
  | "flaky" -> exit @@ run "calc" [ group "calc" strong; group "flaky" flaky ]
  | "domain" -> exit @@ run "calc" [ group "domain" domain ]
  | "skippy" ->
      exit @@ run "calc" [ group "calc" strong; group "skippy" skippy ]
  | "boundary" ->
      (* Outside any test, and before the first one starts. *)
      ignore (Subject.orphan 1 2);
      exit @@ run "calc" [ group "widen" boundary ]
  | "tagged" ->
      (* Every test carries one tag, so --tag/WINDTRAP_TAG selects the
         whole suite: a tag predicate is not expressible as a set of
         paths, and a child that dropped the parent's would run fewer
         tests than the dry run measured. *)
      exit
      @@ run "calc"
           [
             group ~tags:[ "gated" ] "calc" strong;
             group ~tags:[ "gated" ] "widen" weak;
           ]
  | _ ->
      exit
      @@ run "calc"
           [
             group "calc" strong;
             group "widen" weak;
             group "dismissed" dismissed;
           ]
