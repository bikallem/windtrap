# Mutation testing

This page shows how to find the changes to a library that no test
notices, one mutant at a time, and how to kill, reproduce or dismiss
each. The reference is `windtrap mutants --help`, in the
[last section](#the-commands-options), and the suite's `--help`. The
example is `examples/08-mutation/`, and the transcripts ran at the root
of a copy of it made a project of its own, as the
[blueprint](../../examples/x-blueprint/README.md#copying-the-project-out)
shows.

## Instrumenting a library for mutation

Mutation testing is a field of the library stanza, and the tests are
ordinary `(test)` stanzas.

`dune`:

```lisp
(library
 (name windtrap_example_mutation)
 (modules calc)
 (instrumentation
  (backend ppx_windtrap.mutate)))

(test
 (name test_calc)
 (modules test_calc)
 (libraries windtrap windtrap_example_mutation))
```

The `instrumentation` field names the backend, `ppx_windtrap.mutate`.
A build that passes `--instrument-with ppx_windtrap.mutate` compiles
every mutant of the library into it, each behind a guard, and a run
executes the original code until it tests a mutant. A plain build
compiles the library as written. The field repeats, and one library can
carry both this backend and [coverage](coverage.md)'s.

## Testing a suite's mutants

The library holds a calculator.

`calc.ml`:

```ocaml
type op = Add | Sub | Mul | Div

let apply op a b =
  match op with
  | Add -> a + b
  | Sub -> a - b
  | Mul -> a * b
  | Div -> if b = 0 then invalid_arg "Calc.apply: division by zero" else a / b

let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

let abs n =
  if (n >= 0) [@mutate off "both arms yield 0 at n = 0"] then n else -n
```

`test_calc.ml`:

```ocaml
open Windtrap
module Calc = Windtrap_example_mutation.Calc

let addition =
  group "addition"
    [ test "adds" (fun () -> equal int 5 (Calc.apply Calc.Add 2 3)) ]

let subtraction =
  group "subtraction"
    [
      test "stays positive" (fun () -> is_true (Calc.apply Calc.Sub 10 4 > 0));
      test "subtracts" (fun () -> equal int 6 (Calc.apply Calc.Sub 10 4));
    ]

let multiplication =
  group "multiplication"
    [ test "multiplies" (fun () -> equal int 12 (Calc.apply Calc.Mul 3 4)) ]

let division =
  group "division"
    [
      test "divides" (fun () -> equal int 3 (Calc.apply Calc.Div 7 2));
      test "rejects a zero divisor" (fun () ->
          raises_match (Exn.invalid_arg ~sub:"division by zero") (fun () ->
              Calc.apply Calc.Div 1 0));
    ]

let sign =
  group "sign"
    [
      test "is 1 for a positive" (fun () -> equal int 1 (Calc.sign 5));
      test "is -1 for a negative" (fun () -> equal int (-1) (Calc.sign (-5)));
    ]

let abs =
  group "abs"
    [
      test "negates a negative" (fun () -> equal int 3 (Calc.abs (-3)));
      test "keeps zero" (fun () -> equal int 0 (Calc.abs 0));
    ]

let () =
  exit
    (run "calc" [ addition; subtraction; multiplication; division; sign; abs ])
```

To test the mutants a suite reaches, run the suite built with the
backend and pass `--mutate`. The run executes the suite once, recording
which tests reach each mutant, then runs each reached mutant in a
process of its own with those tests alone. A mutant that no test fails on prints
as a `SURVIVED` block: its location in the compiler's format, which
editors and dune jump to, its identifier, the rewrite, the source line
and the tests that ran it. No test calls `sign 0` or `sign 1`:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate
calc: 10 passed in 1.3ms.

─────────────────────── survivors ────────────────────────
File "calc.ml", line 10, characters 16-21:
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

File "calc.ml", line 10, characters 20-21:
  SURVIVED  calc.ml:10:20:int  0 → 1
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

File "calc.ml", line 10, characters 37-42:
  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      sign › is -1 for a negative  test_calc.ml:32
──────────────────────────────────────────────────────────

─────────────────── never reached (1) ────────────────────
  1  calc.ml   line 10
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 3 survived of 9 reached by this suite, 6 killed, 1 never reached, score 66.7% (6/9)
```

## Reproducing a survivor

The `reproduce:` line arms the first survivor. `--arm` for a mutant that
`[@mutate off]` dismisses is a usage error and exits 1. `--arm ID` runs the
suite once with that mutant active, names it first, records no
correction, and ends on one verdict line:

- `mutant killed.`
- `mutant survived: the armed site was evaluated N times and no test
  failed.` Other forms of this line say that only tests marked `xfail`
  failed, that only tests before the first evaluation failed, or that
  only a process that a test forked evaluated the site.
- `mutant not evaluated: no selected test ran the site.` When a test
  failed, the line adds that the mutant did not cause the failure.
- `mutant not reached: only xfail tests ran the site.`

A test that fails kills the mutant as in a mutation run: only when it or
an earlier test in the selection ran the site. An evaluation outside
every test counts as one before every test. A test whose worker crashed,
or was killed at its limit, kills the mutant, because its evaluations
are unknown. Under `-x` the run stops at the first failure that kills
the mutant. Under `dune runtest`, the mirror arms it in every suite that
holds its file, as in
`WINDTRAP_MUTATE_ARM=ID dune runtest --force --instrument-with ppx_windtrap.mutate`
(see [Mutation testing a project](#mutation-testing-a-project) for
`--force`). Arming a killed mutant shows the failure that killed it:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutant calc.ml:10:16:ge armed: n > 0 → n >= 0
calc: 10 passed in 2.1ms.
mutant survived: the armed site was evaluated 2 times and no test failed.
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:6:11:add
mutant calc.ml:6:11:add armed: a - b → a + b
calc: 10 tests
──────────────────────── failures ────────────────────────
  FAIL  subtraction › subtracts (mutant armed)
    test_calc.ml:12
      12 │ test "subtracts" (fun () -> equal int 6 (Calc.apply Calc.Sub 10 4));

    expected  6
    actual    14
──────────────────────────────────────────────────────────

9 passed, 1 failed in 1.8ms.
mutant killed.
```

## Testing one test's mutants

To judge a new test, narrow the mutation run. `--mutate=PREFIX` tests
only the mutants of the files whose path starts with a prefix, and still
saves its verdicts. The filters select the tests as in any run; a
filtered run lists the mutants its tests never reached and saves no
verdict. `stays positive` checks a sign that `a - b → a + b` keeps:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate=calc.ml -f "stays positive"
calc: 1 passed in 1.1ms.

─────────────────────── survivors ────────────────────────
File "calc.ml", line 6, characters 11-16:
  SURVIVED  calc.ml:6:11:add  a - b → a + b
      6 │ | Sub -> a - b

    1 test ran this line and did not fail:
      subtraction › stays positive  test_calc.ml:11
──────────────────────────────────────────────────────────

─────────────────── never reached (9) ────────────────────
  9  calc.ml   lines 5, 8, 10
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:6:11:add -f 'stays positive'
windtrap: verdicts not saved: this run's selection narrows the suite, and a partial run's verdicts would stand in the project merge as the whole.
mutants: 1 survived of 1 reached by the 1 selected test, 9 never reached, score 0.0% (0/1)
```

## Testing a change's mutants

A change is judged by the mutants on its own lines. `--lines` keeps the
mutants on the lines it names, as `--lines=calc.ml:10` or
`--lines=lib/a.ml:3-7,12,lib/b.ml:40`, each file as its mutants'
identifiers spell it, relative to the project root. `--diff FILE`
reads the lines that a `git diff -U0` output adds or changes; with the
default `a/` and `b/` prefixes it names the files as the identifiers do
when the repository's root is the project's. Both narrow `--mutate`,
whose prefixes they combine with, and the run still saves its verdicts,
replacing those on its lines. `windtrap mutants` takes the same two
flags, and reports, and fails on, the mutants of those lines alone, and
`windtrap coverage` the points of those lines (see
[coverage.md](coverage.md)). Their mirrors are `WINDTRAP_LINES` and
`WINDTRAP_DIFF`; a relative path in `WINDTRAP_DIFF` is read from the
project root.

```
$ git diff -U0 > change.diff
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate --diff change.diff
```

## What a mutation run runs

A mutation run runs in passes, and prints neither the focus warning nor
the withheld-correction warning:

- The dry run is the suite's ordinary run. Under `-u` it accepts
  corrections before any mutant is armed.
- The determinism probe runs the suite again and checks that it passes
  again.
- Each reached mutant runs with its reaching tests, up to the first
  failure in or after the test that first evaluates its site. One that
  evaluates its site more than `hits * 8 + 1000` times, `hits` being
  the dry run's count, fails its test, and the mutant is killed.
- Under `--mutate-retry N`, the job of each survivor runs again, up to
  `N` more times (see
  [Running a survivor again](#running-a-survivor-again)).

Every pass runs in worker processes, and the probe and each mutant in a
worker of its own, started as a run's workers are (see [Running
tests](running-tests.md#running-tests-in-worker-processes)): none starts
from what the dry run or another mutant left, a table filled or a lazy
value forced, so a cache cannot hide a mutant. The mutant is armed once
the worker's module initialisation is over. They run up to `-j` at once,
as tests do, and are reported in catalogue order. Unless `--seed` is
given, a mutation run draws its property cases from one fixed seed,
`s1:6d7574616e747321`, so a verdict is the same on every run of one
binary.

A mutant whose run ends before its tests do, because the process
crashed or exited or passed a deadline taken from the dry run, is
unknown, and so is no survivor. The report lists it under `unknown`
with the reason and an `arm:` command, which runs the suite with it
armed and shows what happens. A mutant whose run does not evaluate
its site, as when an earlier test that its run leaves out
decided whether the site runs, is not evaluated and is no survivor
either, listed under `not evaluated` with its `arm:` command.

Until a mutant's run evaluates the site, the run executes the code
without the mutant. Thus a test that fails before the first evaluation
does not kill the mutant. Its failure has another cause, for example a
schedule of domains, the clock or an earlier test. The run does not stop
there. It runs the next reaching test. A failure in the test that
evaluates the site, or after it, kills the mutant. A fixture release or
an `at_exit` function that fails kills the mutant when the run evaluated
the site at any time. When the run does not evaluate the site, the
mutant is not evaluated, and the report names the failure under it, as
`a failure that the mutant did not cause: calc › memo`. For this rule,
an evaluation in a process that a test forks counts, also under
`--arm`. The dry run does not see such an evaluation, so it does not
make a test reach the site.

A site that no test runs, and that module initialization or a
fixture release runs, is evaluated outside tests. No run tests its
mutant, and the report lists its line under `evaluated outside tests`,
apart from the lines never reached.

A test marked `xfail` reaches no mutant. The dry run and the probe run
it, and no mutant's run does. A line that only such tests run is never
reached, and an `--arm` run of its mutant ends on `mutant not reached`.

The mutation run exits 0 whatever it finds. It exits 1, with a sentence
on standard error, when a pass fails or no mutant is left to test.

## Running a survivor again

A test whose result depends on the clock, on threads or on a schedule
of domains can let a mutant survive one run and kill it in the next
run. For example, under `--mutate-workers` a kill can depend on a
schedule (see
[Stateful tests on several domains](#stateful-tests-on-several-domains)).

`--mutate-retry N` (mirror `WINDTRAP_MUTATE_RETRY`) runs the job of a
survivor again, up to `N` more times. Each of these runs is a retry. A
retry runs in a fresh worker, with the tests, the deadline and the
budget of the first run. `N` is from 0 to 100, and the default is 0.

The first run gives the verdict as a run with no retry does. After the
first run, only a kill changes the verdict. A retry can end early, for
example at its deadline, or not evaluate the site. Such a retry leaves
the mutant a survivor, and the next retry runs. Thus a retry cannot
take a survivor out of the score. A mutant survives when its first run
survives and no retry kills it. The number of runs in its title counts
the first run and each retry. Each retry that hangs costs its deadline.

The loop runs the retries in passes. The first pass runs the probe and
the job of each mutant. Each later pass runs again the jobs of the
mutants that survived the pass before it. A pass runs its jobs up to
`-j` at once. A job that runs alone in the first pass also runs alone in
a retry. Only survivors cost more time, and the probe runs one time.

The report prints the block of a survivor in the last pass, and gives
the number of runs after its title:

```
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0  (3 runs)
```

Below its reaching tests, the block gives one line for each retry that
ended early or did not evaluate the site, with the reason:

```
    run 2: its run passed its deadline of 1.0s
```

The live line names a mutant in a retry as it did in the first pass.
The verdict file does not keep the number of runs. Thus
`windtrap mutants` and its `--json` do not show it. The `reproduce:`
and `arm:` commands do not have `--mutate-retry`, because an `--arm` run
runs the suite one time. Thus an `--arm` run can kill a survivor of 3
runs.

A retry makes a false survivor less probable. It does not make a
verdict deterministic. For example, a mutant that 1 run in 10 kills
survives 3 runs in about 73 of 100 mutation runs. The loop does not run
a killed mutant again, so a kill that only some runs give stays a kill.

A retry changes how frequently the verdict of a mutant changes between
two mutation runs (see [Unstable verdicts](#unstable-verdicts)). For a
mutant that most runs kill, a retry makes this change less probable.
For a mutant that few runs kill, a small `N` makes this change more
probable, and a large `N` makes it less probable. For example, take a
mutant that 1 run in 10 kills. With no retry, its verdict changes in
about 18 of 100 pairs of mutation runs. With 2 retries, it changes in
about 40 of 100 pairs.

A signal stops the loop during a retry as it does during a first run.
A survivor that waits for its next run gets no verdict, and the loop
writes no verdict file. When the signal comes between two passes, the
message names the first survivor that waits, as in
`interrupted before the retry of calc.ml:10:16:ge`.

If neither the command line nor a mirror gives `--mutate`, the flag on
the command line is a usage error. The mirror of the flag alone has no
effect on a suite that does not mutate.

## Stateful tests on several domains

Under mutation testing, a stateful test on several domains spawns no
worker domains. It runs each program one time on the domain of the
test, the branches one after the other. Thus a kill does not depend on
a schedule. But a mutant that only a concurrent order of the calls
shows survives, and no test reaches code that only a worker runs.

`--mutate-workers` (mirror `WINDTRAP_MUTATE_WORKERS`) lets such a test
spawn its worker domains under `--mutate` and `--arm`, as it does
without mutation testing. Each program then runs 50 times, and its
branches run on the workers. Use it for the code of a structure that
domains share. It has these costs:

- A run of such a test does about 50 times more work.
- A kill can depend on a schedule. A mutant that one run kills can
  survive the next run, and an `--arm` run of the same mutant can pass.
- The job of a mutant that such a test reaches runs alone, and so does
  the determinism probe. Under `-j`, no other job runs at the same time
  as such a job, because its workers need the CPUs. The other jobs run
  up to `-j` at once.

The dry run records each test that spawned worker domains. The
deadline of a job is the time of the whole dry run plus ten times the
time of the job's tests in the dry run (at least 1 s). The pools of
these tests also ran in the dry run, so their time is in the deadline.
A worker process ends after a test that spawned domains. Then a new
worker process runs the rest of the job. The time that the new worker
process takes to start does not count toward the deadline. But each
start leaves out at most the deadline, so a start that hangs ends the
job.

The `reproduce:`, `arm:` and `replay:` commands of such a run keep
`--mutate-workers`, also in the JUnit file and in the GitHub
annotations. A verdict file does not record the flag, so the commands
of `windtrap mutants` do not have it. Add `--mutate-workers` to such a
command yourself.

If neither the command line nor a mirror gives `--mutate` or `--arm`,
the flag on the command line is a usage error. Its mirror alone has no
effect on a suite that does not mutate.
Thus a suite that opts in through its dune stanza sets the mirror, as
in `(setenv WINDTRAP_MUTATE_WORKERS 1 (run %{test}))`, because the
flag in the stanza is a usage error under a plain `dune runtest`.
Outside mutation testing, a stateful test always spawns its worker
domains.

## Dismissing an equivalent mutant

A mutant that no test can tell from the original is equivalent. `abs`
returns `n` when `n >= 0`, and the mutant `n > 0` differs at zero only,
where both branches return 0. To dismiss it, put `[@mutate off
"reason"]` on the expression, as `calc.ml` does; the site is then
neither tested nor counted. It dismisses every mutant of the
expression, in this version and in any later one that gives the
expression more mutants. `[@@mutate off]` dismisses a binding,
`[@@@mutate off]` and `[@@@mutate on]` the structure items between
them, and `[@@@mutate exclude_file]` a file. Only `off` takes a reason,
which no report prints. `--arm` names it when it refuses the mutant:
a dismissed site has no guard, so `--arm` for its mutant is a usage
error and exits 1.

## Mutation testing a project

A suite's mutation run covers its own executable. To judge the project,
run every suite with `WINDTRAP_MUTATE=1` and merge the verdict files
with `windtrap mutants`. `WINDTRAP_MUTATE` is the mirror of `--mutate`,
where `1` is the bare flag, `0` its absence, and a value that spells no
boolean the prefixes. A suite with no mutant to test, such as a suite
over another library, runs as usual and says why on standard error. A
mutant killed by one executable is killed. A mutant that no executable
killed and one could not judge is unknown, and one that another did not
evaluate is not evaluated; neither is a survivor. The command exits 1
when a mutant survived every executable that reached it, listing the
most reached first, and when an executable could not mutation-test its
suite: the merge names it under `not mutation-tested`, with the mutants
its file leaves unknown. A gate on the score can replace the first
condition (see [Gating on the score](#gating-on-the-score)).

Each suite of an executable writes its own verdict file, and the report
names the suite of a file. A refused row names it, as in
`t.exe (suite lts)`, and the outcome line counts the suites not
mutation-tested. A later refused row whose mutants an earlier row
already counts says `no other mutant unknown`. When two suites of one
executable report the same test path, each witness row ends with
`(suite X)`.

Dune does not track `WINDTRAP_MUTATE`. A suite that ran without it
does not run again when it is set, unless its build changed, and the
merge then finds no verdict of that build.
`(deps (env_var WINDTRAP_MUTATE))` on a test stanza makes dune run it
again when the variable changes. Without it, `--force` makes dune run
every suite:

```
$ WINDTRAP_MUTATE=1 dune runtest --force --instrument-with ppx_windtrap.mutate
calc: 10 passed in 2.7ms.

─────────────────────── survivors ────────────────────────
File "calc.ml", line 10, characters 16-21:
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

File "calc.ml", line 10, characters 20-21:
  SURVIVED  calc.ml:10:20:int  0 → 1
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

File "calc.ml", line 10, characters 37-42:
  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      sign › is -1 for a negative  test_calc.ml:32
──────────────────────────────────────────────────────────

─────────────────── never reached (1) ────────────────────
  1  calc.ml   line 10
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 3 survived of 9 reached by this suite, 6 killed, 1 never reached, score 66.7% (6/9)
$ dune exec windtrap -- mutants
───────────────────── survivors (3) ──────────────────────
File "calc.ml", line 10, characters 16-21:
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      test_calc.exe  sign › is -1 for a negative
      test_calc.exe  sign › is 1 for a positive

File "calc.ml", line 10, characters 20-21:
  SURVIVED  calc.ml:10:20:int  0 → 1
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      test_calc.exe  sign › is -1 for a negative
      test_calc.exe  sign › is 1 for a positive

File "calc.ml", line 10, characters 37-42:
  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      test_calc.exe  sign › is -1 for a negative
──────────────────────────────────────────────────────────

─────────────────── never reached (1) ────────────────────
  1  calc.ml   line 10
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 3 survived of 9 reached, 6 killed, 1 never reached, 1 executable, score 66.7% (6/9)
```

Only code that a suite's own process runs reaches a mutant. A binary
that is not a suite, such as a command-line tool that a cram test or a
dune rule runs or that a test starts as a child process, reaches none,
even when it links the instrumented library. Mutants in code that only
such a binary runs are listed as never reached when a suite links their
module, and are missing from the reports when no suite links it.
`WINDTRAP_MUTATE_ARM` arms a mutant in a suite, never in such a binary.
[Coverage](coverage.md#where-the-dumps-are) does count that code, as
each instrumented executable writes its own dump. A command-line tool
can then be fully covered and have no mutant reached. To test those
mutants, put the tool's entry point in the library, call it from a
test, and check what it prints with `expect` or `expect_file`.

## Skipping the mutants that another suite killed

A project with several suites tests a mutant in each suite that reaches
it. One kill is enough for the merge, so the other suites do work that
does not change the report. `--skip-killed` (mirror
`WINDTRAP_SKIP_KILLED`) skips this work. It narrows `--mutate`, as
`--lines` does. If neither the command line nor a mirror gives
`--mutate`, the flag on the command line is a usage error. The mirror
alone has no effect on a suite that does not mutate.

After the dry run, the suite reads the other verdict files in its
directory, the files of the other suites of its executable included. A
reached mutant gets no worker when another file kills it directly. The
record of that kill must also be of the same mutant: the rewriter read
the same source file for the two executables, and the mutant has the
same renderings and extent. A mutant that another suite skipped does not cause a skip,
so a skip always comes from a run that tested the mutant.

The suite does not use a refused file, and it gives no warning for it. A
refused file holds no kill. The suite also does not use these files, and
it gives a warning for each of them:

- A file that it cannot read, or that is not a verdict file of this
  version.
- A file that names no executable.
- A file whose executable was deleted since, or rebuilt since. These
  are the files that `windtrap mutants` leaves out.

The verdict file records a skipped mutant as killed elsewhere, with the
executable of the file that killed it. The report of the suite counts
the mutant as not tested, and a line above the outcome line names the
executable of each file that the suite used, with the number of skips
that it gave:

```
killed elsewhere: 2 mutants, not tested, from the verdict files of default/test/a.exe (1), default/test/b.exe (1)
```

`windtrap mutants` first judges each skip. A skip stands when another
file of the killing executable kills the mutant. It also stands when no
other file of the killing executable holds the mutant, for example
because the file of the killing suite is now stale. In every other case
the kill does not hold, and the skip does not count:

The merge leaves out every skip that does not count. The other records
of the mutant then give the verdict:

- When they give a verdict of a reached mutant, the merge drops the
  skip, and that verdict stands. For example, a survivor that the
  killing suite now reports stays a survivor.
- When they give no such verdict, the mutant is unknown, because the
  suite that skipped it reached it. Two suites that skipped one mutant
  because of each other give this result when no other record gives a
  verdict of a reached mutant. A third file that holds the mutant as
  never reached gives this result too.

When no file of the merge kills the mutant directly, a note on standard
error then tells to run the suite that skipped the mutant again. A
mutant that another file kills gets no such note. A skip that stands
counts as killed, also in the score and in the `--json` document. When
no file of the merge kills that mutant directly, a note on standard
error tells which suite to run again. The notes do not change the exit
code.

The option uses only the files on disk. Thus run the fast suites first,
for example in a first `dune runtest`, and then the slow suites with
`--skip-killed`. Do not run two suites with the option at the same
time, as `dune runtest` does by default. Each suite can skip a mutant
because of the earlier file of the other. Then no new file kills the
mutant, and the merge gives it as unknown. To run the suites one after
the other, use `dune runtest -j 1`. A suite tests a mutant again when
the rewriter read different source files of the mutant for the two
suites. The digests then differ.

## Unstable verdicts

A mutation run compares the verdict of each mutant with the verdict of
the last run of the same suite. When the verdict changed, the report
lists the mutant in the `unstable` section. A change to a test can
cause this. A test whose result depends on the clock, on the order of
domains or on the tests before it can cause it too:

```
────────────────────── unstable (2) ──────────────────────
  The source of each mutant did not change, but its verdict did.
  calc.ml:10:16:ge   survived → killed
  calc.ml:10:37:le   killed → survived
──────────────────────────────────────────────────────────
```

The run compares only the verdicts killed, survived and not evaluated.
These verdicts do not appear in the section:

- An unknown verdict. The run of the mutant gave no verdict.
- A mutant that no test reached, or that ran outside every test.
- A mutant that the suite skipped under `--skip-killed`. No test of the
  suite ran it.

After such a verdict, the next run compares with the verdict before it.
For example, a mutant that survived, then was skipped, and then was
killed appears as `survived → killed`. Two survivors with other
reaching tests have the same verdict.

The run compares a mutant only with the same mutant: the rewriter read
the same source file, with the same digest, and the mutant has the same
renderings and extent. Thus a change to the source file of a mutant
starts a new comparison. The earlier verdict file can come from another
build, because nearly every change to a test builds the executable
again. It must come from the same suite.

These runs show no section: a run whose selection narrows the suite, a
refused run, a run that a signal stopped, and a run whose file cannot
be written. Under `--lines`, `--diff` or `--mutate=PREFIX`, the section
has only the mutants of the scope. The section does not change the
score or the exit code.

A scoped run keeps the records outside its scope only when the same
build wrote the earlier file and tested its suite. In all other cases
the run drops these records, and their previous verdicts go away. A
refused run also drops the records outside its scope. Then the next
full run lists no change of these mutants across that gap. For example,
change a test, which builds the executable again, and then run the
suite under `--mutate=PREFIX` of one module. The next full run compares
the mutants of the other modules with nothing.

The verdict file keeps the previous verdict of each mutant. Thus
`windtrap mutants` gives, for each verdict file, the last change that
the file records for each mutant, with the executable and the suite of
the file. Under a scope, a run keeps the records outside the scope, so
that change can come from a run before the last one. The rows come
from each verdict file, sorted by mutant and then by file. Under
`--json`, the array `unstable` holds the same rows, each with the index
of its verdict file in `executables`.

## Gating on the score

The outcome line gives the mutation score. The score is the percentage
of killed mutants among the mutants that were killed, that survived, or
that were not evaluated. These mutants do not count in the score:

- A mutant that no test reached.
- A mutant that ran outside every test.
- An unknown mutant. Its run gave no verdict, so it is not a kill and
  not a survivor.

The line gives the score with the killed and the counted mutants, as
`score 66.7% (6/9)`. When no mutant counts and no gate is given, the
line gives no score.

A project can keep a survivor that it does not plan to kill. To gate on
the score and not on each survivor, give `--min PCT` to
`windtrap mutants`. The command then exits 1 when the score is less
than `PCT`, and the outcome line gives the gate and its result. The gate
compares the score before it is rounded. It reads a merge with no
scored mutant as 100%, and the line then says `no scored mutant`. Under
`--lines` or `--diff`, the score is that of the mutants on the lines:

```
$ dune exec windtrap -- mutants --min 60 | tail -n 1
mutants: 3 survived of 9 reached, 6 killed, 1 never reached, 1 executable, score 66.7% (6/9), minimum 60%: ok
```

A suite that was not mutation-tested fails the merge also under a gate,
because the merge does not have the verdicts of that suite. The gate
then says `FAILED`. When the write of the report or of the document to
standard output fails with an error, for example on a full disk, the
command gives the reason on standard error and exits 1. The gate does
not run then. A closed pipe ends the command by SIGPIPE, unless the
parent ignores that signal. The mutation run of a suite gives the score
too, and has no gate.

## Exporting the verdicts

For other tools, `--json` prints the merge as one JSON document on
standard output, in place of the report. The document has its version,
the counts and the score, the verdict files, and each mutant with its
verdict. A survivor also has the tests that ran it, and an unknown
mutant has its reason. A test names its verdict file by its index in
`executables`, because two files can have the same name. Under
`--lines` or `--diff`, the verdict counts, the score and `mutants` hold
only the mutants on the lines. But `executables` still lists every
verdict file, and `refused` still counts every refused file. Under
`--min`, the outcome line goes to standard error, and the exit code is
that of the gate. A later version can add keys. A change
to the meaning of a key increments `version`.
[`bin/mutate_cmd.mli`](../../bin/mutate_cmd.mli) gives each key:

```
$ dune exec windtrap -- mutants --json --lines=calc.ml:10
{ "version": 1,
  "summary": { "reached": 5, "killed": 2, "survived": 3,
    "not_evaluated": 0, "unknown": 0, "outside_tests": 0,
    "unreached": 1, "refused": 0, "score": 40.00 },
  "executables": [
    { "name": "test_calc.exe", "path": "default/test_calc.exe", "suite": "calc", "refused": null } ],
  "mutants": [
    { "id": "calc.ml:10:16:ge",
      "file": "calc.ml", "line": 10, "col": 16, "rewrite": "ge",
      "end_line": 10, "end_col": 21,
      "before": "n > 0", "after": "n >= 0",
      "verdict": "survived",
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] },
        { "executable": 0, "test": ["sign", "is 1 for a positive"] } ] },
    { "id": "calc.ml:10:20:int",
      "file": "calc.ml", "line": 10, "col": 20, "rewrite": "int",
      "end_line": 10, "end_col": 21,
      "before": "0", "after": "1",
      "verdict": "survived",
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] },
        { "executable": 0, "test": ["sign", "is 1 for a positive"] } ] },
    { "id": "calc.ml:10:27:int",
      "file": "calc.ml", "line": 10, "col": 27, "rewrite": "int",
      "end_line": 10, "end_col": 28,
      "before": "1", "after": "0",
      "verdict": "killed" },
    { "id": "calc.ml:10:37:le",
      "file": "calc.ml", "line": 10, "col": 37, "rewrite": "le",
      "end_line": 10, "end_col": 42,
      "before": "n < 0", "after": "n <= 0",
      "verdict": "survived",
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] } ] },
    { "id": "calc.ml:10:48:int",
      "file": "calc.ml", "line": 10, "col": 48, "rewrite": "int",
      "end_line": 10, "end_col": 50,
      "before": "(-1)", "after": "0",
      "verdict": "killed" },
    { "id": "calc.ml:10:56:int",
      "file": "calc.ml", "line": 10, "col": 56, "rewrite": "int",
      "end_line": 10, "end_col": 57,
      "before": "0", "after": "1",
      "verdict": "unreached" } ],
  "unstable": [ ] }
