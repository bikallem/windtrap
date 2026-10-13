(* [[@mutate off]] has priority over a filter: each site that a filter
   would take is dismissed with its reason, and not filtered. *)

let plus x = (x + 0) [@mutate off "zero is kept"]
let both a = (a && a) [@mutate off "one operand"]
let flag c x = if (c [@mutate off "one branch"]) then x else x
let kind x = function (`A [@mutate off "one case"]) -> x | _ -> x
let debug x = Logs.debug (fun m -> m "%d" ((x + 1) [@mutate off "a log"]))
let fail () = failwith (string_of_int (3 [@mutate off "a message"]))
