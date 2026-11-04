(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The [windtrap mutants] command.

    The command merges the verdict files that [--mutate] runs wrote and reports
    on a whole project. It reports the mutants that survived every executable
    that reached them, and the mutants that no executable reached. It only reads
    files, so it runs no test and drives no build. A build gates on its exit
    code, since a [--mutate] run exits 0 whatever it finds.

    {!run} is the whole command.
    {!Windtrap.Private.Report_sections.mutation_report} states what the report
    holds. This interface states the {{!section-files}files} that are merged,
    what the {{!section-merge}merge} decides (the verdicts, the reaching tests,
    the order of the survivors and the launcher of the [reproduce:] command),
    the {{!section-gate}gate}, and the {{!section-format}machine format}, whose
    keys and values are frozen. *)

(** {1:files Files}

    The verdict files are those that {!Data_files.discover} finds for
    [Windtrap_runtime.Verdicts.format] and the [PATH] arguments. Each suite of
    an executable writes its own file, and the command merges the files of all
    suites. A file of a suite that no longer runs stays in the merge until a new
    build of its executable makes it stale, or until a person deletes it. A
    [PATH] that cannot be used fails the command and is never skipped, because a
    file left out can hold the one kill of a mutant, which would then be
    reported as a survivor.

    A file is judged from the identity on its header ({!Data_files.load_fresh})
    before it is loaded: a file of another build is excluded whatever its
    records hold, and a file of the current build must load. A file of another
    build is one whose {!Data_files.type-freshness} is not [Fresh]. It is
    excluded from the merge because a verdict of another build can claim a kill
    that the code no longer earns, and no flag keeps it. The first file that is
    not excluded and cannot be read or parsed, its header included, ends the
    command with its {!Windtrap_runtime.Verdicts.pp_error}, because leaving it
    out could turn a killed mutant into a survivor. On standard error the
    command says the {!Data_files.warnings} of the excluded files, then
    {!Data_files.all_excluded} when no file is left, and then once, in a
    sentence of its own, how to refresh them. When every excluded file lies
    under a build directory ({!Windtrap_runtime.Instr.build_dir}), the command
    [WINDTRAP_MUTATE=1 dune runtest --force --instrument-with
     ppx_windtrap.mutate] follows that sentence on a line of its own.

    The source of a mutated file is looked for under the roots of
    {!Data_files.discover}: the root of the project after a search, and the
    current directory under [PATH] arguments. A survivor whose source is not
    found keeps its identifier and its rewrite, and its block has no source
    line. *)

