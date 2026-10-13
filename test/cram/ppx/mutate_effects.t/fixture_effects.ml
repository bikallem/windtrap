(* ppxlib encodes an effect case as an extension pattern. An effect case
   matches no value, and it is no [arm] site. *)
open Effect.Deep

type _ Effect.t += Ask : int Effect.t

(* [v] is the one case that a value reaches, so it is no site. *)
let run f = match f () with v -> v | effect Ask, k -> continue k 1

(* [Some v] and [None] are sites. *)
let run_option f =
  match f () with Some v -> v | None -> 0 | effect Ask, k -> continue k 1

(* The case [Not_found] of a [try] is a site. *)
let run_handler f =
  try f () with Not_found -> 0 | effect Ask, k -> continue k 1
