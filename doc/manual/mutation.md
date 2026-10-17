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
          raises_match (Exn.invalid_arg ~substring:"division by zero")
            (fun () -> Calc.apply Calc.Div 1 0));
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
which tests reach each mutant, then runs each reached mutant in a child
process with those tests alone. A mutant that no test fails on prints
as a `SURVIVED` block: its identifier, the rewrite, the source line and
the tests that ran it. No test calls `sign 0`:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate
calc: 10 passed in 1.3ms.

─────────────────────── survivors ────────────────────────
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      sign › is -1 for a negative  test_calc.ml:32
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 2 survived of 9 reached by this suite, 7 killed, score 77.8%
```

## Reproducing a survivor

The `reproduce:` line arms the first survivor. `--arm ID` runs the
suite once with that mutant active, names it first, records no
correction, and ends on its verdict: killed, survived, or not evaluated
when no selected test ran the site. As in a child of a mutation run, a
failure before the first evaluation of the site does not kill the
mutant (see [What a mutation run runs](#what-a-mutation-run-runs)).
When a test or a fixture release failed and no test ran the site, the
line tells that the mutant did not cause the failure.
When only tests before the first evaluation failed, the survived line
says so. Under `dune runtest`, the mirror arms it in every suite
that holds its file, as in
`WINDTRAP_MUTATE_ARM=ID dune runtest --force --instrument-with ppx_windtrap.mutate`
(see [Mutation testing a project](#mutation-testing-a-project) for
`--force`). Arming a killed mutant shows the failure that killed it:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutant calc.ml:10:16:ge armed: n > 0 → n >= 0
calc: 10 passed in 0.9ms.
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

9 passed, 1 failed in 0.9ms.
mutant killed.
```

## Testing one test's mutants

To judge a new test, narrow the mutation run. `--mutate=PREFIX` tests
only the mutants of the files whose path starts with a prefix, and still
saves its verdicts. The test filters, as `-f`, select the tests as in
any run. A run that they narrow lists the mutants its tests never
reached and saves no verdict. `stays positive` checks a sign that
`a - b → a + b` keeps:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate=calc.ml -f "stays positive"
calc: 1 passed in 0.5ms.

─────────────────────── survivors ────────────────────────
  SURVIVED  calc.ml:6:11:add  a - b → a + b
      6 │ | Sub -> a - b

    1 test ran this line and did not fail:
      subtraction › stays positive  test_calc.ml:11
──────────────────────────────────────────────────────────

─────────────────── never reached (7) ────────────────────
  7  calc.ml   lines 5, 7-8, 10
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:6:11:add -f 'stays positive'
windtrap: verdicts not saved: this run's selection narrows the suite, and a partial run's verdicts would stand in the project merge as the whole.
mutants: 1 survived of 2 reached by the 1 selected test, 1 killed, 7 never reached, score 50.0%
```

## Testing the changed lines

A run over the whole suite tests each mutant again. To test only what a
change touched, give `--mutate-since=REV` with `--mutate`. The run asks
git for the lines that changed in the work tree since the commit `REV`,
and tests only the mutants on these lines. Uncommitted changes count. A
line that a change only removes does not count. Each line of a file that
git does not track counts, but not a file that git ignores, for example
by a `.gitignore` rule. The project root must be in a git work tree.

A mutant is on one line: the line where its expression starts, or for a
`drop` mutant the line where the pattern of its case starts. When an
expression has more than one line, a change to a later line does not
put the mutant of the expression in scope. For example, when `total`
is on one line and `+ tax` is on the next line, a change to the second
line does not put the mutant of `+` in scope. To test such a mutant,
run without `--mutate-since`.

This change adds a comment to line 10 of `calc.ml`, and the run tests
only the two mutants of that line:

```
$ git diff --stat
 calc.ml | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate --mutate-since=HEAD
calc: 10 passed in 0.5ms.

