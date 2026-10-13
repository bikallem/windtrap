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
when no selected test ran the site. Under `dune runtest`, the mirror
arms it in every suite that holds its file, as in
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

## What a mutation run runs

A mutation run runs in passes, and prints neither the focus warning nor
the withheld-correction warning:

- The dry run is the suite's ordinary run. Under `-u` it accepts
  corrections before any mutant is armed.
- The determinism probe, in a child process, checks that the suite
  passes again.
- Each reached mutant runs in a child with its reaching tests, up to the
  first failure. A child that outruns a deadline taken from the dry run,
  or evaluates its site more than `hits * 8 + 1000` times, `hits` being
  the dry run's count, is killed, and its mutant counts as killed.

A child starts from the state the dry run left. When a child passes
without evaluating its mutant's site, as when the dry run cached the
site's result in a table or a forced lazy value, the mutant is not
evaluated and is no survivor. The report lists it under `not evaluated`
with an `arm:` command, which runs the suite in a new process and ends
on the mutant's verdict.

A site that no test runs, and that module initialization or a
fixture release runs, is evaluated outside tests. No child tests its
mutant, and the report lists its line under `evaluated outside tests`,
apart from the lines never reached.

A test marked `xfail` reaches no mutant. The dry run and the probe run
it, and no child does. A line that only such tests run is never
reached, and an `--arm` run of its mutant ends on `mutant not reached`.

The mutation run exits 0 whatever it finds. It exits 1, with a sentence
on standard error, when a pass fails or no mutant is left to test.

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
  `failwith` or `invalid_arg`.

Two branches or two bodies are the same when they are the same code at
two positions. Code whose value can depend on its position, as
`__LINE__`, `assert` or a match that can fail, is never the same as
other code. A test can read what `print_string`, `Printf.printf` and
`Format.printf` print, so the arguments of these functions keep their
mutants. A literal in the argument of `raise` keeps its mutant too,
because a test can compare the exception.

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
mutants.

## Mutation testing a project

A suite's mutation run covers its own executable. To judge the project,
run every suite with `WINDTRAP_MUTATE=1` and merge the verdict files
with `windtrap mutants`. `WINDTRAP_MUTATE` is the mirror of `--mutate`,
where `1` is the bare flag, `0` its absence, and a value that spells no
boolean the prefixes. A suite with no mutant to test, such as a suite
over another library, runs as usual and says why on standard error. A
mutant killed by one executable is killed. A mutant that no executable
killed and one did not evaluate is not evaluated. The command exits 1
when a mutant survived every executable that reached it, listing the
most reached first, unless a gate on the score is given (see
[Gating on the score](#gating-on-the-score)).

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

## Gating on the score

The outcome line gives the mutation score: the percentage of killed
mutants among the mutants that were killed, survived or were not
evaluated. A mutant that no test reached, that ran outside every test,
or that the rewriter filtered, is not part of the score. When no mutant
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
score, the executables, each mutant with its verdict, and each filtered
mutant with its reason. A survivor also has the tests that ran it. A
test names its executable by its index in `executables`, because two
executables can have the same name. Under `--min-score` the outcome line
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
    "filtered": 0, "score": 77.78 },
  "executables": [
    { "name": "test_calc.exe", "path": "default/test_calc.exe" } ],
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
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] },
        { "executable": 0, "test": ["sign", "is 1 for a positive"] } ] },
    { "id": "calc.ml:10:37:le",
      "file": "calc.ml", "line": 10, "col": 37, "rewrite": "le",
      "before": "n < 0", "after": "n <= 0",
      "verdict": "survived",
      "tests": [
        { "executable": 0, "test": ["sign", "is -1 for a negative"] } ] } ],
  "filtered": [ ] }
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

A suite's `--mutate` run over the whole suite writes one verdict file
under `_build/_mutants`, and its next such run replaces it. An
executable outside any build directory writes under `_windtrap/mutants`
in its working directory. A run under `--mutate=PREFIX` replaces the
verdicts under its prefixes and keeps the others, when the same build
wrote the file. A verdict file records its executable and a digest of
its bytes, and `windtrap mutants` leaves out one whose executable was
deleted or rebuilt since, with a warning, as
[`windtrap coverage`](coverage.md#when-a-dump-is-excluded) does a dump.

## Mutation testing without dune

The mutation backend is applied without dune as
[the coverage backend](coverage.md#instrumenting-without-dune) is, and
the suite then runs with `--mutate`.

## When a run cannot mutate

A mutation run forks a child process for each mutant. It is refused on
Windows, and in a process that has started a domain. `--mutate` and
`--arm` together are a usage error. An interrupt ends the run: the
running child is killed, the mutant under test is named on standard
error, and no verdict file is written.

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
