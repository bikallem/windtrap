(* [same branches]: when the two branches of an [if] are the same, the
   value of the condition changes nothing, so its [neg] or [cmp] mutant is
   filtered, as that of [<] or [=]. The sites inside the condition and the
   branches keep their mutants. A [con] mutant also changes which operand
   runs, a location gives two copies two values, and a string keeps its
   blanks. *)

let flag c x = if c then x + 1 else x + 1
let order a b x = if a < b then x else x
let inner f x = if f (x + 1) then 0 else 0
let both a b x = if a && b then x else x
let other c = if c then 1 else 2
let line c = if c then __LINE__ else __LINE__
let blanks c = if c then "a  b" else "a b"
let partial c x =
  if c then (match x with Some y -> y) else match x with Some y -> y
let equal a b x = if a = b then x else x
