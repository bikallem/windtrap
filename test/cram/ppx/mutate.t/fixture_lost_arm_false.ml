(* A file that declares the constructor [false] alone also loses [arm]. *)

type answer = false

let size n = match n with 0 -> "none" | _ -> "some"
let sum a b = a + b