```

## Killing a survivor

A survivor names a behaviour no test checks. To kill the three survivors
of [Testing a suite's mutants](#testing-a-suites-mutants), add tests at
zero and at one to the `sign` group:

`test_calc.ml`:

```ocaml
let sign =
  group "sign"
    [
      test "is 1 for a positive" (fun () -> equal int 1 (Calc.sign 5));
      test "is -1 for a negative" (fun () -> equal int (-1) (Calc.sign (-5)));
      test "is 0 for zero" (fun () -> equal int 0 (Calc.sign 0));
      test "is 1 for one" (fun () -> equal int 1 (Calc.sign 1));
    ]
```

The mutation run then kills every mutant the suite reaches, and the
project's merge passes:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate
calc: 12 passed in 2.7ms.
mutants: 10 reached by this suite, 10 killed, score 100.0% (10/10)
$ dune exec windtrap -- mutants
mutants: 10 reached, 10 killed, 1 executable, score 100.0% (10/10)
```

## What is mutated

Each mutant rewrites one expression, and the last part of its
identifier names the rewrite:

- `not` negates a condition that is neither a comparison nor a
  connective: the condition of an `if` or a `while`, or a guard.
- A comparison in a condition moves by one boundary: `<` becomes `<=`
  (`le`), `<=` becomes `<` (`lt`), `>` becomes `>=` (`ge`), `>=` becomes
  `>` (`gt`), `=` becomes `<>` (`neq`) and `<>` becomes `=` (`eq`).
