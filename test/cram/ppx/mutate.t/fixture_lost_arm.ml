(* A file that declares a constructor [true] or [false] loses [arm]: the
   guard of a case names the constructors where [bool] is expected, and
   warning 42 then reports them. The other families stay. *)

type answer = false | true

let size n = match n with 0 -> "none" | _ -> "some"
let sum a b = a + b
