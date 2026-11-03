(* [[@mutate off]] has priority over the rules of equivalence: each site
   that such a rule would make arid is recorded as dismissed, with its
   reason. *)

let plus x = (x + 0) [@mutate off "zero is kept"]
let both a = (a && a) [@mutate off "one operand"]
let flag c x = if (c [@mutate off "one branch"]) then x else x
let debug x = Logs.debug (fun m -> m "%d" ((x + 1) [@mutate off "a log"]))
let fail () = failwith (string_of_int (3 [@mutate off "a message"]))