- `&&` becomes `||` (`or`), and `||` becomes `&&` (`and`).
- `+` becomes `-` (`sub`) and `-` becomes `+` (`add`); `+.` and `-.`
  swap likewise (`fsub`, `fadd`).
- `del` drops a statement: `e1` in `e1; e2` does not run. It asks
  whether a test observes what the statement does.
- `int` nudges an integer literal by one: `1` becomes `0`, and any other
  `n` becomes `n + 1`, in the type of its suffix.
- `bool` flips `true` or `false`, outside a condition and the operands
  of `&&` and `||`, where `not` already acts.
- `none` replaces `Some e` with `None`, and `e` does not run.
- `tail` replaces `h :: t` with `t`, and `h` does not run. A list
  literal is one site, at its bracket: `[a; b; c]` becomes `[b; c]`. In
  a chain, as `a :: b :: t`, the outermost `::` alone is a site.

Some code carries no mutant, because no test should pin it or none can
run it. `del` leaves a resource release alone: a call of `close`,
`close_in`, `close_out`, their `_noerr` forms or `closedir`. `int`
leaves alone an operand of `+` or `-`, which `add` and `sub` move
already; an argument of a function whose name ends in `create`, as the
capacity of `Hashtbl.create 16`; the constant of a comparison in a
condition when the nudge is the comparison's own boundary move, as the
`0` of `x < 0`, since `x < 1` is `x <= 0`. `bool` leaves alone the
argument of `~cloexec`. None of these five rewrites has a mutant in code
that runs when the module is initialized, before any test, as in a
top-level `let limit = 64` or `let () = setup (); main ()`, since no run
can judge it. `none` and `tail` also leave alone the right-hand side of
a `let rec` outside its functions and `lazy` bodies, as
`let rec ones = 1 :: ones`, which the compiler accepts only as written.
When the head of a `tail` site written as `h :: t` is a list, as in
`[x] :: acc` or `(x :: cur) :: acc`, it starts at the first byte of the
site and has no `tail` mutant of its own, since one identifier names one
site.

