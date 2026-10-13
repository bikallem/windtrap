(* Before OCaml 5.2, the attributes of [function] after parameters go on the
   function expression, and the printer spells the expansion in another
   form. *)

(* After parameters, the parser puts the attributes of [function] on its
   cases. The generated attribute also comes before them. *)
let loud x = function[@warning "+8"] 0 -> x | _ -> 1

(* After parameters, a dismissal on [function] leaves its cases as written.
   The default argument keeps its site. *)
let quiet ?(d = 1 + 2) x = function[@mutate off "kept"] 0 -> x + d | _ -> 2
