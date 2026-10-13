(* [zero operand]: [x + 0] and [x - 0] are equal on every [int]. A float
   zero filters nothing, because [-0. +. 0.] is [0.] and [-0. -. 0.] is
   [-0.]. A filtered site ends the chain of its operator, so [a + b] keeps
   its mutant. *)

let plus x = x + 0
let minus x = x - 0
let hex x = x + 0x0
let left x = 0 + x
let fplus x = x +. 0.
let chain a b = a + b + 0