The rewriter also gives no mutant where the syntax shows the mutant
equivalent to the original. It gives none where the mutant changes a
log message or a failure message alone. These cases are:

- `x + 0` and `x - 0`, with an integer `0`. `0 + x` keeps its mutant.
- `a && a` and `a || a`, when `a` is a name, a constructor without an
  argument or a field.
- The condition of `if c then e else e`, when the two branches are the
  same code. Code that can give its location, as `__LOC__`, `assert` or
  a `match`, is never the same code as its copy.
- Each site in the arguments of `Logs.app`, `Logs.err`, `Logs.warn`,
  `Logs.info`, `Logs.debug` and `Logs.msg`. The rule reads these names
  as the source spells them, so a module `Logs` of your project in
  another file matches too. A file that declares a module `Logs` loses
  the rule. The list is fixed, and no flag adds a name.
- An integer or boolean literal in the arguments of `failwith` or
  `invalid_arg`. A file that binds one of these names loses the rule.
  The rewriter does not see a binding that an `open` or an `include` of
  another unit brings in. The rule does not cover `raise`.

The last two cases are a choice and not an equivalence. A test can read
a log message or a failure message, and thus kill such a mutant. No test
should pin the text of a message. No attribute and no flag gives such a
mutant back.

These two rules read `f x`, `f @@ x`, `x |> f`, `Printf.ksprintf f` and
`Format.kasprintf f` as calls of `f`. `f @@ x` and `x |> f` match only
when `f` is a name. Thus the message of `Logs.err ~src @@ fun m -> ...`
keeps its mutants, and that of `Logs.err ~src (fun m -> ...)` does not.

