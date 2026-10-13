(* A file that binds [invalid_arg] loses the filter of [failure message]. *)

let invalid_arg n = n + 1
let fail () = invalid_arg 7
