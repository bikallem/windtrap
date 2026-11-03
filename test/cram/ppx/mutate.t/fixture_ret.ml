(* [none] gives [None] in place of [Some e], and [tail] gives [t] in place
   of [h :: t]. The armed arm of [tail] is a copy of [t] with no guard. A
   list literal is one site, at its bracket. *)

let wrap x = Some (x + 1)
let push x xs = x :: xs
let three () = [ 1; 2; 3 ]
let pair x y = x :: [ y ]

let long () =
  [ "a";
    "b" ]

(* In a chain of [(::)], the outermost [(::)] alone is a site. *)
let chain a b t = a :: b :: t

(* The right-hand side of a [let rec] has no site of the two, except in its
   functions and its [lazy] bodies. This is also true in a class and in a
   functor. *)
let local () =
  let rec ones = 1 :: ones in
  let rec stream = lazy (1 :: Lazy.force stream) in
  let rec count n = if n = 0 then [] else n :: count (n - 1) in
  (ones, stream, count)

class cycle =
  let rec ones = 1 :: ones in
  object
    method ones = ones
  end

module Make (X : sig end) = struct
  let rec ones = 1 :: ones
  let twos = [ 2 ]
end

(* Code that runs when the module is initialized has no site of the two. *)
let first = Some 1
let rest = [ 1; 2 ]

(* A qualified constructor, [None] and [[]] are no sites. *)
let qualified x = Option.Some x
let empty () = (None, [])
