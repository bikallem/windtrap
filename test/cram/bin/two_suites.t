Each suite of an executable has its own verdict file, and `windtrap
mutants` merges the files of all suites. Two cases write the files of
several suites: a main that calls `Windtrap.run` with two suite names
(pins_both.exe), and the inline-test runner of a library with two test
files (pins_inline.exe), whose partitions dune runs at the same time.
POSIX only: the loop forks.

The executables run from scratch build directories, where they write
their verdict files, and the source they recorded is planted where it was
recorded. --mutate scopes each loop to calc.ml's mutants, since under
--instrument-with the executables also link an instrumented core.

  $ bin=$PWD
  $ run() {
  >   env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" WINDTRAP_COLOR=never WINDTRAP_SLOW_THRESHOLD=0 "$@" \
  >     > "$bin/out" 2> "$bin/err"
  >   code=$?; cat "$bin/out"
  >   if [ -s "$bin/err" ]; then
  >     echo '--- stderr'
  >     sed -E 's#[^ ()]*[/\\]([^/\\ ()]+\.mutants)#.../\1#g' "$bin/err"
  >   fi
  >   return $code
  > }
  $ hashes() { ls _build/_mutants | sed -E 's/[0-9a-f]{32}/HASH/g'; }

A main with two suites

pins_both.exe calls `Windtrap.run` for the suite adds, which pins add, and
for the suite subs, which pins sub. Each suite reaches the mutant that the
other suite pins, and both reach shared:

  $ rootA=$(cd "$(mktemp -d)" && pwd -P) && cd "$rootA"
  $ mkdir -p _build/default/test test/cram/bin
  $ cp "$bin/calc.ml" test/cram/bin/
  $ cp "$bin/pins_both.exe" _build/default/test/
  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null

The run writes one file for each suite:

  $ hashes
  windtrap-HASH-HASH.mutants
  windtrap-HASH-HASH.mutants

The merge has the verdicts of the two suites. The survivor is the mutant
that neither suite pins:

  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b  (2 runs)
        14 │ let shared a b = a + b
  
      2 tests ran this line and none failed:
        pins_both.exe  shared › shared is nonzero
        pins_both.exe  shared › shared is not 99
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_both.exe -- --arm test/cram/bin/calc.ml:14:17:sub
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7%
  [1]

The document gives the suite of each file:

  $ run windtrap mutants --json > /dev/null
  [1]
  $ grep '"suite"' "$bin/out"
      { "name": "pins_both.exe", "path": "default/test/pins_both.exe", "suite": "subs" },
      { "name": "pins_both.exe", "path": "default/test/pins_both.exe", "suite": "adds" } ],

A suite that is renamed leaves its earlier file in the directory. A run
with another name for the second suite writes a third file, and the merge
adds the runs of the survivor:

  $ run env PINS_SECOND=renamed _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null
  $ hashes
  windtrap-HASH-HASH.mutants
  windtrap-HASH-HASH.mutants
  windtrap-HASH-HASH.mutants
  $ run windtrap mutants | grep -e SURVIVED -e '^mutants:'
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b  (3 runs)
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7%

A new build of the executable makes the three files stale. A run of the
two suites that still exist writes their files again, and the merge excludes
the file of the suite that no longer runs. The warning names the file, and
the remedy tells to delete the files of a suite that no longer exists:

  $ chmod u+w _build/default/test/pins_both.exe
  $ printf '\n' >> _build/default/test/pins_both.exe
  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b  (2 runs)
        14 │ let shared a b = a + b
  
      2 tests ran this line and none failed:
        pins_both.exe  shared › shared is nonzero
        pins_both.exe  shared › shared is not 99
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_both.exe -- --arm test/cram/bin/calc.ml:14:17:sub
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7%
  --- stderr
  windtrap: .../windtrap-c71d35810dd15189cb532bf4404b5a67-acca362a48577269b87ef58cd46e2c3a.mutants: not written by the executable now at _build/default/test/pins_both.exe (rebuilt since); excluding it
  windtrap: re-run every suite with its mutants, then merge again; delete the files whose executable or suite no longer exists
    WINDTRAP_MUTATE=1 dune runtest --force --instrument-with ppx_windtrap.mutate
  [1]

