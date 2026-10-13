(* [same operands]: [a && a] and [a || a] are [a] when the operand gives
   one value each time and does nothing else. A call can do something
   else, so [f x && f x] keeps its mutant. *)

type r = { mutable ok : bool }

let both a = a && a
let either a = a || a
let field r = r.ok && r.ok
let calls f x = f x && f x
let other a b = a && b
