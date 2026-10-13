(* A file that binds [failwith] loses the filter of [failure message]. *)

let failwith n = n + 1
let fail () = failwith 7
