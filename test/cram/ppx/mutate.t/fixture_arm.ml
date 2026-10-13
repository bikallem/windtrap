(* [arm] drops each case of a [match], a [function] and a [try]. A case
   without a guard gets [if armed then false else true], and a case with a
   guard runs the armed flag before it. A match with an [arm] guard allows a
   partial match. The arm site comes before the sites of its case. *)

let apply op a b =
  match op with
  | `Add -> a + b
  | `Sub when a > b -> a - b
  | `Sub | `Mul -> 0

let rec length = function [] -> 0 | _ :: rest -> 1 + length rest
let handle f = try f () with Not_found -> 0 | Exit -> 1

(* An exception case is a site, and the one case that a value reaches is
   not: without it, every value raises. *)
let fallback f = match f () with v -> v | exception Not_found -> 0
let only x = match x with Some y -> y

(* The compiler refuses a guard on a case that matches a value and an
   exception. *)
let mixed f = match f () with Some y -> y | None | (exception Not_found) -> 0

(* A refutation case fails to type when a case before it has a guard, so
   its match has no site. *)
type (_, _) eq = Refl : ('a, 'a) eq

let refuted (x : (int, int) eq option) =
  match x with None -> 0 | Some Refl -> 1 | _ -> .

(* [[@mutate off]] on a pattern dismisses the arm of its case alone, and on
   a match it leaves the whole match as written. *)
let kept x = match x with (0 [@mutate off "zero is unused"]) -> 1 + x | _ -> x
let hidden x = (match x with 0 -> 1 | _ -> x + 1) [@mutate off]

(* An exception pattern under a local open or a type constraint is one all
   the same. The first case of [opened] is thus its one site, and the first
   case of [constrained] is the one case that a value reaches. *)
module M = struct
  exception E
end

let opened f = match f () with Some y -> y | None | M.(exception E) -> 0
let constrained f = match f () with y -> y | ((exception Not_found) : int) -> 0

(* An or-pattern or a tuple takes the attribute on the whole pattern, in
   brackets. *)
let either x =
  match x with (`A | `B) [@mutate off "the two give one result"] -> 1 | `C -> 0

(* The default argument of a [function] with cases keeps its sites. *)
let pick ?(d = 1 + 2) = function 0 -> d | _ -> 1

(* The scrutinee of a match and the body of a try keep their sites. *)
let scrutinized a b = match a + b with 0 -> 1 | _ -> 2
let tried f a b = try f (a - b) with Not_found -> 0 | Exit -> 1

(* The guard [true] on the other cases serves a match or a function alone.
   A dismissed handler of a try thus keeps no guard. *)
let excused f =
  try f () with (Not_found [@mutate off "never raised"]) -> 0 | Exit -> 1
