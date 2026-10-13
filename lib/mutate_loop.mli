(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The mutation loop: the parent process of a mutation run.

    {!execute_and_report} is the one call through which a run becomes a mutation
    run, and the entry point of a suite makes it in place of {!Report.run}.

    The module decides which mutants survived, in which order and with which
    reaching tests. What a run tests or arms arrives on [config.mutation]
    ({!Run.type-mutation}), which {!Cli} resolves. *)

(** {1:running Running} *)

(** The type for what {!execute_and_report} did with the run. *)
type run =
  | Ran of (Run.outcome, Run.startup_error) result
      (** The result of {!Report.run}, which was called once. The caller
          finishes its work on it as it does after {!Report.run}. *)
  | Reported of int
      (** The module has printed everything, and the process must exit with this
          code, which is [0] or [1]. The caller must do none of the work that
          follows a run. *)

val execute_and_report : suite:string -> Run.config -> Test_tree.t list -> run
(** [execute_and_report ~suite config tests] is {!Report.run} over the same
    arguments, in the mode that [config.mutation] names.
    - Under {!Run.No_mutation} it is [Ran (Report.run ~suite config tests)] and
      nothing else, in an instrumented build as in any other.
    - Under {!Run.Armed} it is the {{!section-armed}armed run}.
    - Under {!Run.Loop} it is the {{!section-loop}loop}, and the result is
      [Reported], but for a [WINDTRAP_MUTATE] that finds nothing to test.

    [Reported 0] is a loop that ran whole, whatever it found. Only
    [windtrap mutants], which merges the verdict files of every executable,
    gates on survivors. [Reported 1] is a loop that refused to start or could
    not go on, or an [--arm] identifier that is refused. Each says its reason on
    standard error, and none falls back to a default and runs on. *)

