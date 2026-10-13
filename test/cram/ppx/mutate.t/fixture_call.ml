(* [call] skips an application whose value the code discards: the left
   operand of a sequence, and the expression of [let () = e in body]. The
   last operand of a sequence gives the value, and is no site. *)

let tick r =
  incr r;
  r := !r + 1;
  !r

let bound r =
  let () = incr r in
  !r

(* A statement that is no application has no [call] site, and an operator
   that carries a mutant keeps it. *)
let assign p r =
  p.contents <- 1;
  if !r > 0 then incr r;
  r := 2

let discard x =
  x + 1;
  ()

(* A comparison carries [cmp] only in a condition. Its statement is thus a
   [call] site. *)
let compare_only a b =
  a < b;
  ()

(* A [let () = e] at the top level runs at module initialization alone, and
   is no site. *)
let () = print_newline ()

(* [[@mutate off]] dismisses the site of a statement. *)
let quiet r =
  (incr r [@mutate off "the count is not read"]);
  !r

(* A connective with a connective for an operand carries no mutant. Its
   statement has no [call] site either. *)
let chain a b c =
  (a && b && c) [@warning "-10"];
  ()

(* Only [let () = e] skips [e]. Another constant constructor matches a value
   of another type, which a skipped [e] does not give. *)
type single = Single

let single f x =
  let Single = f x in
  x
