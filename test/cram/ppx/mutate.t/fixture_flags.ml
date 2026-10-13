(* The backend flags [-no-arm], [-no-call] and [-no-ret] switch a family
   off, and [-lit] switches [lit] on. The operators stay. *)

let size n = match n with 0 -> "none" | _ -> "some"

let tick r =
  incr r;
  !r + 1

let wrap x = Some x