A statement in these arguments keeps its mutants, because it acts on the
state of the program. In `a + b + 0` the outermost `+` has no mutant, so
`a + b` carries the mutant of the chain. A `[@mutate off]` on such a
site records it as dismissed, as on any other site.

A comparison outside a condition, as in `let ok = a < b`, carries no
mutant, and neither does an `assert`. In a chain of one operator, as
`a + b + c`, the outermost application alone is a site. Inline tests
(`let%test`, `let%expect_test` and `module%test` with its helpers)
carry no mutant, and the rest of their file is mutated. A file that
rebinds an operator loses the rewrites of its family: the four
arithmetic operators, the six comparisons or the two connectives. A file
that declares a constructor `Some`, `None` or `::` loses `none` and
`tail`.

The `none` mutant names `None` without a module, and the `tail` mutant
gives `t` the type of `h :: t`. The rewriter does not see a `Some` or a
`::` that an `open` or the expected type takes from another module, as
in `let f x : M.t = Some x`. If `M.t` has no `None`, or its `::` does
not join two values of one type, the mutant does not compile. The
compiler shows the error at the expression, and `[@mutate off "reason"]`
on the expression removes the mutant.

## Where the verdicts are

A suite's `--mutate` run over the whole suite writes one verdict file
under `_build/_mutants`, and the next such run of that suite replaces
the file. Each suite of an executable has its own file, named from the
executable and the suite. Thus a main that calls `Windtrap.run` with
more than one suite name keeps the verdicts of each suite. The
partitions of an inline-test library, which dune runs at the same time,
also keep their verdicts. An executable outside any build directory
writes under `_windtrap/mutants` in its working directory.