(** {1:loop The loop}

    The loop proceeds in this order.
    + It fixes the population, which is the catalogue of the executable
      ({!val:Windtrap_runtime.Mutate.catalogue}) narrowed to the scope, without
      the mutants that [[@mutate off]] dismisses. The scope is the list of
      source-path prefixes that [--mutate] gave, and the revision of
      [--mutate-since], if any. A mutant is in scope when the list is empty, or
      when one prefix is a prefix of its recorded file ([String.starts_with]).
      Under [--mutate-since], its line must also be one of the changed lines
      ({!Changed_lines.of_git}), which git gives once, under {!Os.project_root},
      before the dry run. The line of a mutant is that of the first byte of its
      expression, so a change to a later line of an expression on more than one
      line does not put the mutant in scope. Git does not run for a catalogue
      with no mutant. A mutant out of scope is neither forked nor recorded.
    + It runs the dry run, which is {!Report.run} over [config] with [junit]
      cleared. Every other field is that of [config], [baseline] included, so
      the dry run of a [--mutate -u] run accepts what a [-u] run accepts. A site
      that no test reached and that the dry run evaluated outside every test, at
      module initialization or in a fixture release, is evaluated outside tests
      ({!Windtrap_runtime.Verdicts.Outside_tests}). A site that only tests
      marked xfail evaluated is unreached.
    + It runs the determinism probe, which is one unarmed child over the tests
      that the dry run executed. The probe agrees iff it executed as many tests,
      skipped as many and counted no failure.
    + It forks one child per reached mutant, in the order of the catalogue, and
      never forks one that is unreached or evaluated outside tests. A mutant
      with a history can have two children ({b History} below). Up to [jobs]
      children of {!Run.Loop} run at once, and one more starts when one ends.
      The verdict of a mutant is kept until each mutant before it in the
      catalogue has a verdict. Then it is committed, and the block of a survivor
      printed ({!Report.mutation_survivor}). Thus the report and the verdict
      file are the same for every value of [jobs].
    + When the last child has ended it writes the verdict file.

    {b Children.} A child runs {!Run.execute} over {!Run.for_subset} of
    [config], with the reaching tests of its mutant as the allowlist, or with
    the one test of its history for a first child. It checks baselines read-only
    and records no correction. Nothing that a child prints is visible, because
    both of its standard descriptors are [/dev/null]. No [at_exit] function runs
    in a child. Each child has a log directory of its own in the scratch
    directory of the loop, so children that run at once share no file of the
    loop. Their tests can share a file or a port of their own, which is why
    [jobs] is [1] unless a run sets it.

    {b History.} Before the first child, the loop reads the verdict file of the
    executable, which an earlier build can have written. A mutant that it
    records as killed by a test, with the digest of the source file that the
    loop reads now, can get a first child. The test must reach the mutant, must
    not be the first test that does, and must pass alone. Before the child of
    any mutant, each such test runs alone in a child with no mutant armed, up to
    [jobs] at once. The first child runs that test alone. When the first child
    kills the mutant, that is the verdict. Otherwise, a child runs every
    reaching test, before any mutant after it starts, and gives the verdict. A
    child runs each test that decides a verdict, so the history gives no verdict
    without a run. A file that is not a regular file, or that does not load,
    gives no history.

    A first child does not run the tests before its test. When the tests of a
    suite depend on their order, a first child can kill a mutant that a full
    child lets survive: the test passes alone, but fails alone with the mutant,
    and an earlier test changes the state so that it passes with the mutant. A
    test that fails alone with no mutant gets no first child.

    {b Verdicts.} A mutant is {!Windtrap_runtime.Verdicts.Killed} when its child
    counted a failure, that of a fixture release included. The verdict names the
    reaching test that failed first, if one failed. It is also killed when its
    child reported no survivor, because the child recorded no test, passed its
    deadline, did not exit with [0], or left no complete line. Otherwise it is
    {!Windtrap_runtime.Verdicts.Not_evaluated} when its child did not evaluate
    the armed site ({!Windtrap_runtime.Mutate.armed_hits} is [0]), and survived
    when it did. A child starts from the state that the dry run left, so a site
    whose result the dry run cached, in a table or a forced lazy value, can pass
    unevaluated. The report lists such a mutant with the [--arm] command that
    tests it in a new process, and names it no survivor.

    {b Tests marked xfail.} A test marked xfail ({!Test_tree.val-xfail}) reaches
    no mutant and kills none. The dry run and the probe run it, no child runs
    it, and no survivor names it.

    {b Limits.} Nothing bounds a whole run. A child that passes its deadline has
    its process group killed, and the loop goes on. The deadline is the time
    that the dry run took, read on the monotonic clock ({!Os.val-counter}), plus
    a share for the tests of the child. The share is ten times
    ([deadline_multiplier]) what the dry run measured for those tests, and at
    least one second. The probe has the same deadline, over every executed test.
    The loop reads each pipe that is ready before it looks at a deadline. Thus a
    child that exited keeps its verdict, also when a write of the report held
    the loop for longer than the deadline of the child. The loop reads a pipe at
    most 17 times ([drain_rounds]) before it looks at the deadlines and the
    signal, and keeps the first 64 KiB ([output_limit]) of what a child writes.
    Thus a child that writes and never stops cannot keep the loop past its
    deadline, or fill the memory of the loop. When the children at once
    outnumber the CPUs ([Domain.recommended_domain_count]), each deadline is
    multiplied by the children for each CPU. The children at once are [jobs],
    but at most the reached mutants. The probe runs alone, before the children
    of the mutants, and its deadline is not multiplied. On Linux, the time that
    a child or the probe waited for a CPU does not count toward its deadline
    ([waited_for_cpu]). This time is the sum of the waits of the threads of the
    processes in the group of the child, which include the processes that its
    tests start ([read_threads]). Thus other processes that hold the CPUs, for
    example the children of the other suites of a parallel [dune runtest], do
    not kill a mutant by its deadline. The sum is at most the time since the
    start of the child less [share] times the CPU time of these threads. [share]
    is the factor of the deadline of the child, and [1.] for the probe. Thus the
    deadline comes at the latest when the group used as much CPU time as the
    deadline of one job, also when its threads wait at the same time, or wait
    for the other children. The loop reads these times only when a child is past
    its deadline. The wait of a process that ended before that read counts
    toward the deadline. Other systems do not give these times.

    The runaway budget of a child ({!Windtrap_runtime.Mutate.arm}) is
    [(hits * 8) + 1000] ([budget_of]) for a site that the dry run evaluated
    [hits] times.

    {b The verdict file.} The file holds one record per reached mutant, one
    [Outside_tests] record per mutant of the population evaluated outside tests,
    and one [Unreached] record per unreached one. Each record has the digest of
    the source file of its mutant, when the loop can read the file. It is
    written to {!Windtrap_runtime.Verdicts.output_file} of the executable, by
    {!Windtrap_runtime.Verdicts.save}. Under a scope, the records of the mutants
    outside it, under another prefix or on a line that did not change, stay when
    the file there was written by this build
    ({!Windtrap_runtime.Verdicts.writer_identity}), and are dropped otherwise. A
    file that cannot be written ([Sys_error]) is one sentence on standard error
    above the outcome line, and the result is still [Reported 0].

    Only a loop that ran whole, over the whole suite, writes it. The one
    exception is the empty population of a revision under [WINDTRAP_MUTATE] (see
    {b What the environment asks}). A run whose selection narrows the suite
    writes none and says so on standard error above the outcome line. [filter],
    [exclude], [tags], [exclude_tags], [failed_only], [shard] and an active
    focus narrow the suite. The scope of [--mutate] does not.

    {b What the environment asks.} [WINDTRAP_MUTATE] reaches every test
    executable of a project, so an executable that cannot honour it is not in
    error. When [config.broadcast.mutate] holds, an empty population and a
    selection that keeps no test ({!Run.list_selection}) are no refusal. The
    result is then [Ran] of the ordinary run under {!Run.No_mutation}, before
    which an empty population says why on standard error. Every other refusal
    stands. Under [--mutate-since], when the catalogue has mutants and the
    population is empty, the verdict file is also written before the ordinary
    run. The file holds no record in the scope, and keeps the other records as a
    loop does. Thus [windtrap mutants --since] finds a file of the executable
    when no mutant is on a changed line.

    {b Refusals.} Each of these is [Reported 1] with one sentence on standard
    error ({!Os.say}). The first seven are tried in this order, and the last has
    no one place in it:
    - The platform is Windows, which has no [Unix.fork].
    - Under [--mutate-since], the changed lines cannot be read: the revision
      names no commit, the project root is in no git work tree, or git cannot
      run. This refusal stands under [config.broadcast.mutate] too.
    - The dry run is refused at startup. {!Report.run} has said why, and the
      code is [1] whatever {!Run.startup_exit_code} is.
    - The exit code of the dry run is not [0], because no test ran ([2]) or
      because the run is red.
    - The population is empty.
    - The probe disagrees with the dry run, and the sentence names the tests
      that failed in it, or it passes its deadline, is refused at startup, or
      reports nothing readable.
    - A child cannot arm its mutant, or is refused at startup. The refusal comes
      when the verdict of the mutant would be committed, and the children that
      run then are killed.
    - The supervision fails. The scratch directory cannot be created, which is
      tried before the probe, or [pipe], [fork], [select] or [waitpid] fails for
      the probe or for a child. [fork] fails in a process that has spawned a
      domain, in the dry run or before it, and the sentence then says so. *)

