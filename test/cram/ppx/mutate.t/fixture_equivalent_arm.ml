(* [same body as the next case]: a case without a guard whose body is that
   of the next case, when the next case is [_], gives the same value
   dropped. A case that binds a variable, a case with a guard and a next
   case other than [_] keep their mutants. A case that forces a lazy value
   keeps its mutant too, because the next case does not force it. A next
   case with a guard can fail. A next [_] catches no exception, and a next
   [exception _] catches no value. *)

let kind = function `A -> 0 | _ -> 0
let bound = function Some _x -> 0 | _ -> 0
let guarded p = function `A when p -> 0 | _ -> 0
let named = function `A -> 0 | x -> ignore x; 0
let call f = function `A -> f () | _ -> f ()
let handler f = try f () with Not_found -> 0 | _ -> 0
let raised f =
  match f () with v -> v | exception Not_found -> 0 | exception _ -> 0
let forced = function lazy 0 -> 1 | _ -> 1
let next_guarded p = function `A -> 0 | _ when p -> 0
let value f = match f () with exception Not_found -> 0 | _ -> 0
let exn f = match f () with 1 -> 0 | 2 -> 0 | exception _ -> 0
