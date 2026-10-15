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
      the mutants that [[@mutate off]] dismisses and those that the rewriter
      filtered. The scope is the list of source-path prefixes that [--mutate]
      gave, and the revision of [--mutate-since], if any. A mutant is in scope
      when the list is empty, or when one prefix is a prefix of its recorded
      file ([String.starts_with]). Under [--mutate-since], its line must also be
      one of the changed lines ({!Changed_lines.of_git}), which git gives once,
      under {!Os.project_root}, before the dry run. The line of a mutant is that
      of the first byte of its expression, or of the pattern of a dropped case,
      so a change to a later line of an expression on more than one line does
      not put the mutant in scope. Git does not run for a catalogue with no
      mutant. A mutant out of scope is neither forked nor recorded.
    + It runs the dry run, which is {!Report.run} over [config] with [junit]
      cleared. Every other field is that of [config], [baseline] included, so
      the dry run of a [--mutate -u] run accepts what a [-u] run accepts. A site
      that no test reached and that the dry run evaluated outside every test, at
      module initialization or in a fixture release, is evaluated outside tests
      ({!Windtrap_runtime.Verdicts.Outside_tests}). A site that only tests
      marked xfail evaluated is unreached.
    + In exec mode ({b Exec mode} below), it runs one child that runs no test.
      Its time is the time that a new process takes before its first test.
    + It runs the determinism probe, which is one unarmed child over the tests
      that the dry run executed. The probe agrees iff it executed as many tests,
      skipped as many and counted no failure.
    + It runs the unarmed children of {b History} and, in exec mode, of
      {b Exec mode}.
    + It starts one child per reached mutant, in the order of the catalogue, and
      never starts one that is unreached or evaluated outside tests. A mutant
      with a history can have two children ({b History} below). The children at
      once use at most the [jobs] CPUs of {!Run.Loop}. A child uses the most
      CPUs that one of its tests used at once in the dry run. The loop rounds
      this value to the nearest integer. The value is at least 1 and at most the
      CPUs of the host. Tests that took less than 10 ms in all count as 1. These
      CPUs are the CPU time of the process in the test over the time of the
      test. On Linux, the loop also counts the waits of its threads for a CPU
      ([child_cpus]). Thus a child of a test on several domains counts as
      several jobs, also when other load held the CPUs in the dry run. The loop
      does not get the wait of a domain that a test spawns and joins. The
      workers of a stateful test are an exception. Thus other load can make the
      count smaller for a test whose thread sleeps while such domains work. A
      child that uses more than [jobs] CPUs runs alone. A child that does not
      fit waits for other children to end, and no child after it starts before
      it. The verdict of a mutant is kept until each mutant before it in the
      catalogue has a verdict. Then it is committed, and the block of a survivor
      printed ({!Report.mutation_survivor}). Thus the report and the verdict
      file are the same for every value of [jobs].
    + When the last child has ended it writes the verdict file.

    {b Children.} A child runs {!Run.execute} over {!Run.for_subset} of
    [config], with the reaching tests of its mutant as the allowlist, or with
    the one test of its history for a first child. In exec mode, a full child
    can also get the tests that the dry run executed up to the last reaching
    test ({b Exec mode}). It checks baselines read-only, records no correction
    and writes no last-failed store ({!Run.config.store}). The loop removes the
    log directory of the child, and on a busy file system a write of the store
    can take seconds, which count toward the deadline of the child. But a child
    writes the capture log of each test, because a test can read its captured
    output ({!Capture.val-output}). The time of these writes also counts toward
    the deadline, and a stall of the file system there can expire it. Nothing
    that a child prints is visible, because both of its standard descriptors are
    [/dev/null]. No [at_exit] function runs in a child. Each child has a log
    directory of its own in the scratch directory of the loop, so children that
    run at once share no file of the loop. Their tests can share a file or a
    port of their own, which is why [jobs] is [1] unless a run sets it.

    {b Exec mode.} The [children] of {!Run.Loop} tells how the loop starts a
    child. {!Run.Fork} forks each child from the state after the dry run.
    {!Run.Exec} starts each child as a new process of the executable:
    [/proc/self/exe] for native code on Linux, and
    {!Windtrap_runtime.Instr.executable} if not. The child gets the [argv] of
    the loop. {!Run.Auto}, the default, is exec mode when the process spawned a
    domain ({!domain_spawned}), before or in the dry run, and fork mode if not.
    A new process reads its request from a file ({!write_request},
    {!serve_child}). It starts from the state after module initialization, not
    from the state after the dry run. Its environment is that of the loop, with
    [TMPDIR] set to a directory of its own in the scratch directory. The names
    of these directories have one length. A suite that a deep [TMPDIR] breaks,
    for example with the path of a Unix socket, gets a longer path in a new
    process than in the dry run.

    In exec mode, a full child also starts from a new process. A reaching test
    that needs the state that an earlier test sets then fails with no mutant.
    Thus, before the child of any mutant, each different list of reaching tests
    runs one time in a new process with no mutant armed, with the children of
    {b History}. A list that does not pass gives its full children the tests
    that the dry run executed, in its order, up to the last reaching test of the
    mutant. This list is a prefix of the probe, which passed. A test after the
    first reaching test can find the state that the mutant changed, and its
    failure kills the mutant. Such a child runs every test of its list and does
    not stop at its first failure, because the mutant can make a test marked
    xfail pass, and that pass kills nothing. After a test kills the mutant, the
    child continues. A later test that hangs or crashes then gives a verdict
    that names no test, and the history of the mutant gets no killer. The cost
    is one more child for each different list of reaching tests, and all of the
    tests of a prefix for each of its children.

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

    {b Verdicts.} A child of a mutant knows if one of its processes evaluated
    the armed site: {!Windtrap_runtime.Mutate.armed_hits} counts the evaluations
    of the child. A process that a test forks writes one byte of memory that it
    shares with the child. Before the first evaluation, the child runs the code
    of the unmutated program. Thus the mutant cannot cause a failure that comes
    before the first evaluation. A failure counts when it comes in a test that
    evaluated the site, or in a test after such a test. Unless it runs every
    test of a list ({b Exec mode}), the child stops at the first failure that
    counts. It does not stop at a failure that does not count. If the byte is
    not available, each failure counts.

    A mutant is {!Windtrap_runtime.Verdicts.Killed} when its child had a failure
    that counts, that of a fixture release included. The verdict names the first
    test that failed in this way, if a test failed. This test reaches the
    mutant, except in exec mode, where it can be a test before the last reaching
    test ({b Exec mode}). It is also killed when its child evaluated the site
    and recorded no test. It is also killed when its child passed its deadline,
    did not exit with [0], or left no complete line. Such a child gives no count
    of evaluations.

    A mutant is {!Windtrap_runtime.Verdicts.Not_evaluated} when no process of
    its child evaluated the armed site. A test or a fixture release that failed
    in such a child has a cause of its own. Examples are a schedule of domains,
    the clock or the tests before it. The report names that failure under the
    mutant. An exception that escapes the run before the first evaluation also
    gives [Not_evaluated], and the report names no failure. A fork starts from
    the state that the dry run left. Thus a child can find the result that the
    dry run cached for a site, in a table or a forced lazy value. Then the child
    does not evaluate the site. The report lists such a mutant with the [--arm]
    command that tests it in a new process, and names it no survivor. In exec
    mode, a new process has no such cache, and its tests evaluate the site. When
    its child evaluated the site and had no failure that counts, the mutant is
    {!Windtrap_runtime.Verdicts.Survived}.

    {b Tests marked xfail.} A test marked xfail ({!Test_tree.val-xfail}) reaches
    no mutant and kills none. The dry run and the probe run it, no child runs
    it, and no survivor names it.

    {b Limits.} Nothing bounds a whole run. A child that passes its deadline has
    its process group killed, and the loop goes on. The deadline is the time
    that the dry run took, read on the monotonic clock ({!Os.val-counter}), plus
    a share for the tests of the child. The share is ten times
    ([deadline_multiplier]) what the dry run measured for those tests, and at
    least one second. In exec mode, each deadline also has ten times the time
    that the startup child measured. The probe has the same deadline, over every
    executed test. The startup child has a deadline of 60 seconds plus ten times
    the dry run. The loop reads each pipe that is ready before it looks at a
    deadline. Thus a child that exited keeps its verdict, also when a write of
    the report held the loop for longer than the deadline of the child. The loop
    reads a pipe at most 17 times ([drain_rounds]) before it looks at the
    deadlines and the signal, and keeps the first 64 KiB ([output_limit]) of
    what a child writes. Thus a child that writes and never stops cannot keep
    the loop past its deadline, or fill the memory of the loop. When the CPUs
    that the children use at once outnumber the CPUs of the host
    ([Domain.recommended_domain_count]), each deadline is multiplied by that
    ratio. The CPUs at once are [jobs], but at most the sum of the CPUs of the
    reached mutants. A mutant counts the most CPUs of one of its reaching tests.
    In exec mode, it counts the most CPUs of one of the tests up to its last
    reaching test. The probe runs alone, before the children of the mutants, and
    its deadline is not multiplied. On Linux, the time that a child or the probe
    waited for a CPU does not count toward its deadline ([waited_for_cpu]). This
    time is the sum of the waits of the threads of the processes in the group of
    the child, which include the processes that its tests start
    ([read_threads]). Thus other processes that hold the CPUs, for example the
    children of the other suites of a parallel [dune runtest], do not kill a
    mutant by its deadline. The sum is at most the time since the start of the
    child less [share] times a part of the CPU time of these threads. This part
    is the CPU time divided by the CPUs of the child ([child_cpus]). [share] is
    the factor of the deadline of the child, and [1.] for the probe. The CPUs of
    the child are the average of all of its tests in the dry run. They are not
    rounded, and are at most the CPUs of the host. Thus the deadline comes at
    the latest when each CPU of the child used the CPU time of the deadline of
    one job. This is also true when its threads wait at the same time, or wait
    for the other children. The threads of a child on several domains use more
    than one CPU at a time, and their wait moves the deadline too. The loop
    reads these times only when a child is past its deadline, and then at least
    every 0.1 seconds ([reread]). The wait of a process that ended before the
    first read counts toward the deadline. So does the wait of a process after
    its last read. While nothing else holds the loop, this wait is at most 0.1
    seconds for each thread of the process. Other systems do not give these
    times.

    The runaway budget of a child ({!Windtrap_runtime.Mutate.arm}) is
    [(hits * 8) + 1000] ([budget_of]) for a site that the dry run evaluated
    [hits] times.

    {b The verdict file.} The file holds one record per reached mutant, one
    [Outside_tests] record per mutant of the population evaluated outside tests,
    one [Unreached] record per unreached one, and one [Filtered] record per
    mutant of the scope that the rewriter filtered, with the reason of the
    filter. No child starts for a filtered mutant. The report counts the
    filtered mutants by reason. Each record has the digest of the source file of
    its mutant, when the loop can read the file. It is written to
    {!Windtrap_runtime.Verdicts.output_file} of the executable, by
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
    run. In the scope, the file holds only the [Filtered] records, and it keeps
    the other records as a loop does. Thus [windtrap mutants --since] finds a
    file of the executable when no mutant to test is on a changed line.

    {b Refusals.} Each of these is [Reported 1] with one sentence on standard
    error ({!Os.say}). The first nine are tried in this order, and the last has
    no one place in it:
    - The platform is Windows, which has no process groups.
    - Under [--mutate-since], the changed lines cannot be read: the revision
      names no commit, the project root is in no git work tree, or git cannot
      run. This refusal stands under [config.broadcast.mutate] too.
    - The dry run is refused at startup. {!Report.run} has said why, and the
      code is [1] whatever {!Run.startup_exit_code} is.
    - The exit code of the dry run is not [0], because no test ran ([2]) or
      because the run is red.
    - The population is empty.
    - Under {!Run.Fork}, the process spawned a domain, in the dry run or before
      it. The sentence names [--mutate-children=auto] and [exec].
    - In exec mode, the startup child passes its deadline, gives an [error]
      line, or ends with no [ready] line or with an exit code that is not [0].
    - The probe disagrees with the dry run, and the sentence names the tests
      that failed in it, or it passes its deadline, is refused at startup, or
      reports nothing readable.
    - A child cannot arm its mutant, or is refused at startup. The refusal comes
      when the verdict of the mutant would be committed, and the children that
      run then are killed.
    - The supervision fails. The scratch directory cannot be created, which is
      tried before the probe, or [pipe], [fork], [create_process_env], [select]
      or [waitpid] fails for the probe or for a child, or the request file of a
      new process cannot be written. If [fork] fails because a thread spawned a
      domain after the loop selected the mode, the sentence says so and names
      [--mutate-children=exec]. *)