─────────────────────── survivors ────────────────────────
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0 (* -1, 0 or 1 *)

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0 (* -1, 0 or 1 *)

    1 test ran this line and did not fail:
      sign › is -1 for a negative  test_calc.ml:32
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 2 survived of 2 reached by this suite, score 0.0%
```

`windtrap mutants --since REV` reports only the mutants on the lines
that changed since `REV`, and its exit code and `--min-score` look only
at them. Thus a pull request can gate on the mutants of its own lines.

Git compares the work tree with the commit `REV`. When the base branch
changed after the pull request branched from it, the lines of these
changes also count. Thus give the commit where the branch started, which
`git merge-base` finds:

```
$ base=$(git merge-base origin/main HEAD)
$ WINDTRAP_MUTATE=1 WINDTRAP_MUTATE_SINCE=$base dune runtest --force --instrument-with ppx_windtrap.mutate
$ dune exec windtrap -- mutants --since $base
```

Git runs in the root of the project that wrote each verdict file, once
for each root. For a verdict file in a build directory, the root is the
parent of that build directory, also when a `PATH` argument gives the
file. For a verdict file in `_windtrap/mutants`, the root is the parent
of `_windtrap`. Another verdict file has the current directory as its
root. When that root holds no source file of its mutants, the command
stops with exit code 1, because no mutant can be on a changed line.

`WINDTRAP_MUTATE_SINCE` is the mirror of `--mutate-since`. Under
`WINDTRAP_MUTATE`, a suite with no mutant to test on a changed line
runs as usual and says why on standard error. It also writes its
verdict file. That file has no verdict of a child for a changed line,
but it has the [filtered mutants](#filtered-mutants) of these lines.
Thus `windtrap mutants --since` finds a file, and a pull request with
no mutant to test on its lines passes the gate, also after a new build.
Under `--mutate`, the same run stops with exit code 1. Without
`--mutate` and `WINDTRAP_MUTATE`, the revision changes nothing. A run
that arms a mutant (`--arm`) tests only that mutant, and says nothing
about the revision. Any other run says on standard error that it tests
no mutant, and runs as usual. A `REV` that names no commit stops the
run before the dry run, with exit code 1.

Dune does not track `WINDTRAP_MUTATE_SINCE` or the commit that `REV`
names. When only these change, dune does not run a suite again, so the
example above uses `--force` (see
[Mutation testing a project](#mutation-testing-a-project)).

The scope does not narrow the suite, so the run saves its verdicts. But
the file keeps the verdicts of the other lines only when the same build
wrote it. After a change, the build is new, and the merge without
`--since` reports only the changed lines (see
[Where the verdicts are](#where-the-verdicts-are)).

## What a mutation run runs

A mutation run runs in passes, and prints neither the focus warning nor
the withheld-correction warning:

- The dry run is the suite's ordinary run. Under `-u` it accepts
  corrections before any mutant is armed.
- In exec mode, a child process that runs no test measures the startup
  time of the suite.
- The determinism probe, in a child process, checks that the suite
  passes again.
- Under `--mutate-skip-killed`, a reached mutant that the verdict file
  of another suite killed gets no child (see
  [Skipping the mutants that another suite killed](#skipping-the-mutants-that-another-suite-killed)).
- Each other reached mutant runs in a child with its reaching tests. The
  child stops at the first failure in or after the first test that
  evaluates its site. In exec mode, the child can also run the tests
  before them (see below). When the verdict file gives the test that
  killed the mutant before, the source file of the mutant did not
  change, and the test passes alone with no mutant, a first child runs
  that test alone. A second child then runs every reaching test only
  when the first child does not kill the mutant (see
  [Where the verdicts are](#where-the-verdicts-are)). When a full child
  lets the mutant survive, `--mutate-retry` can run it again (see
  [Running a survivor again](#running-a-survivor-again)). A child that
  outruns a deadline taken from the dry run, or evaluates its site more
  than `hits * 8 + 1000` times, `hits` being the dry run's count, is
  killed, and its mutant counts as killed.
- In a process that spawned a domain, each kill that names a test gets
  a check: up to 3 runs of the tests of its child, with no mutant (see
  [Flaky kills](#flaky-kills)).

The deadline of a child is 0.5 seconds, plus the time that the fixtures
took to acquire and to release in the dry run, plus ten times the time
that the tests of the child took in the dry run. The part for the tests
is at least 1 second. A child acquires again each fixture that its tests
use, and releases it at its end. The fixture time of the deadline is for
these acquisitions and releases. Thus with forked children, a mutant
that makes a short test hang in a suite without fixtures is killed after
about 1.5 seconds, also when the suite has slow tests.

In exec mode, the deadline also has ten times the startup time, and the
time that the dry run took for each test up to the last test of the
child. A new process does not have the state that the earlier tests of
the dry run made, for example a forced lazy value or a filled cache. A
test of the child can make this state again, and the dry run counted
this time in an earlier test. Thus in exec mode, a hang in a test that
comes after slow tests is killed later.

The determinism probe has the time of the dry run in place of the 0.5
seconds and the fixture time. When the children use more CPUs than the
host has, the deadlines are longer (see
[Testing mutants in parallel](#testing-mutants-in-parallel)).

A forked child starts from the state the dry run left. When a child passes
without evaluating its mutant's site, as when the dry run cached the
site's result in a table or a forced lazy value, the mutant is not
evaluated and is no survivor. The report lists it under `not evaluated`
with an `arm:` command, which runs the suite in a new process and ends
on the mutant's verdict.

The state that the dry run left is not always the state before a test
of the child. The two states can differ in two directions:

- A later test or a fixture release can remove state that an earlier
  test made, for example when it clears a cache or closes a connection.
  Then a test of the forked child makes this state again.
- A later test can add state that makes a test of the child slower. For
  example, a test that calls `Gc.full_major` or `Gc.compact` walks the
  large heap that the later tests left. A test can also walk a global
  table that the later tests filled.

In the two cases, the deadline has no time for this. Thus the child can
outrun its deadline, and its mutant counts as killed with no test name.
Under `--mutate-children=exec`, each child starts in a new process, and
the deadline has the time of the earlier tests (see above).

Before the first evaluation of its site, a child runs the code of the
unmutated program. Thus a failure before that evaluation does not kill
the mutant, and the child runs the next reaching test. An evaluation in
a process that a test forks also counts. When no process of the child
evaluates the site, the mutant is not evaluated. A failure in such a
child has a cause of its own, for example a schedule of domains, the
clock, or the tests before it. The report names the
failure under the mutant, as
`a failure that the mutant did not cause: calc › memo`. The verdict
file does not keep the failure, so `windtrap mutants` does not show it.
A child that outruns its deadline, or that ends without a verdict line,
gives no count of evaluations, and its mutant counts as killed.

Under `--mutate-children=exec`, or in auto mode (the default) in a
process that started a domain, each child is a new process of the
suite executable. Such a child has no cache from the dry
run. Before the first mutant, each different list of reaching tests runs
one time in a new process with no mutant. When a list fails there, the
child of its mutant runs the tests that the dry run ran up to the last
reaching test, and one of these tests can kill the mutant. In exec mode,
the report tells the mode in one line above the outcome line, for
example `children: new processes, because the suite spawned a domain`.

A site that no test runs, and that module initialization or a
fixture release runs, is evaluated outside tests. No child tests its
mutant, and the report lists its line under `evaluated outside tests`,
apart from the lines never reached.

A test marked `xfail` reaches no mutant. The dry run and the probe run
it, and no child does. A line that only such tests run is never
reached, and an `--arm` run of its mutant ends on `mutant not reached`.

The mutation run exits 0 whatever it finds. It exits 1, with a sentence
on standard error, when a pass fails or no mutant is left to test.

## Stateful tests on several domains

Under mutation testing, a stateful test on several domains spawns no
worker. It runs each program one time on the domain of the test, the
branches one after the other. Thus its kills do not depend on a
schedule, and the suite can fork its children. But a mutant that only
a concurrent order of the calls shows survives, and no test
reaches code that only a concurrent order runs.

`--mutate-workers` (`WINDTRAP_MUTATE_WORKERS=1`) lets such a test
spawn its workers under `--mutate` and `--arm`, as it does without
mutation testing. Each program then runs 50 times, and its branches
run on the workers. Use it for the code of a structure that domains
share. It has these costs:

- The dry run spawns domains, so each child of the run is a new
  process (`--mutate-children`). With `--mutate-children=fork`, the loop
  refuses the run.
- A child that runs such a test can use several CPUs at once. Then it
  counts as several jobs of `--mutate-jobs`
  ([Testing mutants in parallel](#testing-mutants-in-parallel)).
- A child that runs such a test does about 50 times more work.
- A kill can depend on a schedule. A mutant that a run kills can
  survive the next run, and an `--arm` run of the same mutant can pass.
  Each kill that names a test gets the check of
  [Flaky kills](#flaky-kills).

A failure before the first evaluation of the site of a mutant does not
kill the mutant (see [What a mutation run runs](#what-a-mutation-run-runs)).

The `reproduce:`, `arm:` and `replay:` commands of such a run keep
`--mutate-workers`. The `reproduce:` line of `windtrap mutants` does
not keep it, because the verdict file does not record it. Add
`--mutate-workers` to that command yourself.

## Running a survivor again

In a suite that spawns domains, the operating system decides the order
of the domains. A mutant that only some orders show can survive one run
and be killed in the next run.

`--mutate-retry N` (`WINDTRAP_MUTATE_RETRY=N`) runs the child of a
survivor again, up to `N` more times. Each of these runs is a retry.
The first run that does not let the mutant survive gives the verdict.
The mutant survives only when each run lets it survive. `N` is from 0
to 100.

The default is 2 when the process spawned a domain, before or in the
dry run, and 0 if not. The order of the domains is the usual cause of a
verdict that changes from one run to the next. Under
`--mutate-children=exec`, a suite that spawns no domain also gets 0,
because each new process runs its tests in the same order. Give
`--mutate-retry` to a suite whose verdicts change for another cause, for
example threads or the clock.

A retry has the tests and the deadline of the first run, and it uses
a job of `--mutate-jobs` as each child does. Only survivors cost more
time. The live line counts a mutant one time, when it has its verdict.
The determinism probe runs one time.

The report gives the runs of a survivor after its title, when they are
more than 1:

```
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0  (3 runs)
```

The verdict file keeps the runs. `windtrap mutants` adds the runs of the
verdict files in which the mutant survived, and `--json` gives the sum
in `runs`. Thus two suites that each ran a survivor one time give
`(2 runs)`, also when they are suites of one executable. If you name one
verdict file two times with different text, for example `x/a.mutants`
and `./x/a.mutants`, `windtrap mutants` adds its runs two times.

A retry makes a false survivor less probable. It does not make a
verdict deterministic. For example, a mutant that 1 order in 10 kills
survives 3 runs in about 73 of 100 mutation runs. The loop does not run
a killed mutant again with its mutant, so a kill that only some orders
give stays a kill. A kill in a retry gets the check of
[Flaky kills](#flaky-kills). An `--arm` run runs the suite one time.
Thus it can kill a survivor of 3 runs.

A kill in a retry does not give a row in the `unstable` section. The
verdict file keeps only the verdict of the mutant, not the verdict of
each run.

A retry changes how frequently the verdict of a mutant changes between
two mutation runs. For a mutant that most orders kill, a retry makes
this change less probable. For a mutant that few orders kill, a small
`N` makes this change more probable, and a large `N` makes it less
probable. For example, take a mutant that 1 order in 10 kills. With no
retry, its verdict changes in about 18 of 100 pairs of runs. With 2
retries, it changes in about 40 of 100 pairs.

## Flaky kills

In a suite that spawns domains, the operating system decides the order
of the domains. A test can fail with no mutant in some of these orders.
When such a test fails in the child of a mutant, the child kills a
mutant that no test can see.

When the process spawned a domain, before or in the dry run, the run
does a check of each kill that names a test. The check runs the tests
of the child up to and with the killing test, with no mutant, in a new
process. A failure of an earlier test does not stop this run. The check
does this run up to 3 times:

- If the killing test fails in a run, the verdict of the mutant is
  flaky and not killed, and the check stops.
- If the killing test does not fail in the 3 runs, the mutant stays
  killed.

A run that passes its deadline, or that ends with no result, does not
give a failure of the test. The check also applies to a kill in a retry
(see [Running a survivor again](#running-a-survivor-again)) and to a
kill of a first child (see [Where the verdicts are](#where-the-verdicts-are)).
A kill that names no test gets no check, for example a kill at a
deadline, after a crash or after a failed fixture release. A suite that
spawns no domain gets no check, also under `--mutate-children=exec`.
An `--arm` run does no check.

The report lists each flaky mutant in a section `flaky (N)`, with the
killing test and its failure in the run with no mutant:

```
─────────────────────── flaky (1) ────────────────────────
  A test killed each mutant, and then failed in a run with no mutant.
  The score does not count these mutants.
  lib/calc.ml:13:9:sub  a - b → a + b
    test: calc › subtracts on two domains
    failure with no mutant: expected 6, got 5
