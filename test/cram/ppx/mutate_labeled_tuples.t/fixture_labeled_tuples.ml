(* ppxlib encodes a labeled tuple of OCaml 5.4 as an extension node. The
   texts of a site spell it as the source does. *)

let x_or_y p = match p with ~x:0, ~y -> y | ~x, ~y:_ -> x

let show a b =
  print_int ((~a, ~b) |> fun (~a, ~b:_) -> a);
  print_newline ()
