Two executables over one library, each running its own mutation loop,
disagree about the library, and `windtrap mutants` merges their verdict
files into the project's answer. pins_add.exe pins calc.ml's add and only
reaches sub; pins_sub.exe does the reverse; both reach shared and pin
nothing about it; neither calls never.

The two executables run from a scratch build directory, where they write
their verdict files, and the source they recorded is planted where it was
recorded. --mutate scopes each loop to calc.ml's mutants, since under
--instrument-with the executables also link an instrumented core.

  $ bin=$PWD
  $ run() {
  >   env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" WINDTRAP_COLOR=never WINDTRAP_SLOW_THRESHOLD=0 "$@" \
  >     > "$bin/out" 2> "$bin/err"
  >   code=$?; cat "$bin/out"
  >   if [ -s "$bin/err" ]; then echo '--- stderr'; cat "$bin/err"; fi
  >   return $code
  > }
  $ root=$(cd "$(mktemp -d)" && pwd -P) && cd "$root"
  $ mkdir -p _build/default/test test/cram/bin
  $ cp "$bin/calc.ml" test/cram/bin/
  $ cp "$bin/pins_add.exe" "$bin/pins_sub.exe" _build/default/test/

Each executable alone calls the mutant its sibling kills a survivor:

  $ run _build/default/test/pins_add.exe --mutate=test/cram/bin/calc.ml > add
  $ grep -e SURVIVED -e '^--- stderr' add
    SURVIVED  test/cram/bin/calc.ml:13:14:add  a - b → a + b
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b
  $ run _build/default/test/pins_sub.exe --mutate=test/cram/bin/calc.ml > sub
  $ grep -e SURVIVED -e '^--- stderr' sub
    SURVIVED  test/cram/bin/calc.ml:12:14:sub  a + b → a - b
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b

The merge keeps the one mutant that survived everywhere, with the reaching
tests of both executables, each named by its executable, and the mutant
neither reached:

  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b
        14 │ let shared a b = a + b
  
      2 tests in 2 executables ran this line and none failed:
        pins_add.exe  shared › shared is nonzero
        pins_sub.exe  shared › shared is not 99
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_add.exe -- --arm test/cram/bin/calc.ml:14:17:sub
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 2 executables, score 66.7%
  [1]

The document gives the same answer: each mutant with its verdict, and the
survivor with the tests that ran it in each executable:

  $ cp "$bin/out" merged
  $ run windtrap mutants --json
  { "version": 1,
    "summary": { "reached": 3, "killed": 2, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 1,
      "filtered": 0, "score": 66.67 },
    "executables": [
      { "name": "pins_add.exe", "path": "default/test/pins_add.exe" },
      { "name": "pins_sub.exe", "path": "default/test/pins_sub.exe" } ],
    "mutants": [
      { "id": "test/cram/bin/calc.ml:12:14:sub",
        "file": "test/cram/bin/calc.ml", "line": 12, "col": 14, "rewrite": "sub",
        "before": "a + b", "after": "a - b",
        "verdict": "killed" },
      { "id": "test/cram/bin/calc.ml:13:14:add",
        "file": "test/cram/bin/calc.ml", "line": 13, "col": 14, "rewrite": "add",
        "before": "a - b", "after": "a + b",
        "verdict": "killed" },
      { "id": "test/cram/bin/calc.ml:14:17:sub",
        "file": "test/cram/bin/calc.ml", "line": 14, "col": 17, "rewrite": "sub",
        "before": "a + b", "after": "a - b",
        "verdict": "survived",
        "tests": [
          { "executable": 0, "test": ["shared", "shared is nonzero"] },
          { "executable": 1, "test": ["shared", "shared is not 99"] } ] },
      { "id": "test/cram/bin/calc.ml:15:16:add",
        "file": "test/cram/bin/calc.ml", "line": 15, "col": 16, "rewrite": "add",
        "before": "a - b", "after": "a + b",
        "verdict": "unreached" } ],
    "filtered": [ ],
    "unstable": [ ] }
  [1]

With a gate, the score decides the exit code, and the survivor alone does
not fail the command:

  $ run windtrap mutants --min-score 60 > /dev/null
  $ tail -n 1 "$bin/out"
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 2 executables, score 66.7%, minimum 60%: ok
  $ run windtrap mutants --min-score 70 > /dev/null
  [1]
  $ tail -n 1 "$bin/out"
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 2 executables, score 66.7%, minimum 70%: FAILED
  $ cp merged "$bin/out"

The command's identifier, pasted into that executable, arms the survivor:

  $ id=$(sed -n 's/^reproduce: .* --arm //p' "$bin/out")
  $ run _build/default/test/pins_add.exe --arm "$id" > armed
  $ head -n 1 armed
  mutant test/cram/bin/calc.ml:14:17:sub armed: a + b → a - b

With --mutate-skip-killed, pins_sub.exe does not test the mutant of add,
which the verdict file of pins_add.exe gives as killed. The report names
the verdict file of pins_add.exe and counts the mutant as not tested.
The mutant of sub on line 12 survived in the run before, so its verdict
changed class, and the report lists it as unstable:

  $ run _build/default/test/pins_sub.exe --mutate=test/cram/bin/calc.ml --mutate-skip-killed > skipped
  $ grep -e SURVIVED -e 'unstable (' -e 'survived → killed' -e '^killed elsewhere' -e '^mutants:' -e '^--- stderr' skipped
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b
  ────────────────────── unstable (1) ──────────────────────
    test/cram/bin/calc.ml:12:14:sub   survived → killed
  killed elsewhere: 1 mutant, not tested, from the verdict file of default/test/pins_add.exe (1)
  mutants: 1 survived of 3 reached by this suite, 1 killed, 1 never reached, 1 not tested, score 50.0%

The merge gives the survivors and the score of the runs without the option.
It lists the skipped mutant as unstable, because pins_sub.exe let it
survive before:

  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b
        14 │ let shared a b = a + b
  
      2 tests in 2 executables ran this line and none failed:
        pins_add.exe  shared › shared is nonzero
        pins_sub.exe  shared › shared is not 99
  ──────────────────────────────────────────────────────────
  
  ────────────────────── unstable (1) ──────────────────────
    The source of each mutant did not change, but its verdict did.
    pins_sub.exe  test/cram/bin/calc.ml:12:14:sub   survived → killed
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_add.exe -- --arm test/cram/bin/calc.ml:14:17:sub
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 2 executables, score 66.7%
  [1]
  $ tail -n 1 merged > a && tail -n 1 "$bin/out" > b && cmp a b

A new build of pins_add.exe makes its verdict file stale. pins_sub.exe
still uses the file, because the source of the mutant did not change:

  $ chmod u+w _build/default/test/pins_add.exe
  $ printf '\n' >> _build/default/test/pins_add.exe
  $ run _build/default/test/pins_sub.exe --mutate=test/cram/bin/calc.ml --mutate-skip-killed | grep -e '^killed elsewhere' -e '^--- stderr'
  killed elsewhere: 1 mutant, not tested, from the verdict file of default/test/pins_add.exe (1)

The merge excludes the stale file, counts the mutant as killed, and tells
to run pins_add.exe again:

  $ run windtrap mutants > /dev/null
  [1]
  $ tail -n 1 "$bin/out"
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7%
  $ grep 'counts as killed' "$bin/err"
  windtrap: 1 mutant counts as killed by default/test/pins_add.exe, but no verdict file of the merge gives this kill: run default/test/pins_add.exe with its mutants, then merge again
  $ cd / && rm -rf "$root"