The run of a suite under --mutate-skip-killed does not use the stale file
of the suite that no longer runs, and gives no warning:

  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml --mutate-skip-killed | grep -e '^killed elsewhere' -e '^mutants:' -e '^--- stderr' -e warning
  killed elsewhere: 1 mutant, not tested, from the verdict file of default/test/pins_both.exe (1)
  mutants: 1 survived of 3 reached by this suite, 1 killed, 1 never reached, 1 not tested, score 50.0%
  killed elsewhere: 1 mutant, not tested, from the verdict file of default/test/pins_both.exe (1)
  mutants: 1 survived of 3 reached by this suite, 1 killed, 1 never reached, 1 not tested, score 50.0%

A person deletes the file of the suite that no longer runs, and the merge
is complete without a warning:

  $ rm _build/_mutants/windtrap-c71d35810dd15189cb532bf4404b5a67-acca362a48577269b87ef58cd46e2c3a.mutants
  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b  (2 runs)
        14 │ let shared a b = a + b
  
      2 tests ran this line and none failed:
        pins_both.exe  shared › shared is nonzero
        pins_both.exe  shared › shared is not 99
  ──────────────────────────────────────────────────────────
  
  ────────────────────── unstable (2) ──────────────────────
    The source of each mutant did not change, but its verdict did.
    pins_both.exe  test/cram/bin/calc.ml:12:14:sub   survived → killed
    pins_both.exe  test/cram/bin/calc.ml:13:14:add   survived → killed
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_both.exe -- --arm test/cram/bin/calc.ml:14:17:sub
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7%
  [1]

A file at the name of the earlier version is not read, and the merge refuses
it:

  $ printf 'windtrap-mutants-v9\n0\n0\n' > _build/_mutants/windtrap-c71d35810dd15189cb532bf4404b5a67.mutants
  $ run windtrap mutants
  --- stderr
  windtrap: .../windtrap-c71d35810dd15189cb532bf4404b5a67.mutants: not a windtrap verdict file (expected header "windtrap-mutants-v10", found "windtrap-mutants-v9"); files written by other windtrap versions are not readable - delete the stale verdict files, then re-run the mutation tests
  [1]
  $ cd / && rm -rf "$rootA"

An inline runner with two test files

inline_adds.ml pins add and reaches sub. inline_subs.ml pins sub and
reaches add. The partitions run one after the other, in each order, and at
the same time. The merge is the same, and it holds the kill of each file:

  $ rootB=$(cd "$(mktemp -d)" && pwd -P) && cd "$rootB"
  $ mkdir -p _build/default/test test/cram/bin
  $ cp "$bin/calc.ml" test/cram/bin/
  $ cp "$bin/pins_inline.exe" _build/default/test/
  $ part() {
  >   env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" WINDTRAP_COLOR=never WINDTRAP_SLOW_THRESHOLD=0 \
  >     WINDTRAP_MUTATE=test/cram/bin/calc.ml _build/default/test/pins_inline.exe \
  >     inline-test-runner pins -partition "$1"
  > }
  $ part inline_adds.ml > /dev/null
  $ part inline_subs.ml > /dev/null
  $ run windtrap mutants
  ─────────────────── never reached (2) ────────────────────
    2  test/cram/bin/calc.ml   lines 14-15
  ──────────────────────────────────────────────────────────
  
  mutants: 2 reached, 2 killed, 2 never reached, 1 executable, score 100.0%

In the other order:

  $ rm -r _build/_mutants
  $ part inline_subs.ml > /dev/null
  $ part inline_adds.ml > /dev/null
  $ run windtrap mutants > /dev/null
  $ tail -n 1 "$bin/out"
  mutants: 2 reached, 2 killed, 2 never reached, 1 executable, score 100.0%

At the same time:

  $ rm -r _build/_mutants
  $ part inline_adds.ml > "$bin/adds.out" 2>&1 & part inline_subs.ml > "$bin/subs.out" 2>&1 & wait
  $ run windtrap mutants > /dev/null
  $ tail -n 1 "$bin/out"
  mutants: 2 reached, 2 killed, 2 never reached, 1 executable, score 100.0%

The document names the suite of each file, as the library and the test
file:

  $ run windtrap mutants --json > /dev/null
  $ grep '"suite"' "$bin/out"
      { "name": "pins_inline.exe", "path": "default/test/pins_inline.exe", "suite": "pins/inline_adds.ml" },
      { "name": "pins_inline.exe", "path": "default/test/pins_inline.exe", "suite": "pins/inline_subs.ml" } ],
  $ cd / && rm -rf "$rootB"