(** {1:armed The armed run}

    Under {!Run.Armed} the identifier is read by
    {!Windtrap_runtime.Mutate.id_of_string} and armed by
    {!Windtrap_runtime.Mutate.arm} in this process, which forks nothing.
    - An identifier that is malformed, ambiguous, or
      {!Windtrap_runtime.Mutate.Unmatched} within a file that this executable
      catalogues is [Reported 1], with the sentence of
      {!Windtrap_runtime.Mutate.pp_arm_error} on standard error, before anything
      runs.
    - {!Windtrap_runtime.Mutate.Uncatalogued} is no refusal. The same sentence
      goes to standard error before the transcript, and the result is [Ran] of
      the ordinary run under {!Run.No_mutation}.
    - With the mutant armed, it runs {!Report.run} with [baseline] set to
      {!Baseline.Check}, so it records no correction.
    - Its verdict leaves out the tests marked xfail, as the loop does. The
      unexpected pass of such a test fails the run and kills no mutant, and a
      site that only such tests evaluated is not reached
      ({!Report.mutation_not_reached}).

    The result of an armed run is [Ran], so its exit code is that of the
    ordinary run, [2] included, and it writes its JUnit file. *)

(** {1:signals Signals}

    From before its scratch directory exists until its verdict file is written,
    the loop handles [SIGINT], [SIGTERM] and [SIGHUP] as {!Run.execute} does
    during a run (see its {{!Run.section-signals}signals}).

    A child is a session of its own ([setsid]), which a terminal's signal does
    not reach. The handler therefore kills the process group of each running
    child, and the mutants of those children get no verdict, whatever the
    children reported. A signal sent to the whole process tree also reaches each
    child, and a child that it killed gets no verdict too. The report names
    these mutants in catalogue order. The children that exited before the signal
    keep their verdicts, also when the loop did not reap them yet, and the
    report commits them in catalogue order. The loop starts no child after the
    signal. When no child runs and mutants remain, the report names the next
    mutant, which no child tested. The loop then removes its scratch directory
    and writes no verdict file. It dies by the same signal last, so its parent
    sees a death by signal and no [at_exit] function runs.

    A signal that arrives once the last child has ended stops nothing. The
    verdict file is written, a second signal excepted, and the report ends as
    usual. The loop then dies by that signal, and says nothing more.

    [SIGPIPE] is handled over the same span. When the reader of standard output
    has gone away, the write that finds it gone fails. The loop then stops as it
    does for the other signals, except that it says nothing and tries no closing
    report, and it dies by [SIGPIPE]. When the process was started with
    [SIGPIPE] ignored, the [Sys_error] of the failed write escapes
    {!execute_and_report} instead, after the scratch directory is removed. *)

