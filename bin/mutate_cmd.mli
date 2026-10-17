(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The [windtrap mutants] command.

    The command merges the verdict files that [--mutate] runs wrote and reports
    on a whole project. It reports the mutants that survived every executable
    that reached them, the mutants that no executable reached, and the number of
    mutants that the rewriter filtered, for each reason. It only reads files, so
    it runs no test and drives no build. A build gates on its exit code, since a
    [--mutate] run exits 0 whatever it finds.

    {!run} is the whole command.
    {!Windtrap.Private.Report_sections.mutation_report} states what the report
    holds. This interface states the {{!section-files}files} that are merged,
    what the {{!section-merge}merge} decides (the verdicts, the reaching tests,
    the order of the survivors and the launcher of the [reproduce:] command),
    the {{!section-gate}gate}, the {{!section-since}changed lines}, and the
    {{!section-format}machine format}, whose keys and values are frozen. *)

(** {1:files Files}

    The verdict files are those that {!Data_files.discover} finds for
    [Windtrap_runtime.Verdicts.format] and the [PATH] arguments. A [PATH] that
    cannot be used fails the command and is never skipped, because a file left
    out can hold the one kill of a mutant, which would then be reported as a
    survivor.

    A file is judged from the identity on its header ({!Data_files.identity})
    before it is loaded: a file of another build is excluded whatever its
    records hold, and a file of the current build must load. A file of another
    build is one whose {!Data_files.val-freshness} is not [Fresh]. It is
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

(** {1:since Changed lines}

    [--since REV] keeps, in each file that is kept, only the records of the
    mutants on a line that changed since the git revision [REV]
    ({!Windtrap.Private.Changed_lines.of_git}). The line of a mutant is that of
    its identifier: the line of the first byte of its expression, or of the
    pattern of a dropped case. The paths of the records are relative to the root
    of the project that wrote the file, and git runs in that root, once for each
    root:
    - For a file below a build directory, the root is the parent of the build
      directory ({!Windtrap_runtime.Instr.build_root}).
    - For a file in a [_windtrap/mutants] directory, the root is the parent of
      [_windtrap].
    - For another file, the root is the first root of {!Data_files.discover}:
      the current directory under [PATH] arguments.

    The merge, the report, the document and the gate then see only these
    records, so a survivor on a line that did not change does not fail the
    command, and a filtered mutant on such a line is not counted. The lines are
    those of the work tree when the command runs. A verdict file that a build of
    an earlier source wrote can put another mutant on such a line, so the suites
    must run again after the change, before the merge.

    When the root of a file holds no file of its records, the command stops with
    exit code [1]. Git cannot give the lines of these mutants, and an empty
    report would pass the gate. *)

(** {1:merge The merge}

    The verdicts are those of [Windtrap_runtime.Verdicts.merge] over the files
    that are kept, in which a kill by one executable wins. A mutant that some
    file reached survives the merge iff it survived in each of those files, and
    a mutant that no file reached is unreached. A mutant that a file filtered is
    filtered when no other file has a verdict of a test for it. The counts of
    the report are read off the merged verdicts, and its scope is
    {!Windtrap.Private.Report_sections.scope.Executables} with the number of
    files kept.

    {b Killed elsewhere.} A verdict [Killed_elsewhere] counts as killed. When
    the merged verdict of a mutant is [Killed_elsewhere], no file of the merge
    kills it directly. For each executable that such verdicts name, the command
    then gives one note on standard error. The note tells how many mutants count
    as killed by that executable and which run to do again. If the file of the
    killer is in the merge, the run to do again is the run of the executables
    that skipped the mutants. The same applies if the killer no longer exists
    ({!Windtrap_runtime.Instr.exe_location}). In the other cases, the run to do
    again is the run of the killer. These notes come before the report and do
    not change the exit code.

    {b Reaching tests.} The reaching tests of a survivor are the union of those
    of every file in which the mutant survived. Each is paired with the label of
    its file, and the pairs are sorted by label and then by test, without
    duplicates. The label is the base name of the executable that the file
    records. For the inline-test runner of dune, whose base name is the same in
    every library, it is the name of the library, [<lib>] in
    [.<lib>.inline-tests/inline-test-runner.exe]. For a file that records no
    identity it is the base name of the file. No reaching test has a location,
    because the command links no test tree.

    {b Flaky kills.} A merged [Windtrap_runtime.Verdicts.Flaky] verdict has the
    test and the failure of the smaller pair. The report names the label of the
    first file kept, in path order, whose record of the mutant has that pair. A
    flaky mutant is reached and not scored, and it does not fail the command.

    {b Unstable verdicts.} The report lists, for each file that is kept, each
    record whose verdict changed its class
    ([Windtrap_runtime.Verdicts.changed]), with the label of the file. The rows
    are sorted by identifier, and then in path order of the files. The list
    comes from each file before the merge, so it keeps the previous verdict of
    each executable. Under [--since] it has only the records on the changed
    lines. It does not change the score or the exit code.

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
    survived and not evaluated, unrounded. It is [100.] when the merge has none
    of them. [--min-score PCT] requires the score to be at least [PCT]. It runs
    after the report or the document is printed, and does not run when standard
    output refuses them. The outcome line of the report then states the gate and
    whether it is met ({!Windtrap.Private.Report_sections.mutation_line}). A
    score that prints equal to the threshold can thus fail. Without the flag,
    the command fails when a mutant survived. *)

(** {1:format Machine format}

    [--json] makes standard output the document, so the report is not printed.
    The outcome line is not printed on standard output either. Under
    [--min-score], standard error gives its text behind [windtrap:], whether the
    gate is met or not. The keys and the values below are frozen. A later
    version can add a key, and that key does not change the meaning of the
    others. A change to the meaning of a key increments ["version"].

    The document is one object with the keys ["version"], ["summary"],
    ["executables"], ["mutants"], ["filtered"], ["flaky"] and ["unstable"].
    ["version"] is the number [1].

    ["summary"] is an object with these keys:
    - ["reached"] is the sum of the three counts that follow it. It does not
      count the flaky mutants, which the outcome line counts as reached.
    - ["killed"], ["survived"], ["not_evaluated"], ["outside_tests"],
      ["unreached"], ["filtered"] and ["flaky"] are each the count of the merged
      mutants that have that verdict.
    - ["score"] is the score of the {{!section-gate}gate}, with two decimals.

    ["executables"] is an array with one object for each file that is kept, in
    path order. Two executables can have the same name. The object has these
    keys:
    - ["name"] is the label that the report gives the executable
      ({{!section-merge}the merge}).
    - ["path"] is the executable that the file records, as
      {!Windtrap_runtime.Instr.exe_identity} spells it. It is [null] for a file
      that records none.

    ["mutants"] is an array with one object for each merged mutant that is not
    filtered or flaky, in the order of [Windtrap_runtime.Mutate.compare_id]. The
    object has these keys:
    - ["id"] is the identifier, as [Windtrap_runtime.Mutate.id_to_string] spells
      it.
    - ["file"], ["line"], ["col"] and ["rewrite"] are the four parts of the
      identifier.
    - ["before"] is the text of the original site, and ["after"] the text of the
      mutant, as [Windtrap_runtime.Mutate.site] gives them. For most rewrites,
      these are two expressions. For ["drop"], they are the pattern and the
      guard of the case, with [...] for its body, as ["| Add -> ..."] and
      ["| Add when false -> ..."]. For ["skip"], ["after"] is ["()"], and for
      ["none"], ["None"].
    - ["verdict"] is one of ["killed"], ["survived"], ["not_evaluated"],
      ["outside_tests"] and ["unreached"]. A mutant killed elsewhere is
      ["killed"].
    - ["runs"], for a survivor only: the runs of its children that let it
      survive, summed over the verdict files.
    - ["tests"] is in the object of a survivor only. It is an array of the tests
      that reached the survivor.

    ["filtered"] is an array with one object for each merged mutant that the
    rewriter filtered, in the same order. The object has the keys of an object
    of ["mutants"] from ["id"] to ["after"], and the key ["reason"] in place of
    ["verdict"]. ["reason"] is the reason of the filter, as ["zero operand"].

    ["flaky"] is an array with one object for each merged flaky mutant, in the
    same order. The object has the keys of an object of ["mutants"] from ["id"]
    to ["after"], and the keys ["test"] and ["failure"] in place of ["verdict"].
    ["test"] is an object with the keys of an object of ["tests"], for the test
    that killed the mutant in the file that the report names. ["failure"] is the
    first failure of that test in a run with no mutant, on one line.

    ["unstable"] is an array with one object for each row of the unstable
    section ({{!section-merge}the merge}), in its order. The object has the keys
    ["id"], ["executable"], the index of the file in ["executables"],
    ["previous"] and ["verdict"]. The last two are ["killed"], ["survived"] or
    ["not_evaluated"].

    ["tests"] has one object for each reaching test of the survivor in each file
    in which it survived. The objects are sorted by file, and then by the names
    of the test, one name after the other. There are no duplicates. This order
    can be different from the order of the report. The object has these keys:
    - ["executable"] is the index of the file in ["executables"].
    - ["test"] is the path of the test as an array of names, the outermost group
      first.

    Each string is written by {!Windtrap.Private.Text.json_string}. *)

(** {1:running Running} *)

val run : string list -> int
(** [run args] executes the command on [args], the arguments that follow
    [mutants] on the command line, and is the exit code of the process. It never
    calls [exit].

    The command line is [windtrap mutants [OPTIONS] [PATH...]]. [-h], [--help]
    and [-help] print the help page on standard output. [--min-score PCT] and
    [--json] are those of the {{!section-gate}gate} and the
    {{!section-format}machine format}, and [--since REV] that of the
    {{!section-since}changed lines}. [--color MODE] is the runner's flag, read
    by {!Windtrap.Private.Cli.parse_color}. Without it, the colour mode of the
    report is its mirror [WINDTRAP_COLOR], read by
    {!Windtrap.Private.Cli.color_mode}. The mode is resolved for standard output
    by {!Windtrap.Private.Os.resolve_color}, and a document is never styled. A
    flag that takes a value can also be spelled [--flag=value]. Every other
    argument that starts with [-] is refused, and the rest are [PATH]s.

    [run] does these steps, in this order:
    - It parses the arguments.
    - It reads [WINDTRAP_COLOR] for the report when [--color] is absent.
    - It finds the {{!section-files}files}, judges them and loads them.
    - Under [--since], it reads the {{!section-since}changed lines} and keeps
      the records on them.
    - It says the notes of {{!section-merge}the merge} on standard error.
    - It prints the report or the document of the {{!section-merge}merge} on
      standard output.
    - It runs the gate.

    A step before the gate that fails returns its code, and the steps after it
    do not run. Every other line goes to standard error, through
    {!Windtrap.Private.Os.say} but for the usage line that follows a usage
    error.

    The result is:
    - [0] when the report or the document was printed and the merge passes.
      Without [--min-score], the merge passes when no mutant survived. Under
      [--min-score], it passes when the score meets the gate, and a survivor
      does not fail it. Unreached mutants are listed and do not fail the merge.
      The result is also [0] for the help page.
    - [1] when the report or the document was printed and the merge fails.
      Without [--min-score], the merge fails when at least one mutant survived
      every executable that reached it. Under [--min-score], it fails when the
      score is below the gate. Thus under the gate, a merge with no survivor can
      fail, because a mutant that was not evaluated lowers the score. Without
      the gate, a mutant that is equivalent to the original is dismissed at its
      site with [[@mutate off]].
    - [1], with no report, when a [PATH] cannot be used or when no verdict file
      is found. It is also [1] when a file that is not excluded cannot be read,
      is corrupt or has another format version. It is also [1] when every file
      is excluded, and under [--since] when the changed lines cannot be read,
      for example for a [REV] that names no commit, or when the root of a file
      holds no file of its mutants.
    - [1] when standard output refuses the report or the document, for example
      on a full disk. The reader then has only a part of it. Standard error
      gives the reason, and the gate does not run.
    - [2] for a usage error. A usage error is an unknown option, a flag that
      lacks its value, a [--min-score] that is not in the interval
      \[[0];[100]\], a [--since] value that is empty or starts with [-], or a
      [--color] value that the flag refuses.
    - [2] also for a [WINDTRAP_COLOR] that the flag would refuse, when [--color]
      is absent and the report is printed. A document reads no [WINDTRAP_COLOR].
*)
