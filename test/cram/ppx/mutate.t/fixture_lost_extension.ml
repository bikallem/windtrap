(* An extension constructor loses its family as a declared one does: [()]
   that of [call], [true] or [false] that of [arm], and [None] that of
   [ret]. *)

type e = ..
type e += () | false | true | None

let run f x =
  f x;
  match x with 0 -> "none" | _ -> "some"

let found n = Some n