──────────────────────────────────────────────────────────
```

The failure is the first failure of the test in that run, on one line.
After 80 characters, the run cuts the failure and adds an ellipsis
(`…`). A flaky mutant is reached, but it is not part of the score. The
outcome line counts it as `1 flaky`. When each reached mutant is flaky,
the outcome line gives no score, and the gate of `windtrap mutants`
reads such a merge as 100 (see [Gating on the score](#gating-on-the-score)).
To get a verdict for the mutant, make the test deterministic, and then
run the suite again.

The run does the check one time for each different list of tests, also
when the list killed more than one mutant. Each run of the check is a
new process. It uses the jobs of `--mutate-jobs` that a child of a
mutant with the same tests uses (see [Testing mutants in
parallel](#testing-mutants-in-parallel)). It has the deadline of that
child. Thus each different list of a kill costs up to 3 more children.
The live line shows a run of a check as a child of the mutant that
started the check. It counts each mutant one time, when the mutant has
its verdict. The determinism probe does not change.

Three runs with no failure do not prove that a test is not flaky. For
example, a test that fails in 1 run of 10 passes 3 runs in about 73 of
100 checks, and its mutant then stays killed. A flaky verdict also does
not prove that the mutant is not killed. The mutant can make the test
fail in each run, and the test can also fail with no mutant.

The verdict file keeps the test and the failure of each flaky mutant.
The next run does not run that test alone first, as it does for a
killed mutant (see [Where the verdicts are](#where-the-verdicts-are)).
Under `--mutate-skip-killed`, a flaky mutant in the verdict file of
another suite does not cause a skip. `windtrap mutants` gives a
mutant as flaky when no executable killed it and one executable gave it
as flaky. It names that executable before the test.

## Testing mutants in parallel

A mutation run tests one mutant at a time. `--mutate-jobs N` lets
children run at the same time on up to `N` CPUs, and `--mutate-jobs
auto` uses each CPU. The maximum of `N` is 256. A test that spawns
domains can use more than one CPU. A child uses the most CPUs that one
of its tests used at once in the dry run, rounded to the nearest
integer. A test shorter than 10 ms counts as one CPU. On Linux, the loop
also counts the time that the threads of a test waited for a CPU in the
dry run. But it does not get this time for a domain that a test spawns
and joins. The workers of a stateful test are not such domains. Thus
other load in the dry run can make the count smaller for a test whose
thread sleeps while such domains work. A child that uses more than `N`
CPUs runs alone. The report and the verdict file are the same for each
value of `N`. The run keeps the verdict of a mutant until each mutant
before it in the file has a verdict, and only then prints the mutant if
it survived. This run gives the report of the run with one job in
[Testing a suite's mutants](#testing-a-suites-mutants):

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate --mutate-jobs auto
calc: 10 passed in 0.3ms.

─────────────────────── survivors ────────────────────────
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      sign › is -1 for a negative  test_calc.ml:32
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 2 survived of 9 reached by this suite, 7 killed, score 77.8%
```

