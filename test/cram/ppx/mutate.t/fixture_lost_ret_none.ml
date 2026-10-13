(* A file that declares the constructor [None] alone also loses [ret]: a
   [none] guard would give the [None] of the file in place of the [Some n]
   of the predefined option. *)

type outcome = None | Other

let found n = Some n
let push x xs = x :: xs
let sum a b = a + b
