(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Compiled with the mutation instrumenter unconditionally, under the
   warnings the generated preamble is most likely to trip: an unused
   [open] (33), a field resolved by type-directed disambiguation (42),
   and an unused module (60). test/cram/ppx/mutate.t pins what the
   instrumenter emits; this module pins that what it emits is well-typed
   OCaml. *)

let pick flag x y = if flag then x else y

let drain ready step =
  while ready () do
    step ()
  done

let classify p x = match x with y when p y -> "yes" | _ -> "no"
let below a b = if a < b then 1 else 0
let at_most a b = if a <= b then 1 else 0
let above a b = if a > b then 1 else 0
let at_least a b = match a with _ when a >= b -> 1 | _ -> 0
let same a b = if a = b then 1 else 0
let differs a b = if a <> b then 1 else 0
let window lo hi x = x >= lo && x <= hi
let both a b = a && b
let either a b = a || b
let chain a b c = a && b && c
let sum a b = a + b
let diff a b = a - b
let fsum a b = a +. b
let fdiff a b = a -. b
let origin = 1 + 2
let scaled a b = (a + b) * 2
let rec search p = function [] -> false | x :: rest -> p x || search p rest

let countdown n =
  let r = ref n in
  while !r > 0 do
    decr r
  done;
  !r

let tagged a b = match a with _ when a = b -> "same" | _ -> "differs"
let checked a b = assert (a < b)
let thunk a b = lazy (fun () -> a + b)
let forced a b = lazy (a + b)

let cap want =
  if (want > 16) [@mutate off "both arms yield 16 at the boundary"] then want
  else 16

let untouched a b = a + b [@@mutate off]

(* [arm] on the cases of a GADT match, of an or-pattern, of an exception
   case and of a handler. No [arm] in a match with a refutation case, and
   none on a case that matches a value and an exception. Each match with an
   [arm] guard is partial for the compiler, and warning 8 is fatal here. *)
type _ shape = Int : int shape | Bool : bool shape
type (_, _) eq = Refl : ('a, 'a) eq

let show_shape : type a. a shape -> a -> string =
 fun shape x ->
  match shape with Int -> string_of_int x | Bool -> string_of_bool x

(* The refutation case after the other cases is a wildcard, which warning 4
   calls fragile in the source too. *)
let refuted (x : (int, int) eq option) =
  match x with None -> 0 | Some Refl -> 1 | _ -> .
[@@ocaml.warning "-4"]

let either_side x = match x with `A n, _ | _, `A n -> n | _ -> 0
let found f = match f () with v -> v | exception Not_found -> 0

let found_or_none f =
  match f () with Some v -> v | None | (exception Not_found) -> 0

(* An exception pattern under a local open or a type constraint makes its
   case match a value and an exception all the same. *)
module Raised = struct
  exception Gone
end

let opened_or_none f =
  match f () with Some v -> v | None | Raised.((exception Gone)) -> 0

let constrained_or_none f =
  match f () with
  | Some v -> v
  | None | ((exception Not_found) : int option) -> 0

let handled f = try f () with Not_found -> 0

(* Warning 57 reads only the earlier cases that have no guard. The [arm]
   guard on [A, A] thus makes [x] ambiguous in the next case, of a match, of
   a function and of a handler, and warning 57 is fatal here. *)
type letter = A | B | C

exception Pair of letter * letter

let ambiguous p =
  match p with A, A -> 0 | (A, x | x, A) when x = B -> 1 | _ -> 2
[@@ocaml.warning "-4"]

let ambiguous_function = function
  | A, A -> 0
  | (A, x | x, A) when x = B -> 1
  | _ -> 2
[@@ocaml.warning "-4"]

let ambiguous_handler f =
  try f () with Pair (A, A) -> 0 | (Pair (A, x) | Pair (x, A)) when x = B -> 1

(* A warning attribute of the user on the node turns warnings 8 and 57 on
   again. The compiler applies the last attribute of a node first, so the
   generated attribute must come first to apply last. *)
let pinned x = (match x with 0 -> 1 | _ -> 2) [@ocaml.warning "+a"]
let pinned_function = (function 0 -> 1 | _ -> 2) [@ocaml.warning "+8"]

let pinned_handler f =
  (try f () with
  | Pair (A, A) -> 0
  | (Pair (A, x) | Pair (x, A)) when x = B -> 1)
  [@ocaml.warning "+57"]

(* After parameters, the parser puts the attributes of [function] on its
   cases, and the compiler applies them in an inner scope. *)
let pinned_cases x = function[@ocaml.warning "+8"] 0 -> x | _ -> 2

(* The dismissed cases cover every value, so without more guards the match
   is total for the type-checker. After the [arm] guard fails, the compiled
   match reads the mutable field again, and finds the match partial (74). No
   attribute disables warning 74, because the compiler gives it after the
   type-checker. *)
type cell = { tag : bool; mutable value : int option }

let degraded x =
  match x with
  | ({ tag = false; value = _ } [@mutate off "covered"]) -> 0
  | ({ tag = _; value = None } [@mutate off "covered"]) -> 1
  | { tag = _; value = Some 0 } -> 2
  | ({ tag = true; value = Some y } [@mutate off "covered"]) -> y

(* [call] on a statement and on [let () = e]. *)
let bump r =
  incr r;
  !r

let bump_bound r =
  let () = incr r in
  !r

(* A record field beside the generated table: the preamble's fields are
   all qualified, so warning 42 stays silent. *)
type point = { line : int; col : int }

let point line col = { line; col }
let describe p = p.line + p.col
