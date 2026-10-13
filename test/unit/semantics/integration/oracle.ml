(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The behaviour battery. A golden proves the instrumenter emits what it
   emits; it cannot prove that what it emits MEANS the mutant the report
   names. This module is the population that check runs against.

   Every function here has a rendering unique within the file, so a test
   can name its mutant by (rewrite, before) and arm exactly that one -
   and so the [before] and [after] strings in the report are themselves
   under test, since a mutant whose rendering drifts stops being found.

   Nothing here is called by anything else: the whole point is that its
   observable behaviour is read once with nothing armed and once with one
   mutant armed, and the two must differ in exactly the way the [after]
   text claims. *)

(* [neg]. *)
let neg_pick flag = if flag then 1 else 0

(* [cmp], the four orderings, whose armed arms swap their operands, and
   the two equalities, whose armed arms do not. Each is exercised at the
   boundary where the original and the mutant disagree. *)
let cmp_lt a b = if a < b then 1 else 0
let cmp_le a b = if a <= b then 1 else 0
let cmp_gt a b = if a > b then 1 else 0
let cmp_ge a b = if a >= b then 1 else 0
let cmp_eq a b = if a = b then 1 else 0
let cmp_ne a b = if a <> b then 1 else 0

(* [con], both connectives, whose four-row truth tables the test walks. *)
let con_and a b = a && b
let con_or a b = a || b

(* [ari], the four operators. *)
let ari_add a b = a + b
let ari_sub a b = a - b
let ari_fadd a b = a +. b
let ari_fsub a b = a -. b

(* [arm]: a dropped case gives its value to the next case that matches it,
   and a dropped handler lets its exception go on. *)
let arm_pick x = match x with 0 -> "zero" | _ -> "other"
let arm_guarded x = match x with n when n > 9 -> "big" | _ -> "small"
let arm_handler f = try f () with Not_found -> "caught"

(* [call]: a skipped call has no effect, in a sequence and in
   [let () = e]. *)
let call_statement count =
  incr count;
  !count

let call_bound total =
  let () = incr total in
  !total

(* [lit], one literal of each kind, in a library built with [-lit]. An
   integer becomes its successor, a float zero or one, and a boolean the
   other one. *)
let lit_int () = 41
let lit_negative () = -1
let lit_zero_int64 () = 0L
let lit_int32 () = 7l
let lit_nativeint () = 3n
let lit_float () = 2.5
let lit_zero_float () = 0.
let lit_bool () = true

(* [ret]: [Some x] gives [None], and [h :: t] gives [t]. *)
let ret_some x = Some x
let ret_cons h t = h :: t

(* Evaluation order, multiplicity and short-circuiting. [note] records
   that it ran and returns its argument, so a trace says exactly which
   operands were evaluated and in which order. *)

let trace : string list ref = ref []

let record () =
  let seen = List.rev !trace in
  trace := [];
  seen

let note tag v =
  trace := tag :: !trace;
  v

(* The two encodings that lift their operands into a tuple binding must
   evaluate each exactly once and right to left, armed or disarmed. *)
let cmp_order a b = if note "l" a < note "r" b then 1 else 0
let ari_order a b = note "l" a + note "r" b

(* The connective's right operand must be evaluated exactly when the
   connective in force - the original disarmed, the mutant armed - says
   it is, and never twice. *)
let con_short a b = a && note "r" b

(* A [ret] mutant evaluates no more than its [after] text: armed, [Some e]
   does not evaluate [e], and [h :: t] evaluates [t] alone. *)
let ret_some_order x = Some (note "e" x)
let ret_cons_order h t = note "h" h :: note "t" t
