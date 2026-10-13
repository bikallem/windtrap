(* A file that declares a constructor [Some], [None] or [(::)] loses [ret]:
   a [none] guard would give the predefined [None] in place of the [Some n]
   of the file. *)

type found = Some of int | Missing

let found n = Some n
let push x xs = x :: xs