(** {1:armed The armed run}

    Under {!Run.Armed} the identifier is read by
    {!Windtrap_runtime.Mutate.id_of_string} and armed by
    {!Windtrap_runtime.Mutate.arm} in this process, which forks nothing.
    - An identifier that is malformed, ambiguous, or
      {!Windtrap_runtime.Mutate.Unmatched} within a file that this executable
      catalogues is [Reported 1], with the sentence of
      {!Windtrap_runtime.Mutate.pp_arm_error} on standard error, before anything
      runs.
    - A mutant that {!Windtrap_runtime.Mutate.arm} arms but that is dismissed
      ([dismissed] is [Some _]) is [Reported 1] before anything runs. Its site
      has no guard, so an armed run of it is the unarmed run. The sentence on
      standard error gives the reason. For a {!Windtrap_runtime.Mutate.Filtered}
      mutant, it tells the user to give [-no-filter] to the rewriter.
    - {!Windtrap_runtime.Mutate.Uncatalogued} is no refusal. The same sentence
      goes to standard error before the transcript, and the result is [Ran] of
      the ordinary run under {!Run.No_mutation}.
    - With the mutant armed, it runs {!Report.run} with [baseline] set to
      {!Baseline.Check}, so it records no correction.
    - Its verdict leaves out the tests marked xfail, as the loop does. The
      unexpected pass of such a test fails the run and kills no mutant, and a
      site that only such tests evaluated is not reached
      ({!Report.mutation_not_reached}).
    - As in a child, a failure counts when a process evaluated the site in its
      test or before it. A run with no failure that counts and no evaluation is
      {!Report.mutation_not_evaluated}, with [~failed:true] when a test or a
      fixture release failed. A run with an evaluation and no failure that
      counts is {!Report.mutation_survived}, with [~failed_before:true] when a
      test failed before the first evaluation.

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

(** {1:domains Domains} *)

val domain_spawned : unit -> bool
(** [domain_spawned ()] is [true] if the process spawned a domain at any time
    before the call, also if that domain ended. OCaml refuses [Unix.fork] in
    such a process. The process can spawn the domain at module initialization or
    in a test. The module registers one hook with [Domain.before_first_spawn] at
    its initialization, and [domain_spawned] reads what the hook recorded.

    The function is in this interface for the unit suite. A fixture calls it in
    a process of its own, because after a spawn the process cannot fork. *)

(** {1:requests Requests}

    A child that is a new process of the suite executable gets a request in
    place of the state of the parent. *)

(** The type for what a child does with the tests of its request. *)
type kind =
  | Probe
      (** The child runs the tests with no mutant armed. It gives the counts of
          the run: [probe <executed> <skipped> <failed> <indices>...]. *)
  | Alone
      (** The child runs the tests with no mutant armed. It gives [passes] or
          [fails]. *)
  | Mutant of { id : Windtrap_runtime.Mutate.id; budget : int }
      (** The child arms the mutant [id] with the runaway [budget] and runs the
          tests. It gives the verdict: [survived], [not_evaluated],
          [killed <index>] or [killed]. When a test or a fixture release failed
          without an evaluation of the site, it gives [not_evaluated <index>] or
          [not_evaluated release]. If the mutant does not arm, it gives
          [error <diagnostic>]. *)
  | Startup
      (** The child runs no test and gives [ready]. The loop measures the time
          that a new process takes before its first test. *)

type request = {
  suite : string;  (** The name of the suite of the dry run. *)
  config : Run.config;
      (** The configuration of the child, from {!Run.for_subset}. *)
  paths : string list list;
      (** The tests of the child, in the order of the dry run. *)
  kind : kind;
}
(** The type for the request of a child. It holds only data. *)

val write_request : string -> request -> unit
(** [write_request path request] writes [request] to the file [path]. The file
    has a header line, the identity of the executable file, the fingerprint of
    the catalogue of mutants and the request in [Marshal] format. The module
    reads the identity one time, at its initialization. For native code on
    Linux, it is the identity of [/proc/self/exe]. If not, it is the identity of
    {!Windtrap_runtime.Instr.executable}.

    The function is in this interface for the unit suite. *)

val serving : unit -> bool
(** [serving ()] is [true] in a child that is a new process of the loop: the
    environment variable [WINDTRAP_MUTATE_CHILD] was set and not empty at the
    initialization of this module.

    The function is in this interface for the unit suite. *)

val serve_child : suite:string -> Test_tree.t list -> bool
(** [serve_child ~suite tests] is [false] if the process is not a child of the
    loop ({!serving} is [false]). It is [true] if the request is for another
    suite: the caller must run nothing and return, because a later call of
    {!Windtrap.run} in the same main is for that suite. If not, [serve_child]
    does these steps and does not return:
    - It runs the request. These requests give the line [error <diagnostic>]: a
      request file that it cannot read, a request file that is not complete, a
      request from another executable or another catalogue, and a request with a
      test that [tests] does not have.
    - It writes one line to the pipe and calls [Unix._exit 0], as a forked child
      does.

    The environment variable [WINDTRAP_MUTATE_CHILD] gives the path of the
    request file. At the initialization of this module, before the modules of
    the suite initialize, a child does these steps:
    - It removes the variable from the environment, so that a process that the
      suite starts does not serve the request again.
    - It calls [setsid].
    - It moves its standard input, the write end of the verdict pipe, to a new
      descriptor with close-on-exec. Then its standard input is [/dev/null]. If
      it cannot move the pipe, it calls [Unix._exit 2] and writes no line.

    {!Windtrap.run} calls [serve_child] before it parses the command line. If a
    main has no call of {!Windtrap.run} for the suite of the request, the
    process ends with no line, and the loop counts that as a failure of the
    child. *)

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

(** {1:looks The looks at a child} *)

val next_look : left:float -> waited:(unit -> float) -> float * float
(** [next_look ~left ~waited] is the seconds until the deadline of a child, and
    the most seconds until the loop looks at the child again. [left] is the
    seconds from the clock to the deadline that the dry run gives the child.

    If [left] is more than [0.], the two numbers are [left], and [next_look]
    does not call [waited]. If not, the child is past this deadline. Then
    [waited ()] is the seconds that the group of the child waited for a CPU,
    which move the deadline later. The first number is [left +. waited ()], and
    the second number is at most 0.1 seconds ([reread]). Thus the loop reads the
    wait again at least every 0.1 seconds ({{!section-loop}Limits}). The loop
    kills the child when the first number is [0.] or less.

    The function is in this interface for the unit suite. A test of the loop
    cannot make sure that a process of a child ends between two looks. *)

(** {1:effects Effects}

    Beyond the effects of {!Report.run}, the loop calls [fork], [waitpid],
    [pipe] and [select], and each child calls [setsid] and closes the pipes of
    the other children. In exec mode ({!Run.children}), the loop calls
    [create_process_env] in place of [fork]. The pipes are close-on-exec, so a
    new process gets no pipe of another child. For each child, the loop writes a
    request file and makes a temporary directory in its scratch directory. It
    gives the directory to the child in [TMPDIR], and it removes the file and
    the directory when it reaps the child. In exec mode, the report that no
    signal stopped has a line that tells that the children are new processes,
    and why. The line comes above the outcome line ({!Report.mutation_finish}).
    Under [--mutate-since] it runs [git] four times, before the dry run
    ({!Changed_lines.of_git}). The loop calls [kill] on the process group of a
    child that expired or was interrupted. It creates one scratch directory per
    run under [Filename.get_temp_dir_name ()], and removes it however the loop
    ends, a second signal excepted. For the source line of a survivor and the
    digest of each record it reads the recorded file of the mutant, under
    {!Os.project_root} first and then as given. It reads the verdict file of the
    executable before the first child.

    At module initialization, the module reads the status of its executable file
    ([stat]) and the environment variable [WINDTRAP_MUTATE_CHILD]. If the
    variable is set and not empty, the module removes it and calls [setsid]. It
    copies the standard input to a new descriptor and opens [/dev/null] as the
    standard input. Then {!serve_child} reads the request file and exits the
    process with [Unix._exit]. *)