Under `dune runtest`, the mirror `WINDTRAP_MUTATE_JOBS` sets the jobs of
each suite, as in
`WINDTRAP_MUTATE=1 WINDTRAP_MUTATE_JOBS=auto dune runtest --force --instrument-with ppx_windtrap.mutate`
(see [Mutation testing a project](#mutation-testing-a-project) for
`--force`).

The default is 1, because the children of one suite run the same
tests. Two children that use the same port or write the same file can
make each other fail. When a child evaluated the site of its mutant
in or before the test that failed, the mutant counts as killed. Use
more than one job only when the tests can run at the same time. When
the children use more CPUs than the host has, the loop multiplies the
deadline of each child by the ratio of the two. For example, 8
children of one CPU each on 4 CPUs double each deadline. The probe runs
alone before these children, and its deadline does not change.

On Linux, the time that a child waits for a CPU does not count toward
its deadline. This time includes the waits of the processes that the
tests of the child start, and of all of their threads. Thus under a
parallel `dune runtest`, the children of the other suites do not push a
child past its deadline. But the loop reads this time only when a child
is past its deadline, and then at least every 0.1 seconds. The wait of
a process that ended before the first read counts, for example of a
short command that a test ran earlier. So does the wait of a process
after its last read. This wait is at most 0.1 seconds for each thread
of the process.

The time that a child waits for the file system counts toward its
deadline. A child writes no last-failed store, but it writes the
captured output of each test to a log file, because a test can read
its captured output. On a busy file system, the creation of a log file
can take more than 0.5 seconds. Then a child can pass its deadline, and
its mutant counts as killed. The loop does not get this time from the
system.

When the children use more CPUs than the host has, they also wait for
each other. Their longer deadlines are for this wait, and the wait does
not move them again. Thus a child that uses the CPU and never stops is
killed when it used the CPU time of its deadline in a run with one job.
The loop kills a child that uses several CPUs when it used that CPU time
on each of its CPUs. Thus the wait of a child on several domains moves
its deadline too.

Other systems do not give the time that a child waits for a CPU.
There, if you set `WINDTRAP_MUTATE_JOBS` for `dune runtest`, also give
dune `-j 1`, so that it runs one suite at a time.

## Dismissing an equivalent mutant

A mutant that no test can tell from the original is equivalent. The
rewriter finds some equivalent mutants itself (see
[Filtered mutants](#filtered-mutants)). `abs`
returns `n` when `n >= 0`, and the mutant `n > 0` differs at zero only,
where both branches return 0. To dismiss it, put `[@mutate off
"reason"]` on the expression, as `calc.ml` does; the site is then
neither tested nor counted. It dismisses every mutant of the
expression, in this version and in any later one that gives the
expression more mutants. After parameters, as in `let f x =
function[@mutate off "reason"] ...`, the attribute on `function`
dismisses every mutant of its cases, and the parameters keep their
mutants. A case is no expression: to dismiss the
`drop` mutant of a case, put the attribute on its pattern, as in
`| (Div [@mutate off "reason"]) -> ...`. The attribute must be on the
whole pattern: in `| A | B [@mutate off "reason"]` it is on `B`. The
rewriter refuses it when the case has a `drop` mutant, and does not
read it when the case has none, as under `-no-arm`. Put an or-pattern
or a tuple in brackets, as `| (A | B) [@mutate off "reason"]`. In
`r := 0 [@mutate off "reason"]` the attribute is on `0`, and
ocamlformat cannot format `(r := 0) [@mutate off "reason"]`. Thus, to
dismiss the `skip` mutant of a statement that applies an operator,
write `begin[@mutate off "reason"] r := 0 end`. `[@@mutate off]`
dismisses a binding, `[@@@mutate off]` and `[@@@mutate on]` the
structure items between them, and `[@@@mutate exclude_file]` a file.
Only `off` takes a reason, which no report prints.

## Filtered mutants

The rewriter filters a mutant when the syntax shows that the mutant is
equivalent to the original, or that it changes only a log or a failure
message. It records the site as filtered, with a reason, and no child
tests the mutant. The score does not include it. The reports give a
`filtered` section with the number of mutants for each reason, and the
outcome line gives their total, as `3 filtered`. The reasons are these:

- `zero operand`: `x + 0` and `x - 0` are equal on integers, so their
  `sub` and `add` mutants are filtered. On floats, `-0. +. 0.` is `0.`
  and `-0. -. 0.` is `-0.`, so `x +. 0.` keeps its mutant.
- `same operands`: `a && a` and `a || a` are `a` when `a` is a name,
  `true`, `false` or a field, which only gives a value.
- `same branches`: in `if c then e else e`, the `not` or comparison
  mutant of `c` changes nothing. The sites inside `c` and `e` keep their
  mutants.
- `same body as the next case`: in `| A -> 0 | _ -> 0`, the `drop`
  mutant of `A` sends `A` to `_`, which gives the same value. The case
  has no guard, binds no variable and has no `lazy` pattern, which
  forces a value. The next case is `_` without a guard.
- `logging call`: each site in the arguments of `Logs.app`,
  `Logs.err`, `Logs.warn`, `Logs.info`, `Logs.debug` and `Logs.msg`.
  The call itself keeps its `skip` mutant. A statement in the
  arguments, as `incr n;` in the message function, changes the state of
  the program, so it keeps its mutants. The rewriter does not see other
  effects, as those of a function that the message calls.
- `failure message`: under `-lit`, a literal in the arguments of
  `failwith` or `invalid_arg`. A statement in the arguments keeps its
  mutants, as in a logging call.

Two branches or two bodies are the same when they are the same code at
two positions. Code whose value can depend on its position is never the
same as other code: code that holds `__LINE__`, `assert`, a pattern that
can fail, a `match` or a `function`. The rewriter does not see the
types, so it does not know which `match` can fail, and it treats each
one as a `match` that can fail. A test can read what `print_string`,
`Printf.printf` and `Format.printf` print, so the arguments of these
functions keep their mutants. A literal in the argument of `raise`
keeps its mutant too, because a test can compare the exception.

A project that logs through its own functions, or through
`Printf.eprintf` or `prerr_endline`, gives their names with
`-log-function` after the backend, one flag for each name, spelled as
the source spells it:

```lisp
(instrumentation
 (backend ppx_windtrap.mutate -log-function Log.debug -log-function Log.info))
```

`-no-filter` after the backend switches every filter off, and the run
then tests each mutant:

```lisp
(instrumentation
 (backend ppx_windtrap.mutate -no-filter))
```

`[@mutate off "reason"]` on a filtered site dismisses it, and the site
is then neither tested nor counted.

When each mutant that a run can test is dismissed or filtered, there
is nothing to test. `--mutate` then refuses the run and exits 1, and
`WINDTRAP_MUTATE` runs the suite without mutation. The two write no
verdict file, so `windtrap mutants` does not count these filtered
mutants. Under `WINDTRAP_MUTATE_SINCE`, `WINDTRAP_MUTATE` writes the
verdict file with the filtered mutants of the changed lines (see
[Testing the changed lines](#testing-the-changed-lines)).

## Mutation testing a project

A suite's mutation run covers its own executable. To judge the project,
run every suite with `WINDTRAP_MUTATE=1` and merge the verdict files
with `windtrap mutants`. `WINDTRAP_MUTATE` is the mirror of `--mutate`,
where `1` is the bare flag, `0` its absence, and a value that spells no
boolean the prefixes. A suite with no mutant to test, such as a suite
over another library, runs as usual and says why on standard error. A
mutant killed by one executable is killed. A mutant that no executable
killed, and that one executable gave as flaky, is flaky. A mutant that
no executable killed or gave as flaky, and that one executable did not
evaluate, is not evaluated. The command exits 1 when a mutant survived
every executable that reached it, listing the most reached first, unless
a gate on the score is given (see [Gating on the
score](#gating-on-the-score)).

Dune does not track `WINDTRAP_MUTATE`. A suite that ran without it
does not run again when it is set, unless its build changed, and the
merge then finds no verdict of that build.
`(deps (env_var WINDTRAP_MUTATE))` on a test stanza makes dune run it
again when the variable changes. Without it, `--force` makes dune run
every suite:

```
$ WINDTRAP_MUTATE=1 dune runtest --force --instrument-with ppx_windtrap.mutate
calc: 10 passed in 1.0ms.

─────────────────────── survivors ────────────────────────
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      sign › is -1 for a negative  test_calc.ml:32
      sign › is 1 for a positive   test_calc.ml:31

  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      sign › is -1 for a negative  test_calc.ml:32
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 2 survived of 9 reached by this suite, 7 killed, score 77.8%
$ dune exec windtrap -- mutants
───────────────────── survivors (2) ──────────────────────
  SURVIVED  calc.ml:10:16:ge  n > 0 → n >= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    2 tests ran this line and none failed:
      test_calc.exe  sign › is -1 for a negative
      test_calc.exe  sign › is 1 for a positive

  SURVIVED  calc.ml:10:37:le  n < 0 → n <= 0
      10 │ let sign n = if n > 0 then 1 else if n < 0 then -1 else 0

    1 test ran this line and did not fail:
      test_calc.exe  sign › is -1 for a negative
──────────────────────────────────────────────────────────

reproduce: dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --arm calc.ml:10:16:ge
mutants: 2 survived of 9 reached, 7 killed, 1 executable, score 77.8%
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

`windtrap mutants` counts a mutant as killed when one executable kills
it. Thus when several suites reach a mutant, a kill in one suite is
sufficient. The other suites do work that cannot change the report.
`--mutate-skip-killed` (mirror `WINDTRAP_MUTATE_SKIP_KILLED`) skips such
a mutant.

After the dry run, the run reads the other verdict files in its verdict
directory: the files of the other executables, and the files of the
other suites of its own executable. It does not read the file of its own
suite. A reached mutant gets no child when one of these files gives it
`killed`. This applies only when the digest of the source file in that
record is the digest of the source file at this time. Only a kill that a
child gave counts. A mutant that another run skipped does not cause a
skip. A flaky mutant also does not cause a skip. Only the mutants in the
scope are candidates, so `--mutate=PREFIX` and `--mutate-since` keep
their behavior. The run does not use a file that does not load, a file
that names no executable, a file whose executable no longer exists, or
a file whose executable is not a regular file (for example a FIFO). It
names each such file on standard error. The run also does not use a
file that `windtrap mutants` leaves out because another build of its
executable wrote it (see [Where the verdicts
are](#where-the-verdicts-are)). This applies to the files of each
executable. The run gives no warning for such a file, because each build
makes the files of the suites that did not run again stale. `windtrap
mutants` names each such file.

The verdict file of the run records a skipped mutant as killed
elsewhere, with the name of the executable of that file. When another
suite of the same executable killed the mutant, this name is the
executable of the run. A line of the report names the executable of each
verdict file that the run used, one time for each executable. For each
file, the line gives the number of mutants that the run skipped because
of that file. The outcome line counts these mutants as not tested, and
the score of the suite does not count them:

```
killed elsewhere: 1 mutant, not tested, from the verdict file of default/test/pins_add.exe (1)
mutants: 1 survived of 3 reached by this suite, 1 killed, 1 never reached, 1 not tested, score 50.0%
```

`windtrap mutants` counts a mutant that was killed elsewhere as killed,
so the merge gives the same survivors and the same score as without the
option. After the first run with the option, the report and
`windtrap mutants` can list the skipped mutants as `survived → killed`
(see [Unstable verdicts](#unstable-verdicts)). When no verdict file of
the merge has the kill, the command gives a note on standard error. The
note tells which run to do again:

- The verdict file of the killer is in the merge, but it does not kill
  the mutant. For example, its tests changed, or it skipped the mutant
  too. Run the suite that skipped the mutant again:

  ```
  windtrap: 2 mutants count as killed by default/test/a.exe, but no verdict file of default/test/a.exe in the merge kills them: run default/test/b.exe again with its mutants, then merge again
  ```

- The killer no longer exists. Run the suite that skipped the mutant
  again:

  ```
  windtrap: 1 mutant counts as killed by default/test/gone.exe, but default/test/gone.exe no longer exists: run default/test/b.exe, default/test/c.exe again with their mutants, then merge again
  ```

- The verdict file of the killer is not in the merge, because it is
  stale or because you deleted it. Run the killer again:

  ```
  windtrap: 1 mutant counts as killed by default/test/pins_add.exe, but no verdict file of the merge gives this kill: run default/test/pins_add.exe with its mutants, then merge again
  ```

When another suite of the same executable gave the kill, the note has
the first form, because the file of the suite that skipped the mutant is
in the merge. Run that executable again. It runs each of its suites.

The recommended run can skip the mutant again because of another verdict
file on disk. For example, the executable of that file is built again
after the run, so the merge leaves out the file. The next merge then
gives a note that names that other executable. Do what the new note
tells.

The option uses only the files on disk at the end of the dry run. A
parallel `dune runtest` runs the suites at the same time, so the file of
a fast suite can be missing or from an earlier run. Run the fast suites
first, then the slow suites with the option.

Do not run two suites with the option at the same time when they reach
the same mutants. Each suite then reads the file that the other suite
wrote in an earlier run. As a result, the two suites can skip one mutant
because of each other. No file then kills the mutant, the merge gives a
note, and the next parallel run tests the mutant again. Run such suites
one after the other, for example with `dune runtest -j 1`. In that
order, the later suite reads the new file of the earlier suite, so the
two suites cannot skip one mutant because of each other. The test files
of one inline-test library are suites of one executable, and dune runs
them at the same time:

```
$ WINDTRAP_MUTATE=1 dune runtest --force --instrument-with ppx_windtrap.mutate test/core test/sim
$ WINDTRAP_MUTATE=1 WINDTRAP_MUTATE_SKIP_KILLED=1 dune runtest -j 1 --force --instrument-with ppx_windtrap.mutate test/linux
$ dune exec windtrap -- mutants
```

The run uses only the verdict files that `windtrap mutants` keeps at
that time. Thus the merge usually has each kill that the run used. The
merge can lose a kill in two cases. The executable of its file is built
again after the run, or the other suite runs again and does not kill the
mutant. In these cases, the merge counts the mutant as killed and gives
a note. A file of an earlier windtrap version does not load, so the run
does not use it.

## Gating on the score

The outcome line gives the mutation score: the percentage of killed
mutants among the mutants that were killed, survived or were not
evaluated. A mutant that no test reached, that ran outside every test,
that the rewriter filtered, or that is flaky (see
[Flaky kills](#flaky-kills)), is not part of the score. When no mutant
is part of it and no gate is given, the line gives no score.

A project can keep a survivor that it does not plan to kill. To gate on
the score and not on each survivor, give `--min-score PCT` to
`windtrap mutants`. The command then exits 1 only when the score is less
than `PCT`, and the outcome line gives the gate and its result. The
gate compares the score before it is rounded, and reads a merge with no
scored mutant as 100:

```
$ dune exec windtrap -- mutants --min-score 50 | tail -n 1
mutants: 2 survived of 9 reached, 7 killed, 1 executable, score 77.8%, minimum 50%: ok
```

A suite's mutation run gives the score too, and has no gate.

## Exporting the verdicts

For other tools, `--json` prints the merge as JSON on standard output,
in place of the report. The document has its version, the counts and the
score, the executables, each with the suite of its verdict file, each
mutant with its verdict, each filtered mutant with its reason, each
flaky mutant with its test and the failure of that test with no mutant,
and the mutants whose verdict changed. A survivor also has the number of
its runs and the tests that ran it. The count `reached` of the document
does not count the flaky mutants, so it is the count of the mutants of
the score. A test names its executable by its index in `executables`,
because two executables can have the same name, and one executable has
an object for each of its suites. Under `--min-score` the outcome line
goes to standard error, and the exit code is that of the gate. Standard
output can refuse the document, for example on a full disk. The command
then gives the reason on standard error and exits 1. The gate does not
run. A later version can add keys. A change to the meaning of a key
increments `version`. [`bin/mutate_cmd.mli`](../../bin/mutate_cmd.mli)
gives each key:

```
$ dune exec windtrap -- mutants --json
{ "version": 1,
  "summary": { "reached": 9, "killed": 7, "survived": 2,
    "not_evaluated": 0, "outside_tests": 0, "unreached": 0,
    "filtered": 0, "flaky": 0, "score": 77.78 },
  "executables": [
    { "name": "test_calc.exe", "path": "default/test_calc.exe", "suite": "calc" } ],
  "mutants": [
    { "id": "calc.ml:5:4:drop",
      "file": "calc.ml", "line": 5, "col": 4, "rewrite": "drop",
      "before": "| Add -> ...", "after": "| Add when false -> ...",
      "verdict": "killed" },
    { "id": "calc.ml:5:11:sub",
      "file": "calc.ml", "line": 5, "col": 11, "rewrite": "sub",
      "before": "a + b", "after": "a - b",
      "verdict": "killed" },
    { "id": "calc.ml:6:4:drop",
      "file": "calc.ml", "line": 6, "col": 4, "rewrite": "drop",
      "before": "| Sub -> ...", "after": "| Sub when false -> ...",
      "verdict": "killed" },
    { "id": "calc.ml:6:11:add",
      "file": "calc.ml", "line": 6, "col": 11, "rewrite": "add",
      "before": "a - b", "after": "a + b",
      "verdict": "killed" },
    { "id": "calc.ml:7:4:drop",
      "file": "calc.ml", "line": 7, "col": 4, "rewrite": "drop",
      "before": "| Mul -> ...", "after": "| Mul when false -> ...",
      "verdict": "killed" },
    { "id": "calc.ml:8:4:drop",
      "file": "calc.ml", "line": 8, "col": 4, "rewrite": "drop",
      "before": "| Div -> ...", "after": "| Div when false -> ...",
      "verdict": "killed" },
    { "id": "calc.ml:8:14:neq",
      "file": "calc.ml", "line": 8, "col": 14, "rewrite": "neq",
      "before": "b = 0", "after": "b <> 0",
      "verdict": "killed" },
    { "id": "calc.ml:10:16:ge",
      "file": "calc.ml", "line": 10, "col": 16, "rewrite": "ge",
      "before": "n > 0", "after": "n >= 0",
      "verdict": "survived",
      "runs": 1,
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] },
        { "executable": 0, "test": ["sign", "is 1 for a positive"] } ] },
    { "id": "calc.ml:10:37:le",
      "file": "calc.ml", "line": 10, "col": 37, "rewrite": "le",
      "before": "n < 0", "after": "n <= 0",
      "verdict": "survived",
      "runs": 1,
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] } ] } ],
  "filtered": [ ],
  "flaky": [ ],
  "unstable": [ ] }
```

## Killing a survivor

A survivor names a behaviour no test checks. To kill the two survivors
of [Testing a suite's mutants](#testing-a-suites-mutants), add a test at
zero to the `sign` group:

`test_calc.ml`:

```ocaml
let sign =
  group "sign"
    [
      test "is 1 for a positive" (fun () -> equal int 1 (Calc.sign 5));
      test "is -1 for a negative" (fun () -> equal int (-1) (Calc.sign (-5)));
      test "is 0 for zero" (fun () -> equal int 0 (Calc.sign 0));
    ]
```

The mutation run then kills every mutant the suite reaches, and the
project's merge passes:

```
$ dune exec --instrument-with ppx_windtrap.mutate ./test_calc.exe -- --mutate
calc: 11 passed in 2.9ms.
mutants: 9 reached by this suite, 9 killed, score 100.0%
$ dune exec windtrap -- mutants
mutants: 9 reached, 9 killed, 1 executable, score 100.0%
```

## What is mutated

Each mutant rewrites one expression or one case of a match, and the
last part of its identifier names the rewrite:

- `not` negates a condition that is neither a comparison nor a
  connective: the condition of an `if` or a `while`, or a guard.
- A comparison in a condition moves by one boundary: `<` becomes `<=`
  (`le`), `<=` becomes `<` (`lt`), `>` becomes `>=` (`ge`), `>=` becomes
  `>` (`gt`), `=` becomes `<>` (`neq`) and `<>` becomes `=` (`eq`).
- `&&` becomes `||` (`or`), and `||` becomes `&&` (`and`).
- `+` becomes `-` (`sub`) and `-` becomes `+` (`add`); `+.` and `-.`
  swap likewise (`fsub`, `fadd`).
- `drop` removes one case of a `match`, a `function` or a `try`. A
  value then goes on to the next case that matches it, or the match
  raises `Match_failure`. An exception goes on to the next handler. The
  identifier gives the position of the pattern of the case.
- `skip` removes a call whose value the code discards: `e1` in
  `e1; e2`, and `e` in `let () = e in body`, when it is an application.
- `none` replaces `Some e` with `None`, and `tail` replaces `h :: t`
  with `t`. The mutant does not evaluate `e` or `h`. A list literal
  such as `[a; b; c]` is one site, at its bracket, and becomes `[b; c]`.
  A chain such as `a :: b :: t` is also one site, and becomes `b :: t`.

Under the backend flag `-lit`, literals are mutated too:

- `inc` adds one to an integer literal, and `one` makes `0` a `1`.
- `zero` makes a float literal other than zero `0.`, and `one` makes
  `0.` a `1.`.
- `flip` swaps `true` and `false`. A `true` or `false` that is a
  condition has the `not` mutant and no `flip`.

Strings and characters are not mutated.

A comparison outside a condition, as in `let ok = a < b`, carries no
mutant, and neither does an `assert`. In a chain of one operator, as
`a + b + c`, the outermost application alone is a site. Inline tests
(`let%test`, `let%expect_test` and `module%test` with its helpers)
carry no mutant, and the rest of their file is mutated. A file that
rebinds an operator loses the rewrites of its family: the four
arithmetic operators, the six comparisons or the two connectives. A
file that declares a constructor `true` or `false` has no `drop`
mutant, and a file that declares a constructor `()` has no `skip`
mutant. A file that declares a constructor `Some`, `None` or `(::)` has
no `none` or `tail` mutant, and a file that declares `true` or `false`
has no `flip` mutant. This applies to a constructor of a type and to an
extension constructor.

The rewriter does not see a constructor that comes from another module.
When `Some e` builds a value of such a type, and the type has no `None`,
the instrumented build fails to compile. This is also the case when
`h :: t` builds a value of such a type, and `t` has another type. Put
`[@mutate off "reason"]` on the expression.

The right-hand side of a `let rec`, as in `let rec ones = 1 :: ones`,
has no `none` or `tail` mutant outside its functions and its `lazy`
bodies, because OCaml does not let such a value be an `if`.

A case is not dropped when it is the only case of its match that a
value reaches, because every value then raises. A match with a
refutation case, as `| _ -> .`, a case that matches a value and an
exception, as `| None | exception Not_found`, and an effect case, as
`| effect Ask, k`, have no `drop` mutant.

A `let () = e` at the top level of a module runs when the module
initializes, and has no `skip` mutant.

To switch the `drop`, the `skip` or the `none` and `tail` mutants off
for a library, give `-no-arm`, `-no-call` or `-no-ret` after the
backend. A library has many literals, and each one gives a mutant, so
the mutants of literals are off until `-lit` switches them on:

```lisp
(instrumentation
 (backend ppx_windtrap.mutate -no-arm -no-call -no-ret -lit))
```

A long list literal can make the instrumented build slow. When its
elements are not constants, the time of `ocamlopt` increases as the
square of their number. A mutant in each element makes the elements
not constants, as `none` does in a generated table
`[ (0, Some "a"); (1, Some "b"); ... ]` of thousands of elements. Put
`[@@mutate off]` on the binding of such a table.

## Where the verdicts are

A suite's `--mutate` run over the whole suite writes the verdict file
of that suite under `_build/_mutants`, and the next such run of the
suite replaces it. The name of the file is
`windtrap-<exe>-<suite>.mutants`. `<exe>` is the hexadecimal MD5 of the
path of the executable in the build directory, for example
`default/test/calc.exe`. `<suite>` is the hexadecimal MD5 of the suite
name. Thus each suite name of a main has its own file, and the
inline-test runner of a library writes one file for each test file. Two
calls of `Windtrap.run` with one suite name share one file: the later
call replaces the verdicts of the earlier call, and compares its
verdicts with them. An executable outside any build directory writes
under `_windtrap/mutants` in its working directory. A run under
`--mutate=PREFIX` or `--mutate-since=REV` replaces the verdicts in its
scope and keeps the others, when the same build of the same suite wrote
the file. A verdict file records its executable, a digest of its bytes
and its suite, and `windtrap mutants` leaves out one whose executable
was deleted or rebuilt since, with a warning, as
[`windtrap coverage`](coverage.md#when-a-dump-is-excluded) does a dump.

A run does not delete the file of another suite. When a suite no longer
runs, for example after you rename a test file of an inline-test
library, its file stays. While the executable is the same build,
`windtrap mutants` merges the file, and its verdicts are those of the
tests of that build. After the next build, `windtrap mutants` leaves the
file out with a warning that names it, and `--mutate-skip-killed` does
not use it. Delete that file, or delete `_build/_mutants` and run each
suite again. A verdict file of an earlier windtrap version has another
name, which no run replaces. `windtrap mutants` refuses it, so delete
it.

The verdict file also keeps the test that killed each mutant, a digest
of the source file of the mutant, the previous verdict of each mutant
(see [Unstable verdicts](#unstable-verdicts)), and the test and the
failure of each flaky mutant. The next run of the suite reads them, also
after a new build. When the digest did not change and the test still
reaches the mutant, the run first runs the test alone, with no mutant.
If the test passes, a child then runs the test alone with the mutant. If
the test kills the mutant again, no other test runs. If it does not, a
second child runs each reaching test, as without the file. Thus the file
never gives a verdict without a test that fails, and a changed or
renamed test cannot keep an old verdict. The file only lets a killed
mutant run fewer tests. A flaky mutant gets no first child. Under
`--mutate-skip-killed`, the verdict files of the other suites also
decide which mutants get a child (see [Skipping the mutants that another
suite killed](#skipping-the-mutants-that-another-suite-killed)).

A test that runs alone does not run after the tests before it. When a
test passes alone, fails alone with the mutant, but passes with the
mutant after an earlier test, the verdict file can make a survivor a
killed mutant. To get the verdicts without the file, delete the verdict
file of the suite, or `_build/_mutants`, before the run.

## Unstable verdicts

A run that writes its verdict file compares the verdict of each mutant
with the verdict in the file that it replaces. The comparison applies
only when the source file of the mutant has the same digest in the two
files. The file of an earlier build also counts, because almost each
change of a test rebuilds the executable. Each suite has its own verdict
file, so the comparison uses the file of the same suite.

The report lists, in a section `unstable (N)`, each mutant whose verdict
changed between killed, survived and not evaluated:

```
────────────────────── unstable (1) ──────────────────────
  The source of each mutant did not change, but its verdict did.
  lib/calc.ml:13:9:sub   survived → killed
──────────────────────────────────────────────────────────
```

The list does not show these changes:

- A killed mutant with another killing test.
- A survivor with other reaching tests or another number of runs.
- A change between killed and killed elsewhere. A mutant killed
  elsewhere counts as killed.
- A change from or to never reached, evaluated outside tests, filtered
  or flaky. The `flaky` section lists a flaky mutant in each run that
  gives it.

The comparison examines only the source file of the mutant. Thus a
change of other code, for example a caller, a callee or a dependency,
can give a correct row while the tests stay the same. When the tests and
the other code did not change, a row is a sign of a verdict that depends
on the order of the domains, for example in a stateful test on several
domains (see
[Stateful tests on several domains](#stateful-tests-on-several-domains)).
`--mutate-retry` can make such a row more or less probable (see
[Running a survivor again](#running-a-survivor-again)).
A deadline of a child on a host under load can also change a verdict. A
change of `--mutate-children` between `fork` and `exec` can also change
a verdict between killed and not evaluated. A forked child keeps the
cache of the dry run, and a new process does not (see
[What a mutation run runs](#what-a-mutation-run-runs)). When the tests
changed, a row can show a correct change. The commit tells which.

The section does not change the score, the outcome line or the exit
code. A run that writes no verdict file shows no section: a narrowed
run, a run that a signal stopped before its last verdict, and a run
whose file cannot be written.

`windtrap mutants` gives the same list from the verdict files, with the
executable of each row. When two suites of one executable give one
mutant the same change, the report shows one row, and `--json` gives one
object for each suite. `--json` gives the list in `unstable`:

```
  "unstable": [
    { "id": "lib/calc.ml:13:9:sub", "executable": 0, "previous": "survived", "verdict": "killed" } ] }
