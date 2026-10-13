(* A file that declares the constructor [true] alone also loses [arm]. *)

type answer = true

let size n = match n with 0 -> "none" | _ -> "some"
let sum a b = a + b
