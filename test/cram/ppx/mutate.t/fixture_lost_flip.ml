(* Under [-lit], a file that declares a constructor [true] or [false] loses
   [flip]: the guard would give the predefined [false] in place of the
   [true] of the file. The other rewrites of [lit] stay. *)

type truth = true | Unknown

let sure : truth = true
let size = 3
