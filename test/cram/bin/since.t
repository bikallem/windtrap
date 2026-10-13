A run under --mutate-since tests only the mutants on the lines that
changed since a git revision, and `windtrap mutants --since` reports only
those. The project is a git repository in a scratch directory, which
holds the source that pins_add.exe recorded where it recorded it. The
executable runs from a build directory of the project, where it writes
its verdict file. --mutate scopes each loop to calc.ml's mutants, since
under --instrument-with the executable also links an instrumented core.
POSIX only: the loop forks.

  $ bin=$PWD
  $ root=$(cd "$(mktemp -d)" && pwd -P) && cd "$root"
  $ run() {
  >   env -i PATH="$PATH" HOME="$root" TMPDIR="${TMPDIR:-/tmp}" GIT_CONFIG_NOSYSTEM=1 \
  >     WINDTRAP_COLOR=never WINDTRAP_SLOW_THRESHOLD=0 "$@" > "$bin/out" 2> "$bin/err"
  >   code=$?; sed -E 's/ in [0-9.]+m?s\./ in DURATION./' "$bin/out"
  >   if [ -s "$bin/err" ]; then echo '--- stderr'; cat "$bin/err"; fi
  >   return $code
  > }
  $ git() {
  >   env -i PATH="$PATH" HOME="$root" GIT_CONFIG_NOSYSTEM=1 git -c user.name=windtrap \
  >     -c user.email=windtrap@example.com -c init.defaultBranch=main "$@"
  > }
  $ mutate() {
  >   run _build/default/test/pins_add.exe --mutate=test/cram/bin/calc.ml "$@"
  > }
  $ mkdir -p _build/default/test test/cram/bin
  $ cp "$bin/pins_add.exe" _build/default/test/
  $ printf '_build/\n' > .gitignore
  $ git init -q && git add .gitignore && git commit -q -m ignore

A file that git does not track changed on every line. Thus a run since
the first commit tests each mutant of calc.ml:

  $ cp "$bin/calc.ml" test/cram/bin/
  $ mutate --mutate-since=HEAD | grep -e SURVIVED -e '^mutants:'
    SURVIVED  test/cram/bin/calc.ml:13:14:add  a - b → a + b
    SURVIVED  test/cram/bin/calc.ml:14:17:sub  a + b → a - b
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3%

Once calc.ml is committed, a change to one line puts only the mutant of
that line in scope. The run tests it, and the report shows the line as
the work tree has it:

  $ git add test/cram/bin/calc.ml && git commit -q -m calc
  $ sed 's/^let sub a b = a - b$/let sub a b = a - b (* changed *)/' test/cram/bin/calc.ml > calc.ml.new
  $ mv calc.ml.new test/cram/bin/calc.ml
  $ git diff --stat
   test/cram/bin/calc.ml | 2 +-
   1 file changed, 1 insertion(+), 1 deletion(-)
  $ mutate --mutate-since=HEAD
  pins_add: 5 passed in DURATION.
  
  ─────────────────────── survivors ────────────────────────
    SURVIVED  test/cram/bin/calc.ml:13:14:add  a - b → a + b
        13 │ let sub a b = a - b (* changed *)
  
      1 test ran this line and did not fail:
        sub › sub is nonzero  test/cram/bin/pins_add.ml:26
  ──────────────────────────────────────────────────────────
  
  reproduce: _build/default/test/pins_add.exe --arm test/cram/bin/calc.ml:13:14:add
  mutants: 1 survived of 1 reached by this suite, score 0.0%

The run keeps the verdicts of the other lines that the same build wrote,
and the merge reports each of them:

  $ run windtrap mutants | tail -n 1
  mutants: 2 survived of 3 reached, 1 killed, 1 never reached, 1 executable, score 33.3%

`windtrap mutants --since` reports only the mutants on the changed lines,
and gates on them:

  $ run windtrap mutants --since HEAD
  ───────────────────── survivors (1) ──────────────────────
    SURVIVED  test/cram/bin/calc.ml:13:14:add  a - b → a + b
        13 │ let sub a b = a - b (* changed *)
  
      1 test ran this line and did not fail:
        pins_add.exe  sub › sub is nonzero
  ──────────────────────────────────────────────────────────
  
  reproduce: dune exec --instrument-with ppx_windtrap.mutate test/pins_add.exe -- --arm test/cram/bin/calc.ml:13:14:add
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%
  [1]
  $ run windtrap mutants --since=HEAD --min-score 0 --json
  { "version": 1,
    "summary": { "reached": 1, "killed": 0, "survived": 1,
      "not_evaluated": 0, "outside_tests": 0, "unreached": 0,
      "score": 0.00 },
    "executables": [
      { "name": "pins_add.exe", "path": "default/test/pins_add.exe" } ],
    "mutants": [
      { "id": "test/cram/bin/calc.ml:13:14:add",
        "file": "test/cram/bin/calc.ml", "line": 13, "col": 14, "rewrite": "add",
        "before": "a - b", "after": "a + b",
        "verdict": "survived",
        "tests": [
          { "executable": 0, "test": ["sub", "sub is nonzero"] } ] } ] }
  --- stderr
  windtrap: mutants: 1 survived of 1 reached, 1 executable, score 0.0%, minimum 0%: ok
  $ run windtrap mutants --since HEAD~1 | tail -n 1
  mutants: 2 survived of 3 reached, 1 killed, 1 never reached, 1 executable, score 33.3%

