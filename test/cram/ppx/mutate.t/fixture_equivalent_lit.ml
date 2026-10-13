(* [failure message]: under [-lit], a literal in the arguments of
   [failwith] or [invalid_arg] changes the message alone, as an integer, a
   zero, a float and a boolean do. The other sites there keep their
   mutants, and so does a literal of [raise], whose exception a test can
   compare. *)

let fail n = failwith (Printf.sprintf "item %d of %d" (n + 1) 10)
let invalid () = Stdlib.invalid_arg (string_of_int 3)
let formatted () = Printf.ksprintf failwith "code %d" 4
let piped () = string_of_int 5 |> failwith
let raised () = raise (Invalid_argument (string_of_int 6))
let kformatted () = Format.kasprintf failwith "code %d" 8
let qualified () = Stdlib.failwith (string_of_int 9)
let zero () = failwith (string_of_int 0)
let float () = invalid_arg (string_of_float 2.5)
let float_zero () = failwith (string_of_float 0.)
let flag () = failwith (string_of_bool true)
