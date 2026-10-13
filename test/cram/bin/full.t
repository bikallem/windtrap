When standard output refuses the text of `windtrap mutants`, the reader
has only a part of the report or of the document. The command then says
why on standard error and exits 1, and it runs no gate. /dev/full refuses
each write, as a full disk does.

  $ bin=$PWD
  $ root=$(cd "$(mktemp -d)" && pwd -P) && cd "$root"
  $ mkdir lib
  $ printf 'let add a b = a + b\nlet sub a b = a - b\n' > lib/calc.ml
  $ "$bin/mkdata.exe" mutants _build/_mutants/a.mutants \
  >   'lib/calc.ml:1:14:add:a + b:a - b=killed' \
  >   'lib/calc.ml:2:14:sub:a - b:a + b=survived:calc/subtracts'
  $ full() { env -i PATH="$PATH" WINDTRAP_COLOR=never "$@" > /dev/full; }

The score is 50%, so a gate of 10% is met, but the command fails:

  $ full windtrap mutants
  windtrap: cannot write to standard output: No space left on device
  [1]
  $ full windtrap mutants --min-score 10
  windtrap: cannot write to standard output: No space left on device
  [1]
  $ full windtrap mutants --json
  windtrap: cannot write to standard output: No space left on device
  [1]
  $ full windtrap mutants --json --min-score 10
  windtrap: cannot write to standard output: No space left on device
  [1]
