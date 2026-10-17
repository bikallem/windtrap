`windtrap mutants` merges the verdict files of a project's executables and
reports its survivors. Its discovery and its exclusion of files from other
builds are data.t's; this session pins the merge and its report. A path
the command builds is absolute and spelled by the platform, so a verdict
file is shown by its name. The projects lie in a scratch directory outside
the build directory, whose own verdict files the command would otherwise
find.

  $ bin=$PWD
  $ mkdata() { "$bin/mkdata.exe" "$@"; }
  $ run() {
  >   env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" WINDTRAP_COLOR=never "$@" > "$bin/out" 2> "$bin/err"
  >   code=$?; cat "$bin/out"
  >   if [ -s "$bin/err" ]; then
  >     echo '--- stderr'
  >     sed -E 's#[^ ()]*[/\\]([^/\\ ()]+\.mutants)#.../\1#g' "$bin/err"
  >   fi
  >   return $code
  > }
  $ scratch=$(cd "$(mktemp -d)" && pwd -P)

Every project holds the same two sources and draws its mutants from five,
each written as a verdict file records it:

  $ plant() {
  >   mkdir -p "$1/lib"
  >   printf 'let add a b = a + b\nlet sub a b = a - b\nlet cmp a b = a < b\n' > "$1/lib/calc.ml"
  >   printf 'let ok p q = p || q\nlet neither p q = not (p || q)\nlet both p q = p && q\n' > "$1/lib/util.ml"
  > }
  $ add='lib/calc.ml:1:14:add:a + b:a - b'
  $ sub='lib/calc.ml:2:14:sub:a - b:a + b'
  $ lt='lib/calc.ml:3:14:lt:a < b:a <= b'
  $ or='lib/util.ml:1:13:or:p || q:p && q'
  $ and='lib/util.ml:3:22:and:p && q:p || q'

The merge

Three executables over one library. A kills add, which B only reaches;
sub survives in B and in C, with different reaching tests; lt survives in
A, and a crash in B kills it; no test reaches or and and. A names the test
that killed add, and the crash names none:

  $ plant "$scratch/three" && cd "$scratch/three"
  $ mkdata mutants _build/_mutants/windtrap-a.mutants "$add=killed:calc/adds" \
  >   "$sub=unreached" "$lt=survived:calc/compares" "$or=unreached" "$and=unreached"
  $ mkdata mutants _build/_mutants/windtrap-b.mutants "$add=survived:cli/runs" \
  >   "$sub=survived:cli/subtracts" "$lt=killed" "$or=unreached" "$and=unreached"
  $ mkdata mutants _build/_mutants/windtrap-c.mutants "$add=unreached" \
  >   "$sub=survived:prop/sub law" "$lt=unreached" "$or=unreached" "$and=unreached"

A mutant killed anywhere is killed, and the report does not name the test
that killed it. The one survivor is drawn from its record, its reaching
tests are those of every executable that reached it, each named by its
file, and the mutants no test reached are counted by file:

  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:2:14:sub  a - b → a + b  (2 runs)
        2 │ let sub a b = a - b
  
      2 tests in 2 executables ran this line and none failed:
        windtrap-b.mutants  cli › subtracts
        windtrap-c.mutants  prop › sub law
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (2) ────────────────────
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:2:14:sub dune runtest --force --instrument-with ppx_windtrap.mutate
  mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%
  [1]
  $ cp "$bin/out" merged

The order of the files on the command line is not part of the answer:

  $ run windtrap mutants _build/_mutants/windtrap-c.mutants \
  >   _build/_mutants/windtrap-a.mutants _build/_mutants/windtrap-b.mutants > /dev/null
  [1]
  $ diff merged "$bin/out"

Sources are found under the root of the project from a directory below it
too:

  $ cd lib && run windtrap mutants > /dev/null; grep '│' "$bin/out"; cd ..
        2 │ let sub a b = a - b

