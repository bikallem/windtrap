(* The mutation rewriter over a file that holds the coverage rewriter's
   visits. *)

(* [a || b] reaches the rewriter as the [if] of the coverage rewriter: it
   carries no [con] mutant, and each operand, now a condition, carries
   [neg]. *)
let either a b = a || b

(* The [before] and [after] texts of a site hold the visits inside it. *)
let lt f g x = if f x < g x then 1 else 0

(* The coverage rewriter wraps a call in a statement, as
   [___windtrap_post_visit___ 0 (f x)]. The wrapper is the [skip] site of
   the call, and the dismissal of the call holds. A visit is no site. *)
let tick r f x =
  f x;
  (f x) [@mutate off "the result of f is discarded"];
  let () = f x in
  incr r;
  !r

(* The wrapper of a call in a condition carries [neg]. Its two texts leave
   out the attributes of the call, and the dismissal of the call holds. *)
let wait f x = while (f x [@inlined]) do () done
let poll f x = while (f x [@mutate off "a timeout ends the loop"]) do () done