A run under `--mutate=PREFIX` replaces the verdicts under its prefixes
and keeps the others, when the same build wrote the file for the same
suite. A verdict file records its executable, a digest of its bytes and
its suite. Each record keeps the digest of the source file of its mutant,
as the rewriter read it, which `--skip-killed` compares. Each record also
keeps the previous verdict of its mutant
(see [Unstable verdicts](#unstable-verdicts)).
`windtrap mutants` merges the files of all suites, and counts the files
of one executable as one executable. It leaves out a file whose
executable was deleted or rebuilt since, with a warning, as
[`windtrap coverage`](coverage.md#when-a-dump-is-excluded) does a dump.

A suite that you rename, or that no longer runs, leaves its file in the
directory. `windtrap mutants` merges this file until a new build of the
executable makes it stale. To remove its verdicts before that, delete
the file.

## Mutation testing without dune

The mutation backend is applied without dune as
[the coverage backend](coverage.md#instrumenting-without-dune) is, and
the suite then runs with `--mutate`.

## When a run cannot mutate

A mutation run starts a worker process for each mutant. It is refused on
Windows, and in a process forked from the test executable that spawned a
domain before its run: that process cannot fork, and a new start of the
program would not reach its run. A test may spawn a domain. A run that
is refused, or whose selection narrows the suite, still writes its
verdict file when this build has none, saying why, and the project's
merge names the executable and the suite under `not mutation-tested`.
`--mutate` and `--arm` together are a usage error. `--arm` refuses a
mutant that `[@mutate off]` dismisses, names the reason, and exits 1:
its site has no guard, so no run can arm it. An interrupt ends the
run: the running mutants are killed, and no verdict file is written. The
message on standard error names the mutant of the next job that the run
gives, or the determinism probe. Between two passes of
`--mutate-retry`, it names the first survivor that waits for its retry.

## The command's options

`windtrap mutants --help` lists its options; the suite's own flags are
in [Running tests](running-tests.md):

```
$ dune exec windtrap -- mutants --help
windtrap mutants - merge .mutants verdict files and report the survivors

usage: windtrap mutants [OPTIONS] [PATH...]

Merges the .mutants verdict files written by mutation runs and reports the
mutants that survived every test executable. Without PATH arguments the files
are found under the build directory's _mutants (or _windtrap/mutants in a tree
built without one), walking up from the current directory to the enclosing
project root; PATH arguments (.mutants files, or directories searched
recursively) replace that default.

The score is the percentage of killed mutants among those killed, survived and
not evaluated. Runs no tests and drives no build. Exits 1 when an executable
could not mutation-test its suite. Exits 1 also when any mutant survived every
executable that reached it, or under --min when the score is below PCT.

OPTIONS:
  --min=PCT
      Exit 1 when the score is below PCT, and not for a survivor alone.

  --json
      Machine-readable report on standard output.

  --lines=FILE:A-B,...
      Report only the mutants on these lines of these files.

  --diff=FILE
      Report only the mutants on the lines that FILE, the output of git diff
      -U0, adds or changes.

  --color=MODE (env WINDTRAP_COLOR)
      Color output: always, never or auto.

  -h, --help
      Print this help and exit.

ENVIRONMENT (no flag):
  NO_COLOR
      Any value: never style output (--color auto).
```
