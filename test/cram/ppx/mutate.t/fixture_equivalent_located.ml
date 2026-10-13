(* A location gives two copies of one text two values, so their sites keep
   their mutants. [assert] raises [Assert_failure] with its location.
   [__LOC__] and its kin give the location of the copy, under any path. An
   extension node can expand to a location. A pattern that can fail, also in
   a tuple, raises [Match_failure] with its location, in a [let] and a [fun].
   The rewriter does not see the types, so it treats each [match] and each
   [function] as one that can fail, also when its cases cover all values. *)

let asserted x = if x > 0 then assert (x < 5) else assert (x < 5)
let loc c = if c then __LOC__ else __LOC__
let qualified c = if c then Stdlib.__LOC__ else Stdlib.__LOC__
let pos c = if c then Stdlib.__POS__ else Stdlib.__POS__
let line c = if c then Stdlib.__LINE__ else Stdlib.__LINE__
let case = function 0 -> Stdlib.__LOC__ | _ -> Stdlib.__LOC__
let extension c = if c then [%here] else [%here]
(* The compared trees keep the parentheses, so the two branches of each [if]
   that follows have the same ones. *)
let refuted c o = if c then (let (Some x) = o in x) else (let (Some x) = o in x)
let refuted_fun c = if c then fun (Some x) -> x else fun (Some x) -> x
let pair c o = if c then (let Some x, _ = o in x) else (let Some x, _ = o in x)
let total c x = if c then (match x with () -> 1) else (match x with () -> 1)
let total_function c = if c then function () -> 1 else function () -> 1