(** {1:pipes The pipes of the children} *)

val drain : (Unix.file_descr * Buffer.t) list -> Unix.file_descr list
(** [drain pipes] reads each descriptor of [pipes] that is ready, with no wait,
    and adds what it reads to the buffer of that descriptor. It does this again
    until no descriptor is ready, but it reads a descriptor at most 17 times
    ([drain_rounds]). A buffer keeps at most the first 64 KiB ([output_limit])
    of what its descriptor gives. The result is the descriptors that got to
    their end.

    The loop calls [drain] with the pipes of its children before it looks at the
    deadlines and the signal ({{!section-loop}Limits}). Thus a child that ended
    and that left a full pipe of 64 KiB gets to its end in one call. A pipe that
    a writer keeps full does not keep the loop from its next look.

    The function is in this interface for the unit suite. A test gives it a
    descriptor that never empties, as [/dev/zero]. A child cannot keep a pipe
    full with certainty, because the loop can read faster than the child writes.
    When [select] fails with an error other than [EINTR], [drain] raises the
    exception that the loop reports as a failure of the supervision
    ({{!section-loop}Refusals}). When [read] fails with such an error, it raises
    [Unix.Unix_error]. *)

(** {1:effects Effects}

    Beyond the effects of {!Report.run}, the loop calls [fork], [waitpid],
    [pipe] and [select], and each child calls [setsid] and closes the pipes of
    the other children. Under [--mutate-since] it runs [git] four times, before
    the dry run ({!Changed_lines.of_git}). The loop calls [kill] on the process
    group of a child that expired or was interrupted. It creates one scratch
    directory per run under [Filename.get_temp_dir_name ()], and removes it
    however the loop ends, a second signal excepted. For the source line of a
    survivor and the digest of each record it reads the recorded file of the
    mutant, under {!Os.project_root} first and then as given. It reads the
    verdict file of the executable before the first child. *)
