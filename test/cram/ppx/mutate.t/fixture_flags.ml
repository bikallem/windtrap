(* The backend flags [-no-arm] and [-no-call] switch the two families off,
   and leave the operators. *)

let size n = match n with 0 -> "none" | _ -> "some"

let tick r =
  incr r;
  !r + 1
