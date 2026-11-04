Each suite of an executable has its own verdict file, and `windtrap
mutants` merges the files of all suites. Two cases write the files of
more than one suite: a main that calls `Windtrap.run` with two suite names
(pins_both.exe), and the inline-test runner of a library with two test
files (pins_inline.exe), whose partitions dune runs at the same time.
POSIX only: the loop forks.

The executables run from scratch build directories, where they write
their verdict files, and the source they recorded is planted where it was
recorded. --mutate scopes each loop to calc.ml's mutants, because under
--instrument-with the executables also link an instrumented core.

  $ bin=$PWD
  $ run() {
  >   env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" WINDTRAP_COLOR=never WINDTRAP_SLOW_THRESHOLD=0 "$@" \
  >     > "$bin/out" 2> "$bin/err"
  >   code=$?; cat "$bin/out"
  >   if [ -s "$bin/err" ]; then
  >     echo '--- stderr'
  >     sed -E -e 's#[^ ()]*[/\\]([^/\\ ()]+\.mutants)#.../\1#g' -e 's/[0-9a-f]{32}/HASH/g' "$bin/err"
  >   fi
  >   return $code
  > }
  $ hashes() { ls _build/_mutants | sed -E 's/[0-9a-f]{32}/HASH/g'; }
  $ suites() { for f in _build/_mutants/*.mutants; do sed -n 3p "$f"; done | sort; }
  $ file_of() {
  >   for f in _build/_mutants/*.mutants; do
  >     [ "$(sed -n 3p "$f")" = "suite ${#1} $1" ] && echo "$f"
  >   done
  > }

A main with two suites

pins_both.exe calls `Windtrap.run` for the suite adds, which pins add, and
for the suite subs, which pins sub. Each suite reaches the mutant that the
other suite pins, and the two reach shared:

  $ rootA=$(cd "$(mktemp -d)" && pwd -P) && cd "$rootA"
  $ mkdir -p _build/default/test test/cram/bin
  $ cp "$bin/calc.ml" test/cram/bin/
  $ cp "$bin/pins_both.exe" _build/default/test/

A run whose selection narrows the two suites, with no earlier file, writes
a refused file for each suite. The merge names the two suites. The second
row does not count again the mutants that the first row counts, and the
outcome line counts suites:

  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml -f shared > /dev/null
  $ run windtrap mutants
  ──────────────── not mutation-tested (2) ─────────────────
    pins_both.exe (suite subs)  4 mutants unknown: its selection narrowed the suite, so it saved no verdict: run it whole
    pins_both.exe (suite adds)  no other mutant unknown: its selection narrowed the suite, so it saved no verdict: run it whole
  ──────────────────────────────────────────────────────────
  
  mutants: 4 reached, 4 unknown, 1 executable, 2 suites not mutation-tested
  [1]
  $ rm -r _build/_mutants

A refused row with no earlier row counts 0 when another suite kills its
mutants. Here the whole run of adds kills the mutant on line 12, and a
narrowed run of subs writes a refused file:

  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null
  $ rm "$(file_of subs)"
  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml -f add > /dev/null
  $ run windtrap mutants --lines test/cram/bin/calc.ml:12-12
  ──────────────── not mutation-tested (1) ─────────────────
    pins_both.exe (suite subs)  0 mutants unknown: its selection narrowed the suite, so it saved no verdict: run it whole
  ──────────────────────────────────────────────────────────
  
  mutants: 1 reached, 1 killed, 1 executable, 1 suite not mutation-tested, score 100.0% (1/1)
  [1]
  $ rm -r _build/_mutants

A run of the whole suites:

  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null

The run writes one file for each suite, and each file records its suite:

  $ hashes
  windtrap-HASH-HASH.mutants
  windtrap-HASH-HASH.mutants
  $ suites
  suite 4 adds
  suite 4 subs

The merge has the verdicts of the two suites, and counts one executable.
The survivor is the mutant that neither suite pins:

  $ run windtrap mutants
  ───────────────────── survivors (1) ──────────────────────
  File "test/cram/bin/calc.ml", line 14, characters 17-22:
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b
        14 │ let shared a b = a + b
  
      2 tests ran this line and none failed:
        pins_both.exe  shared › shared is nonzero
        pins_both.exe  shared › shared is not 99
  ──────────────────────────────────────────────────────────
  
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_both.exe -- --arm test/cram/bin/calc.ml:14:17:sub
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7% (2/3)
  [1]

A suite that is renamed leaves its earlier file in the directory. A run
with another name for the second suite writes a third file. In this run
the second suite also pins shared. The merge reads the third file, because
the same build wrote it, and the kill of shared removes the survivor:

  $ run env PINS_SECOND=renamed _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null
  $ suites
  suite 4 adds
  suite 4 subs
  suite 7 renamed
  $ run windtrap mutants
  ─────────────────── never reached (1) ────────────────────
    1  test/cram/bin/calc.ml   line 15
  ──────────────────────────────────────────────────────────
  
  mutants: 3 reached, 3 killed, 1 never reached, 1 executable, score 100.0% (3/3)

A new build of the executable makes the three files stale. A run of the
two suites that still exist writes their files again, and the merge
excludes the file of the suite that no longer runs. The warning names the
file, and the remedy tells to delete the files of a suite that no longer
exists:

  $ chmod u+w _build/default/test/pins_both.exe
  $ printf '\n' >> _build/default/test/pins_both.exe
  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml > /dev/null
  $ run windtrap mutants | grep -e '^mutants:' -e '^--- stderr' -e '^windtrap:'
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7% (2/3)
  --- stderr
  windtrap: .../windtrap-HASH-HASH.mutants: not written by the executable now at _build/default/test/pins_both.exe (rebuilt since); excluding it
  windtrap: re-run every suite with its mutants, then merge again; delete the files whose executable or suite no longer exists

The excluded file is the file of the renamed suite:

  $ grep -c "$(basename "$(file_of renamed)"): not written" "$bin/err"
  1

A person deletes the file of the suite that no longer runs, and the merge
is complete without a warning:

  $ rm "$(file_of renamed)"
  $ run windtrap mutants | grep -e '^mutants:' -e '^--- stderr'
  mutants: 1 survived of 3 reached, 2 killed, 1 never reached, 1 executable, score 66.7% (2/3)

The loop never reads a file at the name of the earlier version, and the
merge refuses it:

  $ old=$(file_of adds | sed -E 's/-[0-9a-f]{32}\.mutants$/.mutants/')
  $ printf 'windtrap-mutants-v5\ntested\n0\n' > "$old"
  $ run _build/default/test/pins_both.exe --mutate=test/cram/bin/calc.ml | grep -e '^mutants:' -e '^--- stderr'
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3% (1/3)
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3% (1/3)
  $ run windtrap mutants
  --- stderr
  windtrap: .../windtrap-HASH.mutants: not a windtrap verdict file (expected header "windtrap-mutants-v13", found "windtrap-mutants-v5"); files written by other windtrap versions are not readable - delete the stale verdict files, then re-run the mutation tests
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
  $ suites
  suite 19 pins/inline_adds.ml
  suite 19 pins/inline_subs.ml
  $ run windtrap mutants
  ─────────────────── never reached (2) ────────────────────
    2  test/cram/bin/calc.ml   lines 14-15
  ──────────────────────────────────────────────────────────
  
  mutants: 2 reached, 2 killed, 2 never reached, 1 executable, score 100.0% (2/2)

In the other order:

  $ rm -r _build/_mutants
  $ part inline_subs.ml > /dev/null
  $ part inline_adds.ml > /dev/null
  $ run windtrap mutants > /dev/null
  $ tail -n 1 "$bin/out"
  mutants: 2 reached, 2 killed, 2 never reached, 1 executable, score 100.0% (2/2)

At the same time:

  $ rm -r _build/_mutants
  $ part inline_adds.ml > "$bin/adds.out" 2>&1 & part inline_subs.ml > "$bin/subs.out" 2>&1 & wait
  $ run windtrap mutants > /dev/null
  $ tail -n 1 "$bin/out"
  mutants: 2 reached, 2 killed, 2 never reached, 1 executable, score 100.0% (2/2)
  $ cd / && rm -rf "$rootB"
