(* A case with no drop site: the rewriter does not read the attributes
   inside its pattern. *)

(* The one case that a value can reach. *)
let sum p = match p with a, (b [@mutate off "unused"]) -> a + b

(* A match with a refutation case. *)
type empty = |

let get (r : (int, empty) result) =
  match r with Ok (0 [@mutate off "zero"]) -> 0 | Ok n -> n | Error _ -> .
