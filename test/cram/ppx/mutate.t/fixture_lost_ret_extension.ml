(* An extension constructor [None] loses [none] and [tail] as a declared one
   does. *)

type e = ..
type e += None

let found n = Some n
let sum a b = a + b