(** {1:merge The merge}

    The verdicts are those of [Windtrap_runtime.Verdicts.merge] over the files
    that are kept, in which a kill by one executable wins. A mutant that some
    file reached survives the merge iff it survived in each of those files, and
    a mutant that no file reached is unreached. The counts of the report are
    read off the merged verdicts, and its scope is
    {!Windtrap.Private.Report_sections.scope.Executables} with the number of
    executables of the files kept. Files that record one executable
    ({!Data_files.executable}) count as one. A file that records no identity
    counts as one executable.

    {b Unknown.} A mutant that no file killed and one holds as
    [Windtrap_runtime.Verdicts.Unknown] is unknown. The first file kept, in path
    order, whose writer tested its suite and holds it so names it, with the
    reason it records after its label and suite, and its launcher is that
    file's. A mutant that only refused files hold as unknown is counted under
    the first of them instead. Every refused file is named, in path order, by
    its label and the suite that it records, with its reason and that count.
    When the count is 0 and an earlier refused file counts a mutant that the
    file holds as unknown, the row says [no other mutant unknown]. Any other
    count of 0 says [0 mutants unknown]. The outcome line counts the refused
    files as suites.

    {b Killed elsewhere.} Before the merge, the command judges each
    [Windtrap_runtime.Verdicts.Killed_elsewhere] record of the executable [exe].
    The other files of [exe] are the files of the merge that record [exe],
    except the file of the record. The record stands in two cases:
    - Another file of [exe] holds the mutant as [Killed].
    - No other file of [exe] holds the mutant.

    In each other case the kill of [exe] does not hold, and the skip does not
    count: the record is refused. The command leaves out every refused record of
    the mutant, and the records that stay decide a verdict. When that verdict is
    [Outside_tests] or [Unreached], or no record stays, the command replaces the
    refused record with an [Unknown] verdict, whose reason names [exe]. The run
    that skipped the mutant reached it, so the mutant is not unreached. In the
    other cases the command drops the refused record.

    For each executable that skipped and each [exe], the command gives at most
    one note on standard error. The note covers the mutants of the refused
    records that no file of the merge kills directly, so a merged
    [Killed_elsewhere] verdict gets one and a merged [Killed] verdict does not.
    An executable and an [exe] with no such mutant get no note. The note counts
    each mutant once and tells to run that executable again. When the files of
    that executable in the note record more than one suite, the note names the
    suites. When the executable is [exe] itself, the note names its suite.

    A [Killed_elsewhere] verdict that stands counts as killed, in the report, in
    the score and in the document. When the merged verdict of a mutant is
    [Killed_elsewhere], no file of the merge kills it directly, and no other
    file of the killer holds it. For each executable that such verdicts name as
    the killer, the command then gives one note on standard error, before the
    report. The note tells how many mutants count as killed by that executable
    and which run to do again:
    - When the killer no longer exists ({!Windtrap_runtime.Instr.exe_location}),
      or when a file of the killer that did not skip is in the merge and does
      not hold the mutants, the run of the executables whose files skipped the
      mutants. A run of the killer does not give the kill then. A file that
      records no identity is named by its path.
    - In the other cases, the run of the killer.

    The notes do not change the exit code.

    {b Reaching tests.} The reaching tests of a survivor are the union of those
    of every file in which the mutant survived. Each is paired with the label of
    its file, and the pairs are sorted by label and then by test, without
    duplicates. When files of more than one suite of one label give one test
    path, each such test is followed by [(suite <suite>)], so that the two stay
    apart. The label is the base name of the executable that the file records.
    For the inline-test runner of dune, whose base name is the same in every
    library, it is the name of the library, [<lib>] in
    [.<lib>.inline-tests/inline-test-runner.exe]. For a file that records no
    identity it is the base name of the file. No reaching test has a location,
    because the command links no test tree.

    {b Order.} The survivors are sorted by their number of reaching tests, the
    most first, and then in the order of [Windtrap_runtime.Mutate.compare_id].

    {b Launcher.} The [reproduce:] command of the report arms the first
    survivor, and its launcher is spelled from one verdict file. Each reaching
    test of that survivor names a candidate: the first file kept, in path order,
    that bears the label of the test and in which the mutant survived. The
    launcher is that of the first candidate, in the order of the reaching tests,
    whose launcher is an [`Exe], and [`Mirrors] when no candidate has one. A
    launcher is a {!type:Windtrap.Private.Run.invocation}:
    - [`Mirrors] when the file records no identity, or that of an inline-test
      runner, which takes its arguments from dune alone.
    - [`Exe] of [dune exec --instrument-with ppx_windtrap.mutate <target> --]
      when the identity is relative, which means an executable below a build
      directory. [<target>] is the identity without its first component, the
      build context, spelled by {!Windtrap.Private.Report_sections.dune_exec}.
    - [`Exe] of the path of the executable, as one such word, when the identity
      is absolute. *)

(** {1:gate The gate}

    The score is {!Windtrap.Private.Report_sections.mutation_score} of the
    merge. It is the percentage of the killed mutants among those killed,
    survived and not evaluated, unrounded. An unknown mutant does not count. The
    score is [100.] when the merge has none of these mutants, and the outcome
    line then says [no scored mutant]. [--min PCT] makes the merge pass when
    {!Windtrap.Private.Report_sections.mutation_gate_met} is [true]: the score
    is at least [PCT] and no file is refused. A survivor then does not fail the
    merge. A refused file fails the merge with a gate or without one. The gate
    runs after the report or the document is printed, and does not run when the
    write fails. The outcome line of the report then gives the gate and its
    result ({!Windtrap.Private.Report_sections.mutation_line}), and the score
    with its two counts beside its rounding. *)

(** {1:format Machine format}

    [--json] makes standard output the document, so the report is not printed.
    The outcome line is not printed on standard output either. Under [--min],
    standard error gives its text behind [windtrap:], when the gate is met and
    when it is not. The keys and the values that follow are frozen. A later
    version can add a key, and that key does not change the meaning of the
    others. A change to the meaning of a key increments ["version"]. Under
    [--lines] or [--diff], the verdict counts, ["reached"], ["score"] and
    ["mutants"] hold only the mutants on the lines, as the report does. But
    ["executables"] still lists every file that is kept, and ["refused"] still
    counts every refused file, because each file stays in the merge.

    The document is one object with the keys ["version"], ["summary"],
    ["executables"] and ["mutants"]. ["version"] is the number [1].

    ["summary"] is an object with these keys:
    - ["reached"] is the sum of ["killed"], ["survived"], ["not_evaluated"] and
      ["unknown"].
    - ["killed"], ["survived"], ["not_evaluated"], ["unknown"],
      ["outside_tests"] and ["unreached"] are each the count of the merged
      mutants that have that verdict.
    - ["refused"] is the count of the refused files.
    - ["score"] is the score of the {{!section-gate}gate}, with two decimals. It
      is [100.00] when no mutant is scored, as the ["percentage"] of
      [windtrap coverage --json] is with no point.

    ["executables"] is an array with one object for each file that is kept, in
    path order. Two files can have the same name, and the files of the suites of
    one executable have the same name and path. The object has these keys:
    - ["name"] is the label that the report gives the executable
      ({{!section-merge}the merge}).
    - ["path"] is the executable that the file records, as
      {!Windtrap_runtime.Instr.exe_identity} spells it. It is [null] for a file
      that records none.
    - ["suite"] is the suite that the file records, or [null].
    - ["refused"] is the reason why the writer of the file could not test its
      mutants, or [null] when it tested them.

    ["mutants"] is an array with one object for each merged mutant, in the order
    of [Windtrap_runtime.Mutate.compare_id]. The object has these keys:
    - ["id"] is the identifier, as [Windtrap_runtime.Mutate.id_to_string] spells
      it.
    - ["file"], ["line"], ["col"] and ["rewrite"] are the four parts of the
      identifier.
    - ["end_line"] and ["end_col"] are the one-based line and the zero-based
      column of the byte after the mutated expression.
    - ["before"] is the source text of the original expression.
    - ["after"] is the source text of the armed expression.
    - ["verdict"] is one of ["killed"], ["survived"], ["not_evaluated"],
      ["unknown"], ["outside_tests"] and ["unreached"]. A mutant killed
      elsewhere ({{!section-merge}the merge}) is ["killed"].
    - ["tests"] is in the object of a survivor only. It is an array of the tests
      that reached the survivor.
    - ["executable"] and ["reason"] are in the object of an unknown mutant only.
      ["executable"] is the index in ["executables"] of the file that the report
      names for the mutant ({{!section-merge}the merge}), and ["reason"] is the
      reason that this file records.

    ["tests"] has one object for each reaching test of the survivor in each file
    in which it survived. The objects are sorted by file, and then by the names
    of the test, one name after the other. There are no duplicates. This order
    can be different from the order of the report. The object has these keys:
    - ["executable"] is the index of the file in ["executables"].
    - ["test"] is the path of the test as an array of names, the outermost group
      first.

    {!Windtrap.Private.Json.string} writes each string. *)

(** {1:running Running} *)

val run : string list -> int
(** [run args] executes the command on [args], the arguments that follow
    [mutants] on the command line, and is the exit code of the process. It never
    calls [exit].

    The command line is [windtrap mutants [OPTIONS] [PATH...]]. [-h], [--help]
    and [-help] print the help page on standard output. [--min PCT] and [--json]
    are those of the {{!section-gate}gate} and the
    {{!section-format}machine format}. A [PCT] that is not a number from [0] to
    [100] is a usage error. [--lines SPEC] and [--diff FILE] repeat and add up
    into a {!Windtrap.Private.Lines.t}, read by
    {!Windtrap.Private.Lines.of_spec} and {!Windtrap.Private.Lines.of_diff}.
    Each file's records off those lines are dropped before the
    {{!section-merge}merge}, so the report, the document and the exit code are
    those of the mutants on the lines. A malformed [SPEC] or an unreadable
    [FILE] is a usage error. [--color MODE] is the runner's flag, read by
    {!Windtrap.Private.Cli.parse_color}. Without it, the colour mode of the
    report is its mirror [WINDTRAP_COLOR], read by
    {!Windtrap.Private.Cli.color_mode}. The mode is resolved for standard output
    by {!Windtrap.Private.Os.resolve_color}, and a document is never styled. A
    flag that takes a value can also be spelled [--flag=value]. Every other
    argument that starts with [-] is refused, and the rest are [PATH]s.

    [run] does these steps, in this order:
    - It parses the arguments.
    - It reads [WINDTRAP_COLOR] for the report when [--color] is absent.
    - It finds the {{!section-files}files}, judges them and loads them.
    - It judges the skips and says the notes of the mutants killed elsewhere
      ({{!section-merge}the merge}) on standard error.
    - It prints the report or the document of the {{!section-merge}merge} on
      standard output.
    - It runs the gate.

    A step before the gate that fails gives its code, and the steps after it do
    not run. Every other line goes to standard error, through
    {!Windtrap.Private.Os.say} but for the usage line that follows a usage
    error.

    The result is:
    - [0] when the report or the document was printed and the merge passes.
      Without [--min], the merge passes when no mutant survived and every file
      was tested. Under [--min], it passes when the score meets the gate and
      every file was tested, and a survivor does not fail it. Unreached, unknown
      and not-evaluated mutants are listed and do not fail the merge by
      themselves. The result is also [0] for the help page.
    - [1] when the report or the document was printed and the merge fails.
      Without [--min], the merge fails when at least one mutant survived every
      executable that reached it. Under [--min], it fails when the score is
      below the gate. Thus under the gate, a merge with no survivor can fail,
      because a mutant that was not evaluated lowers the score. The merge also
      fails when a file is refused: a merge without the verdicts of that suite
      is not the project's. Without the gate, a mutant that is equivalent to the
      original is dismissed at its site with [[@mutate off]].
    - [1], with no report, when a [PATH] cannot be used or when no verdict file
      is found. It is also [1] when a file that is not excluded cannot be read,
      is corrupt or has another format version. It is also [1] when every file
      is excluded.
    - [1] when the write of the report or of the document to standard output
      fails with an error, for example on a full disk. The reader then has only
      a part of it. Standard error gives the reason, and the gate does not run.
      A closed pipe, as after [| head], ends the process by SIGPIPE instead,
      unless the parent ignores that signal.
    - [2] for a usage error. A usage error is an unknown option, a flag that
      does not have its value, a [--min] that is not in the interval
      \[[0];[100]\], a malformed [--lines], an unreadable [--diff], or a
      [--color] value that the flag refuses.
    - [2] also for a [WINDTRAP_COLOR] that the flag would refuse, when [--color]
      is absent and the report is printed. A document reads no [WINDTRAP_COLOR].
*)