A verdict file below a build directory has the parent of that directory
as its root, also when a PATH argument gives it. Git runs in that root,
so the command gives the same lines from a subdirectory:

  $ cd test/cram
  $ run windtrap mutants --since HEAD ../../_build/_mutants | tail -n 1
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%

A verdict file outside a build directory and outside _windtrap/mutants
has the current directory as its root. When that directory holds no
file of its mutants, no mutant can be on a changed line, and an empty
report would pass the gate. Thus the command stops:

  $ mkdir "$root/copy" && cp "$root"/_build/_mutants/*.mutants "$root/copy/"
  $ run windtrap mutants --since HEAD --min-score 0 ../../copy
  --- stderr
  windtrap: --since HEAD: no file of the mutants of ../../copy/windtrap-68af57029dba11636bff61ba3ab2ea94.mutants is under ".", where git runs; run windtrap mutants in the project root, or give the verdict files in its build directory
  [1]
  $ cd "$root"
  $ run windtrap mutants --since HEAD copy | tail -n 1
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%
  $ rm -r copy

An executable outside any build directory writes its verdict file under
_windtrap/mutants in its working directory. The parent of _windtrap is
the root of that file, also when the command runs in a subdirectory:

  $ mkdir standalone && cp "$bin/pins_add.exe" standalone/
  $ run standalone/pins_add.exe --mutate=test/cram/bin/calc.ml | tail -n 1
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3%
  $ cd test/cram
  $ run windtrap mutants --since HEAD ../../_windtrap/mutants | tail -n 1
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%
  $ cd "$root"

The command filters each verdict file, and git runs once for each root.
Here a wrapper of git writes the subcommand of each git command to a
log. The two files below the root have one root, so the log has the
subcommands of one root:

  $ mkdir "$bin/wrap"
  $ printf '#!/bin/sh\necho "$3" >> "%s/git.log"\nPATH="%s" exec git "$@"\n' \
  >   "$bin" "$PATH" > "$bin/wrap/git" && chmod +x "$bin/wrap/git"
  $ run env PATH="$bin/wrap:$PATH" windtrap mutants --since HEAD | tail -n 1
  mutants: 1 survived of 1 reached, 2 executables, score 0.0%
  $ cat "$bin/git.log" && rm "$bin/git.log"
  rev-parse
  rev-parse
  diff
  ls-files

Git does not track the files of other/, so each line of its calc.ml
changed. Its executable is a second one, and other/ is a second root.
Thus the log has the subcommands of two roots, and each file has the
lines of its own root:

  $ mkdir -p other/test/cram/bin && cp test/cram/bin/calc.ml other/test/cram/bin/
  $ cp "$bin/pins_add.exe" other/ && cd other
  $ run ./pins_add.exe --mutate=test/cram/bin/calc.ml | tail -n 1
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3%
  $ cd "$root"
  $ run env PATH="$bin/wrap:$PATH" windtrap mutants --since HEAD \
  >   _windtrap/mutants other/_windtrap/mutants | tail -n 1
  mutants: 2 survived of 3 reached, 1 killed, 1 never reached, 2 executables, score 33.3%
  $ cat "$bin/git.log" && rm "$bin/git.log"
  rev-parse
  rev-parse
  diff
  ls-files
  rev-parse
  rev-parse
  diff
  ls-files
  $ rm -r standalone other _windtrap

A commit leaves no changed line. A run under WINDTRAP_MUTATE then has no
mutant to test, and runs as usual. On the command line, the same run is
refused. The two say so with a prefix and without one:

  $ git commit -q -a -m changed
  $ run env WINDTRAP_MUTATE=test/cram/bin/calc.ml WINDTRAP_MUTATE_SINCE=HEAD \
  >   _build/default/test/pins_add.exe
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: WINDTRAP_MUTATE is set, but no mutant of this executable's catalogue under test/cram/bin/calc.ml is on a line that changed since HEAD, so the suite runs without mutation
  $ mutate --mutate-since=HEAD
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: --mutate=test/cram/bin/calc.ml and --mutate-since=HEAD leave no mutant in this executable's catalogue: no mutation site under the prefix is on a line that changed since HEAD
  [1]
  $ run env WINDTRAP_MUTATE=1 WINDTRAP_MUTATE_SINCE=HEAD _build/default/test/pins_add.exe
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: WINDTRAP_MUTATE is set, but no mutant of this executable's catalogue is on a line that changed since HEAD, so the suite runs without mutation
  $ run _build/default/test/pins_add.exe --mutate --mutate-since=HEAD
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: --mutate-since=HEAD leaves no mutant in this executable's catalogue: no mutation site is on a line that changed since HEAD
  [1]
  $ mutate --mutate-since=HEAD~1 | tail -n 1
  mutants: 1 survived of 1 reached by this suite, score 0.0%
  $ run windtrap mutants --since HEAD | tail -n 1
  mutants: 0 reached, 1 executable

A revision can name a commit by a text of its message. Here :/calc
names the commit "calc", which is HEAD~1:

  $ mutate --mutate-since=:/calc | tail -n 1
  mutants: 1 survived of 1 reached by this suite, score 0.0%
  $ run windtrap mutants --since :/calc | tail -n 1
  mutants: 1 survived of 1 reached, 1 executable, score 0.0%

A new build has no verdict file. Under WINDTRAP_MUTATE, a run with no
mutant on a changed line writes one, with no verdict of a changed line.
Thus the gate passes on a change that no mutant is on:

  $ rm -r _build/_mutants
  $ run env WINDTRAP_MUTATE=1 WINDTRAP_MUTATE_SINCE=HEAD _build/default/test/pins_add.exe
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: WINDTRAP_MUTATE is set, but no mutant of this executable's catalogue is on a line that changed since HEAD, so the suite runs without mutation
  $ run windtrap mutants --since HEAD --min-score 90
  mutants: 0 reached, 1 executable, score 100.0%, minimum 90%: ok

A revision that names no commit is refused before the dry run, also
under WINDTRAP_MUTATE, and so is one that git would read as an option:

  $ mutate --mutate-since=nope
  --- stderr
  windtrap: --mutate-since=nope: "nope" names no commit
  [1]
  $ run env WINDTRAP_MUTATE=test/cram/bin/calc.ml WINDTRAP_MUTATE_SINCE=nope \
  >   _build/default/test/pins_add.exe
  --- stderr
  windtrap: --mutate-since=nope: "nope" names no commit
  [1]
  $ mutate --mutate-since=-p
  --- stderr
  windtrap: invalid value '-p' for --mutate-since: expected a git revision, which does not start with -
  usage: pins_add.exe [OPTIONS] [PATTERN...]
  [2]
  $ run windtrap mutants --since nope
  --- stderr
  windtrap: --since nope: "nope" names no commit
  [1]
  $ run windtrap mutants --since -p
  --- stderr
  windtrap: invalid value '-p' for --since: expected a git revision, which does not start with -
  usage: windtrap mutants [OPTIONS] [PATH...]
  [2]

Without --mutate or WINDTRAP_MUTATE, a revision tests no mutant. The
run says so on standard error, and runs as usual:

  $ run _build/default/test/pins_add.exe --mutate-since=HEAD
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: --mutate-since gives a revision, but neither --mutate nor WINDTRAP_MUTATE is given, so the suite runs without mutation
  $ run env WINDTRAP_MUTATE_SINCE=HEAD _build/default/test/pins_add.exe
  pins_add: 5 passed in DURATION.
  --- stderr
  windtrap: WINDTRAP_MUTATE_SINCE gives a revision, but neither --mutate nor WINDTRAP_MUTATE is given, so the suite runs without mutation

A run that arms a mutant tests only that mutant, and says nothing about
the revision:

  $ run _build/default/test/pins_add.exe --arm test/cram/bin/calc.ml:13:14:add --mutate-since=HEAD
  mutant test/cram/bin/calc.ml:13:14:add armed: a - b → a + b
  pins_add: 5 passed in DURATION.
  mutant survived: the armed site was evaluated 1 time and no test failed.
  $ run env WINDTRAP_MUTATE_ARM=test/cram/bin/calc.ml:13:14:add WINDTRAP_MUTATE_SINCE=HEAD \
  >   _build/default/test/pins_add.exe
  mutant test/cram/bin/calc.ml:13:14:add armed: a - b → a + b
  pins_add: 5 passed in DURATION.
  mutant survived: the armed site was evaluated 1 time and no test failed.

A project can be in a subdirectory of its git work tree, and the
configuration of the repository can change what git diff prints. Here
the project is proj/, and the configuration removes the prefixes of the
paths, adds color, sets an external diff tool, adds a line at the top of
each converted file and detects renames. It also joins two hunks with
the lines between them, and makes git find each converted file binary.
In the environment, GIT_DIFF_OPTS adds 5 context lines to each hunk:

  $ mkdir -p "$root/repo" && cd "$root/repo"
  $ mkdir -p proj/_build/default/test proj/test/cram/bin
  $ cp "$bin/pins_add.exe" proj/_build/default/test/
  $ cp "$bin/calc.ml" proj/test/cram/bin/
  $ printf '_build/\n' > .gitignore
  $ git init -q && git add . && git commit -q -m calc
  $ printf '#!/bin/sh\nexit 0\n' > .git/ext-diff
  $ printf '#!/bin/sh\necho converted\ncat "$1"\n' > .git/convert
  $ chmod +x .git/ext-diff .git/convert
  $ git config diff.noprefix true
  $ git config color.ui always
  $ git config diff.external "$PWD/.git/ext-diff"
  $ git config diff.converted.textconv "$PWD/.git/convert"
  $ printf '*.ml diff=converted\n' > .git/info/attributes
  $ git config diff.renames true
  $ git config diff.interHunkContext 5
  $ git config diff.converted.binary true
  $ cd proj

A run under --mutate-since writes the verdicts of the changed lines,
and the merge reads the same lines:

  $ sed -e 's/^let sub a b = a - b$/let sub a b = a - b (* changed *)/' \
  >   -e 's/^let never a b = a - b$/let never a b = a - b (* changed *)/' \
  >   test/cram/bin/calc.ml > calc.ml.new
  $ mv calc.ml.new test/cram/bin/calc.ml
  $ run env GIT_DIFF_OPTS=-u5 _build/default/test/pins_add.exe \
  >   --mutate=test/cram/bin/calc.ml --mutate-since=HEAD | grep -e SURVIVED -e '^mutants:'
    SURVIVED  test/cram/bin/calc.ml:13:14:add  a - b → a + b
  mutants: 1 survived of 1 reached by this suite, 1 never reached, score 0.0%
  $ run env GIT_DIFF_OPTS=-u5 windtrap mutants --since HEAD | grep -e SURVIVED -e '^mutants:'
    SURVIVED  test/cram/bin/calc.ml:13:14:add  a - b → a + b
  mutants: 1 survived of 1 reached, 1 never reached, 1 executable, score 0.0%

A file that the work tree renamed is a new file, so each of its lines
changed:

  $ git add -A && git commit -q -m changed
  $ git mv test/cram/bin/calc.ml test/cram/bin/renamed.ml && git commit -q -m renamed
  $ git mv test/cram/bin/renamed.ml test/cram/bin/calc.ml
  $ mutate --mutate-since=HEAD | tail -n 1
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3%
  $ run windtrap mutants --since HEAD | tail -n 1
  mutants: 2 survived of 3 reached, 1 killed, 1 never reached, 1 executable, score 33.3%

The project root must be in a git work tree. Outside one, a run under
--mutate-since stops before the dry run, and so does the merge under
--since. The message ends with the last line that git wrote on standard
error. Here git looks for a repository only in the project root:

  $ outside=$(cd "$(mktemp -d)" && pwd -P) && cd "$outside"
  $ ceiling=$(dirname "$outside")
  $ mkdir -p _build/default/test test/cram/bin
  $ cp "$bin/pins_add.exe" _build/default/test/ && cp "$bin/calc.ml" test/cram/bin/
  $ run env GIT_CEILING_DIRECTORIES="$ceiling" _build/default/test/pins_add.exe \
  >   --mutate=test/cram/bin/calc.ml --mutate-since=HEAD
  --- stderr
  windtrap: --mutate-since=HEAD: git rev-parse failed: fatal: not a git repository (or any of the parent directories): .git
  [1]
  $ mutate | tail -n 1
  mutants: 2 survived of 3 reached by this suite, 1 killed, 1 never reached, score 33.3%
  $ run env GIT_CEILING_DIRECTORIES="$ceiling" windtrap mutants --since HEAD
  --- stderr
  windtrap: --since HEAD: git rev-parse failed: fatal: not a git repository (or any of the parent directories): .git
  [1]

The scratch projects leave with the session:

  $ cd "$bin" && rm -rf "$root" "$outside"