WINDTRAP_COLOR=always colours SURVIVED red, a never-reached count yellow and
the counts as a suite's summary does; the command to reproduce stays plain:

  $ esc() { sed "s/$(printf '\033')/\\\\e/g"; }
  $ run WINDTRAP_COLOR=always windtrap mutants > coloured
  [1]
  $ esc < coloured
  \e[2m───────────────────── survivors (1) ──────────────────────\e[0m
    \e[31mSURVIVED\e[0m  \e[1mlib/calc.ml:2:14:sub\e[0m  a - b → a + b  (2 runs)
        \e[2m2 │\e[0m let sub a b = a - b
  
      2 tests in 2 executables ran this line and none failed:
        windtrap-b.mutants  cli › subtracts
        windtrap-c.mutants  prop › sub law
  \e[2m──────────────────────────────────────────────────────────\e[0m
  
  \e[2m─────────────────── never reached (2) ────────────────────\e[0m
    \e[33m2\e[0m  lib/util.ml   lines 1, 3
  \e[2m──────────────────────────────────────────────────────────\e[0m
  
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:2:14:sub dune runtest --force --instrument-with ppx_windtrap.mutate
  mutants: \e[31m1 survived\e[0m of 3 reached, \e[32m2 killed\e[0m, \e[33m2 never reached\e[0m, 3 executables, score 66.7%

B's file alone reports the survivor A kills. Survivors that as many tests
reached are in identifier order:

  $ run windtrap mutants _build/_mutants/windtrap-b.mutants
  ───────────────────── survivors (2) ──────────────────────
    SURVIVED  lib/calc.ml:1:14:add  a + b → a - b
        1 │ let add a b = a + b
  
      1 test ran this line and did not fail:
        windtrap-b.mutants  cli › runs
  
    SURVIVED  lib/calc.ml:2:14:sub  a - b → a + b
        2 │ let sub a b = a - b
  
      1 test ran this line and did not fail:
        windtrap-b.mutants  cli › subtracts
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (2) ────────────────────
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:1:14:add dune runtest --force --instrument-with ppx_windtrap.mutate
  mutants: 2 survived of 3 reached, 1 killed, 2 never reached, 1 executable, score 33.3%
  [1]

A project with nothing to report is one line, and exits 0:

  $ plant "$scratch/clean" && cd "$scratch/clean"
  $ mkdata mutants _build/_mutants/all.mutants "$add=killed" "$sub=killed" "$lt=killed"
  $ run windtrap mutants
  mutants: 3 reached, 3 killed, 1 executable, score 100.0%

A mutant that no test reached is listed and not scored, so it leaves the
exit code 0, and there is no command to reproduce:

  $ plant "$scratch/unreached" && cd "$scratch/unreached"
  $ mkdata mutants _build/_mutants/all.mutants "$add=killed" "$sub=killed" "$or=unreached"
  $ run windtrap mutants
  ─────────────────── never reached (1) ────────────────────
    1  lib/util.ml   line 1
  ──────────────────────────────────────────────────────────
  
  mutants: 2 reached, 2 killed, 1 never reached, 1 executable, score 100.0%

A site that ran outside every test in one executable is not never reached,
and a test's verdict in another executable outranks it:

  $ plant "$scratch/outside" && cd "$scratch/outside"
  $ mkdata mutants _build/_mutants/a.mutants "$sub=outside_tests" "$or=outside_tests" "$and=unreached"
  $ mkdata mutants _build/_mutants/b.mutants "$sub=killed" "$or=unreached" "$and=unreached"
  $ run windtrap mutants
  ─────────────────── never reached (1) ────────────────────
    1  lib/util.ml   line 3
  ──────────────────────────────────────────────────────────
  
  ────────────── evaluated outside tests (1) ───────────────
    These sites ran outside every test, at module initialization or in a fixture release.
    1  lib/util.ml   line 1
  ──────────────────────────────────────────────────────────
  
  mutants: 1 reached, 1 killed, 1 never reached, 1 evaluated outside tests, 2 executables, score 100.0%

A mutant whose site one executable's child did not evaluate is no
survivor: it is listed with the command that arms it, and exits 0:

  $ plant "$scratch/not-evaluated" && cd "$scratch/not-evaluated"
  $ mkdata mutants _build/_mutants/a.mutants "$add=killed" "$sub=survived:cli/runs"
  $ mkdata mutants _build/_mutants/b.mutants "$add=killed" "$sub=not_evaluated"
  $ run windtrap mutants
  ─────────────────── not evaluated (1) ────────────────────
    Each site ran in the dry run and not in its mutant's child.
    lib/calc.ml:2:14:sub  a - b → a + b
      arm: WINDTRAP_MUTATE_ARM=lib/calc.ml:2:14:sub dune runtest --force --instrument-with ppx_windtrap.mutate
  ──────────────────────────────────────────────────────────
  
  mutants: 2 reached, 1 killed, 1 not evaluated, 2 executables, score 50.0%

A mutant that the rewriter filtered is counted by its reason and not
scored, and a verdict of another executable outranks the filter:

  $ plant "$scratch/filtered" && cd "$scratch/filtered"
  $ mkdata mutants _build/_mutants/a.mutants "$add=killed" "$sub=filtered:zero operand" "$lt=filtered:same branches" "$or=filtered:same operands" "$and=filtered:same operands"
  $ mkdata mutants _build/_mutants/b.mutants "$add=killed" "$lt=killed"
  $ run windtrap mutants
  ────────────────────── filtered (3) ──────────────────────
    The rewriter found these mutants equivalent or of no interest, and no child tested them.
    2  same operands
    1  zero operand
  ──────────────────────────────────────────────────────────
  
  mutants: 2 reached, 2 killed, 3 filtered, 2 executables, score 100.0%

Survivors are ordered by how many tests reached them, then by identifier:

  $ plant "$scratch/order" && cd "$scratch/order"
  $ mkdata mutants _build/_mutants/one.mutants "$add=survived:t/a" "$sub=survived:t/b;t/c"
  $ mkdata mutants _build/_mutants/two.mutants "$sub=survived:u/d"
  $ run windtrap mutants
  ───────────────────── survivors (2) ──────────────────────
    SURVIVED  lib/calc.ml:2:14:sub  a - b → a + b  (2 runs)
        2 │ let sub a b = a - b
  
      3 tests in 2 executables ran this line and none failed:
        one.mutants  t › b
        one.mutants  t › c
        two.mutants  u › d
  
    SURVIVED  lib/calc.ml:1:14:add  a + b → a - b
        1 │ let add a b = a + b
  
      1 test ran this line and did not fail:
        one.mutants  t › a
  ──────────────────────────────────────────────────────────
  
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:2:14:sub dune runtest --force --instrument-with ppx_windtrap.mutate
  mutants: 2 survived of 2 reached, 2 executables, score 0.0%
  [1]

Reaching tests sort by their spelled path, where a space sorts before the
separator:

  $ plant "$scratch/spelled" && cd "$scratch/spelled"
  $ mkdata mutants _build/_mutants/s.mutants "$add=survived:a/b;a b"
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:1:14:add  a + b → a - b
        1 │ let add a b = a + b
  
      2 tests ran this line and none failed:
        s.mutants  a b
        s.mutants  a › b
  ──────────────────────────────────────────────────────────
  
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:1:14:add dune runtest --force --instrument-with ppx_windtrap.mutate
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%
  [1]

A survivor whose source is not found keeps its identifier and its
rewrite, with no source line:

  $ mkdir "$scratch/no-sources" && cd "$scratch/no-sources"
  $ mkdata mutants _build/_mutants/b.mutants "$sub=survived:t/b"
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:2:14:sub  a - b → a + b
  
      1 test ran this line and did not fail:
        b.mutants  t › b
  ──────────────────────────────────────────────────────────
  
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:2:14:sub dune runtest --force --instrument-with ppx_windtrap.mutate
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%
  [1]

Unstable verdicts

A record keeps the verdict that the mutant had in the file that the run
replaced, when the source did not change. The report lists, for each file,
the mutants whose verdict changed class. Two executables over one library.
In A, add was survived and is killed, sub was killed and survived, lt was
killed by another test, and or was reached and is not. In B, add is killed
as before, sub was not evaluated and is killed, and lt was survived and is
killed elsewhere:

  $ plant "$scratch/unstable" && cd "$scratch/unstable"
  $ mkdata mutants _build/_mutants/a.mutants "$add=killed@survived:t/a" \
  >   "$sub=survived:t/b@killed" "$lt=killed:t/c@killed:t/d" "$or=unreached@survived:t/e"
  $ mkdata mutants _build/_mutants/b.mutants "$add=killed@killed" \
  >   "$sub=killed@not_evaluated" "$lt=elsewhere:a.exe@survived:t/f"
  $ run windtrap mutants
  ────────────────────── unstable (4) ──────────────────────
    The source of each mutant did not change, but its verdict did.
    a.mutants  lib/calc.ml:1:14:add   survived → killed
    a.mutants  lib/calc.ml:2:14:sub   killed → survived
    b.mutants  lib/calc.ml:2:14:sub   not evaluated → killed
    b.mutants  lib/calc.ml:3:14:lt    survived → killed
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  lib/util.ml   line 1
  ──────────────────────────────────────────────────────────
  
  mutants: 3 reached, 3 killed, 1 never reached, 2 executables, score 100.0%

The rows of one mutant in two executables come one for each executable, in
the order of the files. A mutant with another killing test, with the same
class, or that no test reached gives no row. The rows change neither the
score nor the exit code. The document has the same rows in "unstable", with
the index of the executable:

  $ run windtrap mutants --json | sed -n '/"unstable"/,$p'
    "unstable": [
      { "id": "lib/calc.ml:1:14:add", "executable": 0, "previous": "survived", "verdict": "killed" },
      { "id": "lib/calc.ml:2:14:sub", "executable": 0, "previous": "killed", "verdict": "survived" },
      { "id": "lib/calc.ml:2:14:sub", "executable": 1, "previous": "not_evaluated", "verdict": "killed" },
      { "id": "lib/calc.ml:3:14:lt", "executable": 1, "previous": "survived", "verdict": "killed" } ] }

Flaky kills

A record can be flaky: a test killed the mutant, and then failed in a run
with no mutant. The report lists each flaky mutant with the test and its
failure, and the score does not count it. Two executables over one
library. A has add, sub and or flaky. In B, add survived, sub was not
evaluated, lt was killed, and or is flaky with another failure. Flaky ranks
over survived and over not evaluated, and under killed. Of two flaky
records, the smaller failure stays, with the executable that holds it. The
command still exits 0:

  $ plant "$scratch/flaky" && cd "$scratch/flaky"
  $ mkdata mutants _build/_mutants/a.mutants "$add=flaky:t/a:child run 5" \
  >   "$sub=flaky:t/b:child run 4" "$lt=flaky:t/c:child run 6" "$or=flaky:t/d:x"
  $ mkdata mutants _build/_mutants/b.mutants "$add=survived:u/a" \
  >   "$sub=not_evaluated" "$lt=killed" "$or=flaky:t/d:w"
  $ run windtrap mutants
  ─────────────────────── flaky (3) ────────────────────────
    A test killed each mutant, and then failed in a run with no mutant.
    The score does not count these mutants.
    lib/calc.ml:1:14:add  a + b → a - b
      test: a.mutants  t › a
      failure with no mutant: child run 5
    lib/calc.ml:2:14:sub  a - b → a + b
      test: a.mutants  t › b
      failure with no mutant: child run 4
    lib/util.ml:1:13:or  p || q → p && q
      test: b.mutants  t › d
      failure with no mutant: w
  ──────────────────────────────────────────────────────────
  
  mutants: 4 reached, 1 killed, 3 flaky, 2 executables, score 100.0%

The document has the array "flaky", and "mutants" holds no flaky mutant.
"reached" counts the mutants of the score, so it does not count the flaky
mutants. A flaky object names its executable by the index in
"executables":

  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 1, "killed": 1, "survived": 0,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 0,
      "filtered": 0, "flaky": 3, "score": 100.00 },
    "executables": [
      { "name": "a.mutants", "path": null, "suite": null },
      { "name": "b.mutants", "path": null, "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:3:14:lt",
        "file": "lib/calc.ml", "line": 3, "col": 14, "rewrite": "lt",
        "before": "a < b", "after": "a <= b",
        "verdict": "killed" } ],
    "filtered": [ ],
    "flaky": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "test": { "executable": 0, "test": ["t", "a"] },
        "failure": "child run 5" },
      { "id": "lib/calc.ml:2:14:sub",
        "file": "lib/calc.ml", "line": 2, "col": 14, "rewrite": "sub",
        "before": "a - b", "after": "a + b",
        "test": { "executable": 0, "test": ["t", "b"] },
        "failure": "child run 4" },
      { "id": "lib/util.ml:1:13:or",
        "file": "lib/util.ml", "line": 1, "col": 13, "rewrite": "or",
        "before": "p || q", "after": "p && q",
        "test": { "executable": 1, "test": ["t", "d"] },
        "failure": "w" } ],
    "unstable": [ ] }

Executables

A file that records the executable that wrote it names its reaching tests
by the executable's name, and the command to reproduce a survivor runs that
executable through dune:

  $ plant "$scratch/fresh" && cd "$scratch/fresh"
  $ mkdir -p _build/default/test && echo 'a suite' > _build/default/test/a.exe
  $ mkdata mutants _build/_mutants/a.mutants --exe _build/default/test/a.exe \
  >   "$add=killed" "$sub=unreached" "$lt=survived:calc/compares" "$or=unreached" "$and=unreached"
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:3:14:lt  a < b → a <= b
        3 │ let cmp a b = a < b
  
      1 test ran this line and did not fail:
        a.exe  calc › compares
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (3) ────────────────────
    1  lib/calc.ml   line 2
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/a.exe -- --arm lib/calc.ml:3:14:lt
  mutants: 1 survived of 2 reached, 1 killed, 3 never reached, 1 executable, score 50.0%
  [1]

A file of an executable that no longer exists, or that was rebuilt since,
is excluded, so its kill never reaches the report, and the remedy is said
once:

  $ echo 'a sibling' > _build/default/test/b.exe
  $ echo 'another sibling' > _build/default/test/c.exe
  $ mkdata mutants _build/_mutants/b.mutants --exe _build/default/test/b.exe "$lt=killed"
  $ mkdata mutants _build/_mutants/c.mutants --exe _build/default/test/c.exe "$lt=killed"
  $ rm _build/default/test/b.exe
  $ echo 'rebuilt since' > _build/default/test/c.exe
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:3:14:lt  a < b → a <= b
        3 │ let cmp a b = a < b
  
      1 test ran this line and did not fail:
        a.exe  calc › compares
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (3) ────────────────────
    1  lib/calc.ml   line 2
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/a.exe -- --arm lib/calc.ml:3:14:lt
  mutants: 1 survived of 2 reached, 1 killed, 3 never reached, 1 executable, score 50.0%
  --- stderr
  windtrap: .../b.mutants: its executable (_build/default/test/b.exe) no longer exists; excluding it
  windtrap: .../c.mutants: not written by the executable now at _build/default/test/c.exe (rebuilt since); excluding it
  windtrap: re-run every suite with its mutants, then merge again; delete the files whose executable or suite no longer exists
    WINDTRAP_MUTATE=1 dune runtest --force --instrument-with ppx_windtrap.mutate
  [1]

When every file is excluded, the command says what a verdict file is and
what invalidates one:

  $ echo 'rebuilt since' > _build/default/test/a.exe
  $ rm _build/_mutants/b.mutants _build/_mutants/c.mutants
  $ run windtrap mutants
  --- stderr
  windtrap: .../a.mutants: not written by the executable now at _build/default/test/a.exe (rebuilt since); excluding it
  windtrap: found 1 .mutants file and every one is stale
    A verdict is written only by a run asked to test its mutants, and it is
    invalidated by any later build of the executable that wrote it.
  windtrap: re-run every suite with its mutants, then merge again; delete the files whose executable or suite no longer exists
    WINDTRAP_MUTATE=1 dune runtest --force --instrument-with ppx_windtrap.mutate
  [1]

An executable outside every build directory writes under _windtrap, and
the remedy names no command:

  $ rm _build/_mutants/a.mutants
  $ echo 'a hand-built suite' > no-such-exe
  $ mkdata mutants _windtrap/mutants/abs.mutants --exe no-such-exe "$lt=killed"
  $ rm no-such-exe
  $ run windtrap mutants > abs
  [1]
  $ sed -E 's#\(.*[/\\]no-such-exe\)#(.../no-such-exe)#' abs
  --- stderr
  windtrap: .../abs.mutants: its executable (.../no-such-exe) no longer exists; excluding it
  windtrap: found 1 .mutants file and every one is orphaned
    A verdict is written only by a run asked to test its mutants, and it is
    invalidated by any later build of the executable that wrote it.
  windtrap: re-run every suite with its mutants (--mutate, instrumented with ppx_windtrap.mutate, forcing the runs your build tool cached), then merge again; delete the files whose executable or suite no longer exists

The executable column names each file by its executable's basename, an
inline-test runner by its library, and a file with no identity by its own
name. Rows sort by executable, then test, in one column as wide as the
widest name. The survivor is reproduced in the first executable of its
reaching tests that runs alone, here test_calc.exe, though an inline test
comes first:

  $ plant "$scratch/labels" && cd "$scratch/labels"
  $ mkdir -p _build/default/test _build/default/lib/.my_lib_expect.inline-tests
  $ echo 'the unit suite' > _build/default/test/test_calc.exe
  $ echo 'the inline runner' > _build/default/lib/.my_lib_expect.inline-tests/inline-test-runner.exe
  $ mkdata mutants _build/_mutants/unit.mutants --exe _build/default/test/test_calc.exe \
  >   "$add=survived:calc/adds;calc/adds zero"
  $ mkdata mutants _build/_mutants/inline.mutants \
  >   --exe _build/default/lib/.my_lib_expect.inline-tests/inline-test-runner.exe \
  >   "$add=survived:my_lib_expect/add"
  $ mkdata mutants _build/_mutants/plain.mutants "$add=survived:hand/written"
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:1:14:add  a + b → a - b  (3 runs)
        1 │ let add a b = a + b
  
      4 tests in 3 executables ran this line and none failed:
        my_lib_expect  my_lib_expect › add
        plain.mutants  hand › written
        test_calc.exe  calc › adds
        test_calc.exe  calc › adds zero
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/test_calc.exe -- --arm lib/calc.ml:1:14:add
  mutants: 1 survived of 1 reached, 3 executables, score 0.0%
  [1]

Without it, the survivor is reproduced through the build, since dune alone
runs an inline-test runner:

  $ run windtrap mutants _build/_mutants/inline.mutants _build/_mutants/plain.mutants | grep reproduce
  reproduce: WINDTRAP_MUTATE_ARM=lib/calc.ml:1:14:add dune runtest --force --instrument-with ppx_windtrap.mutate

One column serves every block:

  $ plant "$scratch/column" && cd "$scratch/column"
  $ mkdir -p _build/default/test
  $ echo short > _build/default/test/t.exe
  $ echo long > _build/default/test/a_long_name.exe
  $ mkdata mutants _build/_mutants/short.mutants --exe _build/default/test/t.exe "$add=survived:calc/adds"
  $ mkdata mutants _build/_mutants/long.mutants --exe _build/default/test/a_long_name.exe \
  >   "$sub=survived:calc/subtracts"
  $ run windtrap mutants | grep '›'
        t.exe            calc › adds
        a_long_name.exe  calc › subtracts

The command runs an executable in which the mutant survived. Two files
name t.exe here, and the first in path order did not reach the mutant:

  $ plant "$scratch/launcher" && cd "$scratch/launcher"
  $ mkdir -p _build/default/a _build/default/b
  $ echo 'suite a' > _build/default/a/t.exe
  $ echo 'suite b' > _build/default/b/t.exe
  $ mkdata mutants _build/_mutants/1.mutants --exe _build/default/a/t.exe "$add=unreached"
  $ mkdata mutants _build/_mutants/2.mutants --exe _build/default/b/t.exe "$add=survived:calc/adds"
  $ run windtrap mutants | grep reproduce
  reproduce: dune exec --instrument-with ppx_windtrap.mutate b/t.exe -- --arm lib/calc.ml:1:14:add

A target without a directory is spelled from the current one, whether the
executable is at the root of the build context or its identity has one
component:

  $ plant "$scratch/root-exe" && cd "$scratch/root-exe"
  $ mkdir -p _build/default && echo 'a suite' > _build/default/t.exe
  $ mkdata mutants _build/_mutants/t.mutants --exe _build/default/t.exe "$add=survived:calc/adds"
  $ run windtrap mutants | grep reproduce
  reproduce: dune exec --instrument-with ppx_windtrap.mutate ./t.exe -- --arm lib/calc.ml:1:14:add
  $ plant "$scratch/one-component" && cd "$scratch/one-component"
  $ mkdir _build && echo 'a suite' > _build/t.exe
  $ mkdata mutants _build/_mutants/t.mutants --exe _build/t.exe "$add=survived:calc/adds"
  $ run windtrap mutants | grep reproduce
  reproduce: dune exec --instrument-with ppx_windtrap.mutate ./t.exe -- --arm lib/calc.ml:1:14:add

An executable under no build directory is run as it is, and a path a
shell would split is one quoted word, as is such a dune target:

  $ plant "$scratch/built by hand" && cd "$scratch/built by hand"
  $ echo 'built by hand' > test_calc.exe
  $ mkdata mutants _windtrap/mutants/calc.mutants --exe test_calc.exe "$add=survived:calc/adds"
  $ run windtrap mutants | grep reproduce | sed "s|'.*/built by hand/|'.../built by hand/|"
  reproduce: '.../built by hand/test_calc.exe' --arm lib/calc.ml:1:14:add
  $ plant "$scratch/spaced" && cd "$scratch/spaced"
  $ mkdir -p "_build/default/my tests" && echo 'a suite' > "_build/default/my tests/a.exe"
  $ mkdata mutants _build/_mutants/a.mutants --exe "_build/default/my tests/a.exe" "$add=survived:calc/adds"
  $ run windtrap mutants | grep reproduce
  reproduce: dune exec --instrument-with ppx_windtrap.mutate 'my tests/a.exe' -- --arm lib/calc.ml:1:14:add

The score and its gate

The score is the share of the killed mutants among those killed, survived
and not evaluated. Without a gate one survivor fails the command. With
--min-score, the outcome line gives the gate, and only a score below it
fails the command. The gate compares the score before it is rounded:

  $ cd "$scratch/three"
  $ for min in 0 60 66.6 66.7 100; do
  >   run windtrap mutants --min-score=$min > gated; echo "[$?] $(tail -n 1 gated)"
  > done
  [0] mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 0%: ok
  [0] mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 60%: ok
  [0] mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 66.6%: ok
  [1] mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 66.7%: FAILED
  [1] mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 100%: FAILED

Under a gate the report is the same, but for its outcome line:

  $ run windtrap mutants --min-score 50 > gated
  $ diff merged gated
  15c15
  < mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%
  ---
  > mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 50%: ok
  [1]

A score below the gate is red, and so is FAILED:

  $ run WINDTRAP_COLOR=always windtrap mutants --min-score 70 > /dev/null
  [1]
  $ tail -n 1 "$bin/out" | esc
  mutants: \e[31m1 survived\e[0m of 3 reached, \e[32m2 killed\e[0m, \e[33m2 never reached\e[0m, 3 executables, \e[31mscore 66.7%\e[0m, minimum 70%: \e[31mFAILED\e[0m

A mutant that no test reached, or that ran outside every test, is not
scored. With no scored mutant the line gives no score, and a gate reads it
as 100:

  $ plant "$scratch/none-scored" && cd "$scratch/none-scored"
  $ mkdata mutants _build/_mutants/all.mutants "$add=unreached" "$sub=outside_tests"
  $ run windtrap mutants | tail -n 1
  mutants: 0 reached, 1 never reached, 1 evaluated outside tests, 1 executable
  $ run windtrap mutants --min-score 100 | tail -n 1
  mutants: 0 reached, 1 never reached, 1 evaluated outside tests, 1 executable, score 100.0%, minimum 100%: ok

A mutant that a child did not evaluate is scored as not killed. Thus a
gate can fail a merge in which no mutant survived:

  $ plant "$scratch/unevaluated" && cd "$scratch/unevaluated"
  $ mkdata mutants _build/_mutants/u.mutants "$add=killed" "$sub=not_evaluated"
  $ for min in '' 50 60; do
  >   run windtrap mutants ${min:+--min-score=$min} > gated; echo "[$?] $(tail -n 1 gated)"
  > done
  [0] mutants: 2 reached, 1 killed, 1 not evaluated, 1 executable, score 50.0%
  [0] mutants: 2 reached, 1 killed, 1 not evaluated, 1 executable, score 50.0%, minimum 50%: ok
  [1] mutants: 2 reached, 1 killed, 1 not evaluated, 1 executable, score 50.0%, minimum 60%: FAILED

A value that is not a percentage from 0 to 100 is a usage error, and the
flag needs its value:

  $ for value in eleventy '' nan inf -1 100.5; do
  >   run windtrap mutants "--min-score=$value"; echo "[$?]"
  > done
  --- stderr
  windtrap: invalid value 'eleventy' for --min-score: expected a percentage (0-100)
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  --- stderr
  windtrap: invalid value '' for --min-score: expected a percentage (0-100)
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  --- stderr
  windtrap: invalid value 'nan' for --min-score: expected a percentage (0-100)
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  --- stderr
  windtrap: invalid value 'inf' for --min-score: expected a percentage (0-100)
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  --- stderr
  windtrap: invalid value '-1' for --min-score: expected a percentage (0-100)
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  --- stderr
  windtrap: invalid value '100.5' for --min-score: expected a percentage (0-100)
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  $ run windtrap mutants --min-score
  --- stderr
  windtrap: option '--min-score' requires an argument
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]

The document

--json writes the merge as one document on standard output. Each mutant
has its verdict, in the order of identifiers, and a survivor has the tests
that ran it in each executable in which it survived. A killed mutant has
no tests, also when its file names the test that killed it. A test names
its executable by its index in "executables":

  $ cd "$scratch/three"
  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 3, "killed": 2, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 2,
      "filtered": 0, "flaky": 0, "score": 66.67 },
    "executables": [
      { "name": "windtrap-a.mutants", "path": null, "suite": null },
      { "name": "windtrap-b.mutants", "path": null, "suite": null },
      { "name": "windtrap-c.mutants", "path": null, "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "killed" },
      { "id": "lib/calc.ml:2:14:sub",
        "file": "lib/calc.ml", "line": 2, "col": 14, "rewrite": "sub",
        "before": "a - b", "after": "a + b",
        "verdict": "survived",
        "runs": 2,
        "tests": [
          { "executable": 1, "test": ["cli", "subtracts"] },
          { "executable": 2, "test": ["prop", "sub law"] } ] },
      { "id": "lib/calc.ml:3:14:lt",
        "file": "lib/calc.ml", "line": 3, "col": 14, "rewrite": "lt",
        "before": "a < b", "after": "a <= b",
        "verdict": "killed" },
      { "id": "lib/util.ml:1:13:or",
        "file": "lib/util.ml", "line": 1, "col": 13, "rewrite": "or",
        "before": "p || q", "after": "p && q",
        "verdict": "unreached" },
      { "id": "lib/util.ml:3:22:and",
        "file": "lib/util.ml", "line": 3, "col": 22, "rewrite": "and",
        "before": "p && q", "after": "p || q",
        "verdict": "unreached" } ],
    "filtered": [ ],
    "flaky": [ ],
    "unstable": [ ] }
  [1]
  $ cp "$bin/out" json

Two executables can have one name, and the index tells them apart. An
executable has the path that its file records, and null for a file that
records none:

  $ cd "$scratch/launcher"
  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 1, "killed": 0, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 0,
      "filtered": 0, "flaky": 0, "score": 0.00 },
    "executables": [
      { "name": "t.exe", "path": "default/a/t.exe", "suite": null },
      { "name": "t.exe", "path": "default/b/t.exe", "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "survived",
        "runs": 1,
        "tests": [
          { "executable": 1, "test": ["calc", "adds"] } ] } ],
    "filtered": [ ],
    "flaky": [ ],
    "unstable": [ ] }
  [1]
  $ cd "$scratch/labels"
  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 1, "killed": 0, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 0,
      "filtered": 0, "flaky": 0, "score": 0.00 },
    "executables": [
      { "name": "my_lib_expect", "path": "default/lib/.my_lib_expect.inline-tests/inline-test-runner.exe", "suite": null },
      { "name": "plain.mutants", "path": null, "suite": null },
      { "name": "test_calc.exe", "path": "default/test/test_calc.exe", "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "survived",
        "runs": 3,
        "tests": [
          { "executable": 0, "test": ["my_lib_expect", "add"] },
          { "executable": 1, "test": ["hand", "written"] },
          { "executable": 2, "test": ["calc", "adds"] },
          { "executable": 2, "test": ["calc", "adds zero"] } ] } ],
    "filtered": [ ],
    "flaky": [ ],
    "unstable": [ ] }
  [1]

In one executable, the tests are sorted name by name, the outermost name
first, and a test that the file records two times is given once. The
report compares the names that it prints, so its order can be different:

  $ plant "$scratch/json-order" && cd "$scratch/json-order"
  $ mkdata mutants _build/_mutants/s.mutants "$add=survived:z/b;a b;a/b;z/b"
  $ run windtrap mutants --json | grep '"executable"'
          { "executable": 0, "test": ["a", "b"] },
          { "executable": 0, "test": ["a b"] },
          { "executable": 0, "test": ["z", "b"] } ] } ],
  $ run windtrap mutants | grep 's\.mutants  '
        s.mutants  a b
        s.mutants  a › b
        s.mutants  z › b

A survivor that two files let survive has the sum of their runs, after
its title and in "runs":

  $ plant "$scratch/runs" && cd "$scratch/runs"
  $ mkdata mutants _build/_mutants/a.mutants "$add=survived:t/a:3"
  $ mkdata mutants _build/_mutants/b.mutants "$add=survived:t/b"
  $ run windtrap mutants | grep SURVIVED
    SURVIVED  lib/calc.ml:1:14:add  a + b → a - b  (4 runs)
  $ run windtrap mutants --json | grep '"runs"'
        "runs": 4,

A mutant that a child did not evaluate, and a mutant that ran outside
every test, have their verdicts and no tests:

  $ plant "$scratch/json-verdicts" && cd "$scratch/json-verdicts"
  $ mkdata mutants _build/_mutants/a.mutants "$add=killed" "$sub=not_evaluated" "$lt=outside_tests"
  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 2, "killed": 1, "survived": 0,
      "not_evaluated": 1, "outside_tests": 1, "unreached": 0,
      "filtered": 0, "flaky": 0, "score": 50.00 },
    "executables": [
      { "name": "a.mutants", "path": null, "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "killed" },
      { "id": "lib/calc.ml:2:14:sub",
        "file": "lib/calc.ml", "line": 2, "col": 14, "rewrite": "sub",
        "before": "a - b", "after": "a + b",
        "verdict": "not_evaluated" },
      { "id": "lib/calc.ml:3:14:lt",
        "file": "lib/calc.ml", "line": 3, "col": 14, "rewrite": "lt",
        "before": "a < b", "after": "a <= b",
        "verdict": "outside_tests" } ],
    "filtered": [ ],
    "flaky": [ ],
    "unstable": [ ] }

A filtered mutant is in the array "filtered", with its reason, and not in
"mutants":

  $ cd "$scratch/filtered"
  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 2, "killed": 2, "survived": 0,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 0,
      "filtered": 3, "flaky": 0, "score": 100.00 },
    "executables": [
      { "name": "a.mutants", "path": null, "suite": null },
      { "name": "b.mutants", "path": null, "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "killed" },
      { "id": "lib/calc.ml:3:14:lt",
        "file": "lib/calc.ml", "line": 3, "col": 14, "rewrite": "lt",
        "before": "a < b", "after": "a <= b",
        "verdict": "killed" } ],
    "filtered": [
      { "id": "lib/calc.ml:2:14:sub",
        "file": "lib/calc.ml", "line": 2, "col": 14, "rewrite": "sub",
        "before": "a - b", "after": "a + b",
        "reason": "zero operand" },
      { "id": "lib/util.ml:1:13:or",
        "file": "lib/util.ml", "line": 1, "col": 13, "rewrite": "or",
        "before": "p || q", "after": "p && q",
        "reason": "same operands" },
      { "id": "lib/util.ml:3:22:and",
        "file": "lib/util.ml", "line": 3, "col": 22, "rewrite": "and",
        "before": "p && q", "after": "p || q",
        "reason": "same operands" } ],
    "flaky": [ ],
    "unstable": [ ] }

Each string is escaped as JSON needs, and bytes that are not UTF-8 become
the replacement character:

  $ plant "$scratch/escape" && cd "$scratch/escape"
  $ mkdata mutants _build/_mutants/e.mutants "$add=survived:t/say \"hi\"\\ $(printf '\t\001\377')"
  $ run windtrap mutants --json | grep '"test"'
          { "executable": 0, "test": ["t", "say \"hi\"\\ \t\u0001\ufffd"] } ] } ],

Under a gate the document is the same, the exit code is that of the gate,
and the outcome line goes to standard error:

  $ cd "$scratch/three"
  $ errs() { run "$@" > /dev/null; code=$?; cat "$bin/err"; return $code; }
  $ errs windtrap mutants --json --min-score 70
  windtrap: mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 70%: FAILED
  [1]
  $ diff json "$bin/out"
  $ errs windtrap mutants --json --min-score 50
  windtrap: mutants: 1 survived of 3 reached, 2 killed, 2 never reached, 3 executables, score 66.7%, minimum 50%: ok
  $ diff json "$bin/out"

--color and a WINDTRAP_COLOR the report refuses change neither the
document nor the exit code:

  $ run windtrap mutants --json --color=always > shown
  [1]
  $ diff json shown
  $ run WINDTRAP_COLOR=sometimes windtrap mutants --json > shown
  [1]
  $ diff json shown

Killed elsewhere

A suite that ran with --mutate-skip-killed records a mutant that another
executable killed as killed elsewhere, with that executable's name. The
merge counts it as killed. Each project below writes the executables that
it names, and plants each file with the identity of its executable, so that
the file is fresh:

  $ exes() { mkdir -p _build/default/test; for n in "$@"; do echo "suite $n" > "_build/default/test/$n.exe"; done; }

When a file of the merge kills the mutant directly, the merge says nothing
more. The report is the report of the runs that tested every mutant:

  $ plant "$scratch/direct" && cd "$scratch/direct" && exes a b
  $ mkdata mutants _build/_mutants/windtrap-a.mutants --exe _build/default/test/a.exe \
  >   "$add=killed:calc/adds" "$sub=survived:calc/subs"
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=elsewhere:default/test/a.exe" "$sub=survived:cli/subs"
  $ run windtrap mutants > skipped
  [1]
  $ test ! -s "$bin/err"
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=survived:cli/adds" "$sub=survived:cli/subs"
  $ run windtrap mutants > tested
  [1]
  $ test ! -s "$bin/err"
  $ cmp skipped tested

When no file of the merge kills the mutant, the mutant is still killed, and
the merge says on standard error which run to do again. Here the file of
a.exe is not in the merge:

  $ plant "$scratch/missing" && cd "$scratch/missing" && exes a b
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=elsewhere:default/test/a.exe" "$sub=survived:cli/subs" "$lt=unreached" "$or=unreached" "$and=unreached"
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:2:14:sub  a - b → a + b
        2 │ let sub a b = a - b
  
      1 test ran this line and did not fail:
        b.exe  cli › subs
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (3) ────────────────────
    1  lib/calc.ml   line 3
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/b.exe -- --arm lib/calc.ml:2:14:sub
  mutants: 1 survived of 2 reached, 1 killed, 3 never reached, 1 executable, score 50.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/a.exe, but no verdict file of the merge gives this kill: run default/test/a.exe with its mutants, then merge again
  [1]

The document counts the mutant as killed, and the note is the same:

  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 2, "killed": 1, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 3,
      "filtered": 0, "flaky": 0, "score": 50.00 },
    "executables": [
      { "name": "b.exe", "path": "default/test/b.exe", "suite": null } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "killed" },
      { "id": "lib/calc.ml:2:14:sub",
        "file": "lib/calc.ml", "line": 2, "col": 14, "rewrite": "sub",
        "before": "a - b", "after": "a + b",
        "verdict": "survived",
        "runs": 1,
        "tests": [
          { "executable": 0, "test": ["cli", "subs"] } ] },
      { "id": "lib/calc.ml:3:14:lt",
        "file": "lib/calc.ml", "line": 3, "col": 14, "rewrite": "lt",
        "before": "a < b", "after": "a <= b",
        "verdict": "unreached" },
      { "id": "lib/util.ml:1:13:or",
        "file": "lib/util.ml", "line": 1, "col": 13, "rewrite": "or",
        "before": "p || q", "after": "p && q",
        "verdict": "unreached" },
      { "id": "lib/util.ml:3:22:and",
        "file": "lib/util.ml", "line": 3, "col": 22, "rewrite": "and",
        "before": "p && q", "after": "p || q",
        "verdict": "unreached" } ],
    "filtered": [ ],
    "flaky": [ ],
    "unstable": [ ] }
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/a.exe, but no verdict file of the merge gives this kill: run default/test/a.exe with its mutants, then merge again
  [1]

There is one note for each killer, in the order of the killers. The count
and the wording follow the number of mutants:

  $ plant "$scratch/plurals" && cd "$scratch/plurals" && exes a b c
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=elsewhere:default/test/a.exe" "$sub=elsewhere:default/test/a.exe" \
  >   "$lt=elsewhere:default/test/c.exe" "$or=unreached" "$and=unreached"
  $ run windtrap mutants
  ─────────────────── never reached (2) ────────────────────
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  mutants: 3 reached, 3 killed, 2 never reached, 1 executable, score 100.0%
  --- stderr
  windtrap: 2 mutants count as killed by default/test/a.exe, but no verdict file of the merge gives these kills: run default/test/a.exe with its mutants, then merge again
  windtrap: 1 mutant counts as killed by default/test/c.exe, but no verdict file of the merge gives this kill: run default/test/c.exe with its mutants, then merge again

When the file of the killer is in the merge and does not kill the mutant,
the killer did not give the kill again. The note tells to run the suite
that skipped the mutant:

  $ plant "$scratch/present" && cd "$scratch/present" && exes a b
  $ mkdata mutants _build/_mutants/windtrap-a.mutants --exe _build/default/test/a.exe \
  >   "$add=survived:calc/adds"
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=elsewhere:default/test/a.exe"
  $ run windtrap mutants
  mutants: 1 reached, 1 killed, 2 executables, score 100.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/a.exe, but no verdict file of default/test/a.exe in the merge kills it: run default/test/b.exe again with its mutants, then merge again

Two suites that skipped one mutant because of each other leave no kill.
Each note names the other suite:

  $ plant "$scratch/mutual" && cd "$scratch/mutual" && exes a b
  $ mkdata mutants _build/_mutants/windtrap-a.mutants --exe _build/default/test/a.exe \
  >   "$add=elsewhere:default/test/b.exe"
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=elsewhere:default/test/a.exe"
  $ run windtrap mutants
  mutants: 1 reached, 1 killed, 2 executables, score 100.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/a.exe, but no verdict file of default/test/a.exe in the merge kills it: run default/test/b.exe again with its mutants, then merge again
  windtrap: 1 mutant counts as killed by default/test/b.exe, but no verdict file of default/test/b.exe in the merge kills it: run default/test/a.exe again with its mutants, then merge again

When the killer no longer exists, no run of it can give the kill. The note
tells to run each suite that skipped the mutant, once:

  $ plant "$scratch/gone" && cd "$scratch/gone" && exes b c
  $ mkdata mutants _build/_mutants/windtrap-b.mutants --exe _build/default/test/b.exe \
  >   "$add=elsewhere:default/test/gone.exe"
  $ mkdata mutants _build/_mutants/windtrap-c.mutants --exe _build/default/test/c.exe \
  >   "$add=elsewhere:default/test/gone.exe"
  $ run windtrap mutants
  mutants: 1 reached, 1 killed, 2 executables, score 100.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/gone.exe, but default/test/gone.exe no longer exists: run default/test/b.exe, default/test/c.exe again with their mutants, then merge again

A file with no identity names no executable, so the note names the file:

  $ plant "$scratch/anonymous" && cd "$scratch/anonymous" && exes b
  $ mkdata mutants _build/_mutants/windtrap-b.mutants "$add=elsewhere:default/test/gone.exe"
  $ run windtrap mutants
  mutants: 1 reached, 1 killed, 1 executable, score 100.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/gone.exe, but default/test/gone.exe no longer exists: run the executable that wrote .../windtrap-b.mutants again with its mutants, then merge again

When the killer is another suite of the same executable, the file of the
suite that skipped the mutant is a file of that executable in the merge.
The note tells to run that executable again, and it does not go away when
the file of the killer is deleted:

  $ plant "$scratch/sibling" && cd "$scratch/sibling" && exes a
  $ mkdata mutants _build/_mutants/one.mutants --exe _build/default/test/a.exe --suite one "$add=survived:t/adds"
  $ mkdata mutants _build/_mutants/two.mutants --exe _build/default/test/a.exe --suite two "$add=elsewhere:default/test/a.exe"
  $ run windtrap mutants
  mutants: 1 reached, 1 killed, 1 executable, score 100.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/a.exe, but no verdict file of default/test/a.exe in the merge kills it: run default/test/a.exe again with its mutants, then merge again
  $ rm _build/_mutants/one.mutants
  $ run windtrap mutants
  mutants: 1 reached, 1 killed, 1 executable, score 100.0%
  --- stderr
  windtrap: 1 mutant counts as killed by default/test/a.exe, but no verdict file of default/test/a.exe in the merge kills it: run default/test/a.exe again with its mutants, then merge again

Suites of one executable

Each suite of an executable has its own file. The suites one and two of
a.exe both reach add and sub. Suite one kills add, and suite two lets it
survive. Both suites let sub survive, and both killed it in the run before.
The two rows of the unstable section are equal, so the report prints one:

  $ plant "$scratch/suites" && cd "$scratch/suites" && exes a
  $ mkdata mutants _build/_mutants/one.mutants --exe _build/default/test/a.exe --suite one \
  >   "$add=killed:t/adds" "$sub=survived:t/subs@killed" "$lt=unreached" "$or=unreached" "$and=unreached"
  $ mkdata mutants _build/_mutants/two.mutants --exe _build/default/test/a.exe --suite two \
  >   "$add=survived:u/adds" "$sub=survived:u/subs@killed" "$lt=unreached" "$or=unreached" "$and=unreached"
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  lib/calc.ml:2:14:sub  a - b → a + b  (2 runs)
        2 │ let sub a b = a - b
  
      2 tests ran this line and none failed:
        a.exe  t › subs
        a.exe  u › subs
  ──────────────────────────────────────────────────────────
  
  ────────────────────── unstable (1) ──────────────────────
    The source of each mutant did not change, but its verdict did.
    a.exe  lib/calc.ml:2:14:sub   killed → survived
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (3) ────────────────────
    1  lib/calc.ml   line 3
    2  lib/util.ml   lines 1, 3
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/a.exe -- --arm lib/calc.ml:2:14:sub
  mutants: 1 survived of 2 reached, 1 killed, 3 never reached, 1 executable, score 50.0%
  [1]

The document gives the suite of each file, and one object of "unstable" for
each file:

  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 2, "killed": 1, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 3,
      "filtered": 0, "flaky": 0, "score": 50.00 },
    "executables": [
      { "name": "a.exe", "path": "default/test/a.exe", "suite": "one" },
      { "name": "a.exe", "path": "default/test/a.exe", "suite": "two" } ],
    "mutants": [
      { "id": "lib/calc.ml:1:14:add",
        "file": "lib/calc.ml", "line": 1, "col": 14, "rewrite": "add",
        "before": "a + b", "after": "a - b",
        "verdict": "killed" },
      { "id": "lib/calc.ml:2:14:sub",
        "file": "lib/calc.ml", "line": 2, "col": 14, "rewrite": "sub",
        "before": "a - b", "after": "a + b",
        "verdict": "survived",
        "runs": 2,
        "tests": [
          { "executable": 0, "test": ["t", "subs"] },
          { "executable": 1, "test": ["u", "subs"] } ] },
      { "id": "lib/calc.ml:3:14:lt",
        "file": "lib/calc.ml", "line": 3, "col": 14, "rewrite": "lt",
        "before": "a < b", "after": "a <= b",
        "verdict": "unreached" },
      { "id": "lib/util.ml:1:13:or",
        "file": "lib/util.ml", "line": 1, "col": 13, "rewrite": "or",
        "before": "p || q", "after": "p && q",
        "verdict": "unreached" },
      { "id": "lib/util.ml:3:22:and",
        "file": "lib/util.ml", "line": 3, "col": 22, "rewrite": "and",
        "before": "p && q", "after": "p || q",
        "verdict": "unreached" } ],
    "filtered": [ ],
    "flaky": [ ],
    "unstable": [
      { "id": "lib/calc.ml:2:14:sub", "executable": 0, "previous": "killed", "verdict": "survived" },
      { "id": "lib/calc.ml:2:14:sub", "executable": 1, "previous": "killed", "verdict": "survived" } ] }
  [1]

The outcome line counts executables by their path. Two projects that each
build test/a.exe give two executables in one merge:

  $ plant "$scratch/root-a" && cd "$scratch/root-a" && exes a
  $ mkdata mutants _build/_mutants/a.mutants --exe _build/default/test/a.exe --suite one "$add=killed:t/adds"
  $ plant "$scratch/root-b" && cd "$scratch/root-b" && exes a
  $ mkdata mutants _build/_mutants/a.mutants --exe _build/default/test/a.exe --suite one "$add=killed:t/adds"
  $ run windtrap mutants "$scratch/root-a/_build/_mutants" "$scratch/root-b/_build/_mutants"
  mutants: 1 reached, 1 killed, 2 executables, score 100.0%

A file below no build directory gives no path for a relative identity, and
the identity counts in its place:

  $ mkdir copies
  $ mkdata mutants copies/one.mutants --exe _build/default/test/a.exe --suite one "$add=killed:t/adds"
  $ mkdata mutants copies/two.mutants --exe _build/default/test/a.exe --suite two "$add=killed:u/adds"
  $ run windtrap mutants copies
  mutants: 1 reached, 1 killed, 1 executable, score 100.0%

Files that cannot be merged

Nothing to merge is exit 1, with a hint that names the backend and the
flag a verdict needs:

  $ mkdir "$scratch/empty" && cd "$scratch/empty"
  $ run windtrap mutants
  --- stderr
  windtrap: no .mutants files found
  Instrument the library under test with ppx_windtrap.mutate and run every suite with its mutants (--mutate) first; every mutation run writes its verdicts under the build directory's _mutants or under _windtrap/mutants.
  [1]

A truncated file is corrupt, and nothing is reported:

  $ plant "$scratch/truncated" && cd "$scratch/truncated"
  $ mkdata mutants whole.mutants "$add=killed" "$sub=unreached" "$lt=survived:calc/compares"
  $ mkdir -p _build/_mutants
  $ head -c $(( $(wc -c < whole.mutants) - 11 )) whole.mutants > _build/_mutants/cut.mutants
  $ run windtrap mutants
  --- stderr
  windtrap: .../cut.mutants: corrupt verdict file: truncated test name
  [1]

A file of another format is refused and never converted, and the remedy
is to delete it, which a coverage dump in the directory shares:

  $ mkdir -p "$scratch/foreign/_build/_mutants" && cd "$scratch/foreign"
  $ printf 'windtrap-mutants-v0\n1\nsome older payload\n' > _build/_mutants/old.mutants
  $ run windtrap mutants
  --- stderr
  windtrap: .../old.mutants: not a windtrap verdict file (expected header "windtrap-mutants-v10", found "windtrap-mutants-v0"); files written by other windtrap versions are not readable - delete the stale verdict files, then re-run the mutation tests
  [1]
  $ rm _build/_mutants/old.mutants
  $ printf 'windtrap-coverage-v3\n0\n' > _build/_mutants/cov.mutants
  $ run windtrap mutants
  --- stderr
  windtrap: .../cov.mutants: not a windtrap verdict file (expected header "windtrap-mutants-v10", found "windtrap-coverage-v3"); files written by other windtrap versions are not readable - delete the stale verdict files, then re-run the mutation tests
  [1]

A PATH that cannot be used fails the command, and the files named beside
it are not reported:

  $ cd "$scratch/three"
  $ run windtrap mutants _build/_mutants/windtrap-a.mutants absent.mutants
  --- stderr
  windtrap: absent.mutants: no such file or directory
  [1]

The command line


--help says what the command does and does not do, and its exit code, in
80 columns:

  $ run windtrap mutants --help
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
  $ cp "$bin/out" help
  $ awk '{ sub(/\r$/, "") } length > 80' help
  $ run windtrap mutants -h > /dev/null && diff help "$bin/out"
  $ run windtrap mutants -help > /dev/null && diff help "$bin/out"

An unknown option is a usage error, as is a lone dash:

  $ run windtrap mutants --frobnicate
  --- stderr
  windtrap: unknown option '--frobnicate'
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  $ run windtrap mutants -
  --- stderr
  windtrap: unknown option '-'
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]

--color is the runner's flag, in either spelling, and it hides
WINDTRAP_COLOR:

  $ run WINDTRAP_COLOR=always windtrap mutants --color never > /dev/null
  [1]
  $ diff merged "$bin/out"
  $ run windtrap mutants --color=always > /dev/null
  [1]
  $ diff coloured "$bin/out"
  $ run WINDTRAP_COLOR=sometimes windtrap mutants --color=always > /dev/null
  [1]
  $ diff coloured "$bin/out"
  $ run windtrap mutants --color=sometimes
  --- stderr
  windtrap: invalid value 'sometimes' for --color: expected always, never or auto
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]
  $ run windtrap mutants --color
  --- stderr
  windtrap: option '--color' requires an argument
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]

The first argument that starts with a dash ends the parse: a PATH before
-h is not looked at, and an option before --help is refused:

  $ run windtrap mutants absent.mutants -h > /dev/null && diff help "$bin/out"
  $ run windtrap mutants -x --help
  --- stderr
  windtrap: unknown option '-x'
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]

Without --color, a value of WINDTRAP_COLOR the runner refuses is a usage
error, said before any PATH is looked at:

  $ run WINDTRAP_COLOR=sometimes windtrap mutants
  --- stderr
  windtrap: invalid value 'sometimes' for WINDTRAP_COLOR: expected always, never or auto
  [2]
  $ run WINDTRAP_COLOR=sometimes windtrap mutants absent.mutants
  --- stderr
  windtrap: invalid value 'sometimes' for WINDTRAP_COLOR: expected always, never or auto
  [2]
  $ cd / && rm -rf "$scratch"
