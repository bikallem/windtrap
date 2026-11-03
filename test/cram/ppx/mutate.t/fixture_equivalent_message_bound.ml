(* A file that binds [failwith] loses the rule of the failure message. *)

let failwith n = n + 1
let fail () = failwith 7
