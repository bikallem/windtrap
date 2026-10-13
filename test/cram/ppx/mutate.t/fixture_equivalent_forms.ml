(* The forms that each filter reads. [true] and a type constraint give one
   value each time. A location gives two copies two values, and so does a
   [match] or a [function] whose guard can fail. A pattern that cannot fail
   is [_], a name, [()], or a tuple, a constraint or an alias of such
   patterns. A constrained [_] catches all. A case that binds a name by an
   alias or a module keeps its mutant. *)

let constructor () = true && true
let constrained a = (a : bool) || (a : bool)
let pos c = if c then __POS__ else __POS__
let loc_of c x = if c then __LOC_OF__ x else __LOC_OF__ x
let line_of c x = if c then __LINE_OF__ x else __LINE_OF__ x
let pos_of c x = if c then __POS_OF__ x else __POS_OF__ x

let guarded c x =
  if c then match x with y when y > 0 -> y else match x with y when y > 0 -> y

let cases c =
  if c then function y when y > 0 -> y else function y when y > 0 -> y

let tuple c = if c then fun (a, b) -> a + b else fun (a, b) -> a + b
let typed c = if c then fun (a : int) -> a else fun (a : int) -> a
let alias c = if c then fun (_ as a) -> a else fun (_ as a) -> a
let unit c = if c then fun () -> 0 else fun () -> 0
let any = function `A -> 0 | (_ : [ `A | `B ]) -> 0
let named = function `A as _v -> 0 | _ -> 0
let packed = function (module M : S) -> 0 | _ -> 0
