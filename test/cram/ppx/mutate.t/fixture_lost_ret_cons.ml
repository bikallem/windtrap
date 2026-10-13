(* A file that declares the constructor [(::)] alone also loses [ret]: a
   [tail] guard would give the [string] [s] in place of the [pair] [n :: s]. *)

type pair = ( :: ) of int * string

let pair n s = n :: s
let found n = Some n
let sum a b = a + b
