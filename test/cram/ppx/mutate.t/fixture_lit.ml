(* Under [-lit], a literal becomes another one. An integer becomes its
   successor, with its suffix, under [one] for [0] and [inc] for the others.
   A float other than zero becomes [0.] under [zero], and a zero becomes
   [1.] under [one]. *)

let ints = (0, 41, -1, 0x7f, 7l, 9L, 3n)
let floats = (2.5, 0., -0.0, 1e3)

(* The successor of the greatest integer is the least one, as the addition
   gives. *)
let greatest = 4611686018427387903

(* An integer literal that its type cannot hold is no site, so that the
   compiler reports the error. *)
let too_big = (4611686018427387905, 2147483649l, 0x1_0000_0000_0000_0000L)

(* [true] and [false] swap under [flip], except in a condition, where [neg]
   gives the same mutant. *)
let flags = (true, false)
let forever f = while true do f () done
let both a = a && true

(* A string, a character and a literal with the suffix of another rewriter
   are no sites, and neither is a literal in a pattern, in an attribute or
   in an [assert]. *)
let text = ("text", 'c', 1z)
let small = function 0 -> "zero" | _ -> "other"
let noted = 2 [@note 5]
let checked x = assert (x > 0)