```

The verdict file keeps only the verdict of the run before. Thus a
verdict that changes on each run shows a row on each run. A project that
wants to keep the list, for example as known survivors, copies the rows
of `--json`.

Under `--mutate-skip-killed`, the first run with the option can list a
mutant that this suite let survive and another suite killed, as
`survived → killed`. A run without the option after it can list the
mutant as `killed → survived`. `windtrap mutants` lists the same row
from the file.

To start the comparison again, delete the verdict file of the suite, or
`_build/_mutants`.

## Mutation testing without dune

The mutation backend is applied without dune as
[the coverage backend](coverage.md#instrumenting-without-dune) is, and
the suite then runs with `--mutate`.

## When a run cannot mutate

A mutation run starts a child process for each mutant. It is refused on
Windows. OCaml refuses `fork` in a process that has started a domain, so
in such a process each child is a new process of the suite executable
(`--mutate-children`). With `--mutate-children=fork`, the run is refused
in that process. Under `--mutate-since`, it is refused when git cannot
give the changed lines, for example when `REV` names no commit.
`--mutate` and `--arm` together are a usage error. `--arm` refuses a
mutant that `[@mutate off]` dismisses or that the rewriter filtered, and
exits 1: its site has no guard, so no run can arm it. An interrupt ends
the run: the running children are killed, the mutants under test are
named on standard error, and no verdict file is written. When no child
runs at the interrupt and mutants remain, standard error names the first
mutant with no verdict. A kill that waits for its [check](#flaky-kills)
gets no verdict. A survivor that waits for a retry gets no verdict too.
This holds also when its child exited before the interrupt. An interrupt
after the last child exits stops nothing: the run writes the verdict
file and the report as usual, and then dies by the signal.

A new process costs more than a fork, because it starts the executable
and does its module initialization again. The run also has more
children in exec mode: one child measures the startup time, and one
child runs each different list of reaching tests with no mutant. In a
process that spawned a domain, each different list of tests of a kill
also costs up to 3 children (see [Flaky kills](#flaky-kills)). This
table shows an example. It gives the mean wall times of 20 runs in a
shell loop, on Linux with 16 CPUs. The suite is `suite_main.exe`, the
test suite of the mutation loop, with 2 reached mutants:

| Mode | Children | Mean wall time |
|---|---|---|
| `--mutate-children=fork` | 3 | 11.6 ms |
| `--mutate-children=exec` | 6 | 25.4 ms |

In the same loop, a new process of that suite that lists its tests
(`-l`) takes 2.1 ms, and `/bin/true` takes 0.3 ms. A suite whose tests
run for milliseconds or more pays a smaller part of its time for the
new processes.

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
not evaluated. Runs no tests and drives no build. Exits 1 when any mutant
survived every executable that reached it, or under --min-score only when the
score is below PCT.

OPTIONS:
  --min-score=PCT
      Exit 1 when the score is below PCT, and not for a survivor alone.

  --since=REV
      Report only the mutants on lines changed since git revision REV.

  --json
      Machine-readable report on standard output.

  --color=MODE (env WINDTRAP_COLOR)
      Color output: always, never or auto.

  -h, --help
      Print this help and exit.

ENVIRONMENT (no flag):
  NO_COLOR
      Any value: never style output (--color auto).
```
