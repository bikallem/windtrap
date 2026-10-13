(* A location gives two copies of one text two values, so their sites keep
   their mutants. [assert] raises [Assert_failure] with its location.
   [__LOC__] and its kin give the location of the copy, under any path. An
   extension node can expand to a location. *)

let asserted x = if x > 0 then assert (x < 5) else assert (x < 5)
let loc c = if c then __LOC__ else __LOC__
let qualified c = if c then Stdlib.__LOC__ else Stdlib.__LOC__
let pos c = if c then Stdlib.__POS__ else Stdlib.__POS__
let line c = if c then Stdlib.__LINE__ else Stdlib.__LINE__
let case = function 0 -> Stdlib.__LOC__ | _ -> Stdlib.__LOC__
let extension c = if c then [%here] else [%here]
