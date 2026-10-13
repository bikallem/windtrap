(* An extension constructor loses its family as a declared one does: [()]
   that of [call], and [true] or [false] that of [arm]. *)

type e = ..
type e += () | false | true

let run f x =
  f x;
  match x with 0 -> "none" | _ -> "some"
