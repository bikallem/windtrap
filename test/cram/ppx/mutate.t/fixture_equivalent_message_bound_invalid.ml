(* A file that binds [invalid_arg] loses the rule of the failure message. *)

let invalid_arg n = n + 1
let fail () = invalid_arg 7
