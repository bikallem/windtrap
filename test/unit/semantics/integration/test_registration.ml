(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The libraries of this directory are instrumented in every build, so that
   they compile is the check on the generated code: fatal warnings, a
   shadowed [not] and [bool], the typing order and the expected type of an
   operand. This suite checks what compiling cannot: with nothing armed each
   function computes its original result, and an armed mutant computes the
   rewrite its site names. *)

open Windtrap
module Mutate = Windtrap_runtime.Mutate
module Oracle = Windtrap_mutate_forced.Oracle
module Forced = Windtrap_mutate_forced.Forced
module No_guard = Windtrap_mutate_forced.No_guard
module Disambiguate = Windtrap_mutate_disambiguate.Disambiguate
module Expected_type = Windtrap_mutate_disambiguate.Expected_type

let strf = Printf.sprintf

(* Arming *)

(* [arm] disarms the armed mutant before it resolves, so arming an identifier
   of no catalogued file leaves nothing armed. *)
let disarm () =
  let nowhere =
    { Mutate.file = "<nowhere>.ml"; line = 1; col = 0; rewrite = "not" }
  in
  match Mutate.arm nowhere with
  | Error (Mutate.Uncatalogued _) -> ()
  | Ok _ | Error (Malformed _ | Unmatched _ | Ambiguous _) ->
      fail "an identifier of no catalogued file armed a mutant"

let mutants_of file =
  List.filter
    (fun (m : Mutate.mutant) -> String.equal (Filename.basename m.id.file) file)
    (Mutate.catalogue ())

let pp_ids ppf mutants =
  let id ppf (m : Mutate.mutant) =
    Format.pp_print_string ppf (Mutate.id_to_string m.id)
  in
  Format.pp_print_list ~pp_sep:Format.pp_print_space id ppf mutants

(* [armed ~file ~rewrite ~before f] is [f ()] with the one mutant of [file]
   that has this rewrite and this original text armed. Finding it by its text
   keeps the rendered texts under test. *)
let armed ~file ~rewrite ~before f =
  let named (m : Mutate.mutant) =
    String.equal m.id.rewrite rewrite && String.equal m.before before
  in
  let m =
    require_match ~msg:"one mutant has this rewrite and this text" ~pp:pp_ids
      (function [ m ] -> Some m | _ -> None)
      (List.filter named (mutants_of file))
  in
  ignore (require_ok ~pp:Mutate.pp_arm_error (Mutate.arm m.id) : Mutate.mutant);
  Fun.protect ~finally:disarm f

let ints = List.map Int.to_string
let bools = List.map Bool.to_string
let floats = List.map Float.to_string

(* [traced f] is the operands [f] evaluated, in order. *)
let traced f =
  ignore (f ());
  String.concat "," (Oracle.record ())

(* The corpora's values *)

let rect = { Disambiguate.Layout.x = 10; y = 20; width = 30; height = 40 }
let collide = { Disambiguate.Rect.x = 10; y = 20; width = 30; height = 40 }
let line = { Disambiguate.Line.start = 2; end_ = 7 }
let empty_line = { Disambiguate.Line.start = 7; end_ = 7 }

let item =
  let sides left right =
    { Disambiguate.Sides.left; right; top = 0.; bottom = 0. }
  in
  { Disambiguate.padding = sides 1. 2.; border = sides 3. 4. }

let point y = { Expected_type.Point.x = 0; y }

(* Disarmed *)

let originals =
  [
    ("neg_pick true", "1", fun () -> Int.to_string (Oracle.neg_pick true));
    ("cmp_lt 2 2", "0", fun () -> Int.to_string (Oracle.cmp_lt 2 2));
    ("cmp_le 2 2", "1", fun () -> Int.to_string (Oracle.cmp_le 2 2));
    ( "con_and false true",
      "false",
      fun () -> Bool.to_string (Oracle.con_and false true) );
    ( "con_or true false",
      "true",
      fun () -> Bool.to_string (Oracle.con_or true false) );
    ("ari_add 5 3", "8", fun () -> Int.to_string (Oracle.ari_add 5 3));
    ("ari_sub 5 3", "2", fun () -> Int.to_string (Oracle.ari_sub 5 3));
    ( "the operands of cmp_order",
      "r,l",
      fun () -> traced (fun () -> Oracle.cmp_order 1 2) );
    ( "the operands of ari_order",
      "r,l",
      fun () -> traced (fun () -> Oracle.ari_order 1 2) );
    ( "the right operand of con_short false",
      "",
      fun () -> traced (fun () -> Oracle.con_short false true) );
    ( "the right operand of con_short true",
      "r",
      fun () -> traced (fun () -> Oracle.con_short true true) );
    ("clip", "130", fun () -> Int.to_string (Disambiguate.clip rect 0 0 100 100));
    ("span", "5", fun () -> Int.to_string (Disambiguate.span line));
    ("inverted", "0", fun () -> Int.to_string (Disambiguate.inverted line));
    ( "horizontal",
      "10.",
      fun () -> Float.to_string (Disambiguate.horizontal item) );
    ( "clip_collide",
      "130",
      fun () -> Int.to_string (Disambiguate.clip_collide collide 5 0 100 100) );
    ( "before_green Red",
      "1",
      fun () ->
        Int.to_string (Expected_type.before_green Expected_type.Color.Red) );
    ( "before_green Green",
      "0",
      fun () ->
        Int.to_string (Expected_type.before_green Expected_type.Color.Green) );
    ( "past_green Blue",
      "1",
      fun () ->
        Int.to_string (Expected_type.past_green Expected_type.Color.Blue) );
    ( "past_green Green",
      "0",
      fun () ->
        Int.to_string (Expected_type.past_green Expected_type.Color.Green) );
    ( "within Green",
      "true",
      fun () -> Bool.to_string (Expected_type.within Expected_type.Color.Green)
    );
    ( "within Blue",
      "false",
      fun () -> Bool.to_string (Expected_type.within Expected_type.Color.Blue)
    );
    ( "below { x = 0; y = 5 }",
      "1",
      fun () -> Int.to_string (Expected_type.below (point 5)) );
    ( "below { x = 0; y = 10 }",
      "0",
      fun () -> Int.to_string (Expected_type.below (point 10)) );
    ( "is_green Green",
      "1",
      fun () -> Int.to_string (Expected_type.is_green Expected_type.Color.Green)
    );
    ( "a dismissed site's cap 20",
      "20",
      fun () -> Int.to_string (No_guard.cap 20) );
    ("arm_pick 0", "zero", fun () -> Oracle.arm_pick 0);
    ("arm_guarded 10", "big", fun () -> Oracle.arm_guarded 10);
    ("arm_guarded 9", "small", fun () -> Oracle.arm_guarded 9);
    ( "arm_handler of Not_found",
      "caught",
      fun () -> Oracle.arm_handler (fun () -> raise Not_found) );
    ( "call_statement",
      "1",
      fun () -> Int.to_string (Oracle.call_statement (ref 0)) );
    ("call_bound", "1", fun () -> Int.to_string (Oracle.call_bound (ref 0)));
    ("lit_int", "41", fun () -> Int.to_string (Oracle.lit_int ()));
    ("lit_negative", "-1", fun () -> Int.to_string (Oracle.lit_negative ()));
    ("lit_zero_int64", "0", fun () -> Int64.to_string (Oracle.lit_zero_int64 ()));
    ("lit_int32", "7", fun () -> Int32.to_string (Oracle.lit_int32 ()));
    ( "lit_nativeint",
      "3",
      fun () -> Nativeint.to_string (Oracle.lit_nativeint ()) );
    ("lit_float", "2.5", fun () -> Float.to_string (Oracle.lit_float ()));
    ( "lit_zero_float",
      "0.",
      fun () -> Float.to_string (Oracle.lit_zero_float ()) );
    ("lit_bool", "true", fun () -> Bool.to_string (Oracle.lit_bool ()));
    ( "ret_some 1",
      "1",
      fun () -> Option.fold ~none:"none" ~some:Int.to_string (Oracle.ret_some 1)
    );
    ( "ret_cons 1 [ 2 ]",
      "1,2",
      fun () -> String.concat "," (ints (Oracle.ret_cons 1 [ 2 ])) );
    ( "the operands of ret_some_order",
      "e",
      fun () -> traced (fun () -> Oracle.ret_some_order 1) );
    ( "the operands of ret_cons_order",
      "t,h",
      fun () -> traced (fun () -> Oracle.ret_cons_order 1 [ 2 ]) );
  ]

let disarmed =
  group "Disarmed"
    [
      cases "with nothing armed, a function computes its original result"
        ~name:(fun (name, _, _) -> name)
        originals
        (fun (_, expected, actual) -> equal string expected (actual ()));
    ]

(* Armed *)

type arming = {
  file : string;
  rewrite : string;
  before : string;
  observe : unit -> string list; (* values where the two readings differ *)
  mutated : string list;
}

let oracle rewrite before observe mutated =
  { file = "oracle.ml"; rewrite; before; observe; mutated }

let truth_table f =
  bools [ f true true; f true false; f false true; f false false ]

(* Each comparison is read at the boundary, where it and its rewrite differ,
   and away from it, where they agree. *)
let armings =
  [
    oracle "not" "flag"
      (fun () -> ints [ Oracle.neg_pick true; Oracle.neg_pick false ])
      [ "0"; "1" ];
    oracle "le" "a < b"
      (fun () -> ints [ Oracle.cmp_lt 2 2; Oracle.cmp_lt 3 2 ])
      [ "1"; "0" ];
    oracle "lt" "a <= b"
      (fun () -> ints [ Oracle.cmp_le 2 2; Oracle.cmp_le 1 2 ])
      [ "0"; "1" ];
    oracle "ge" "a > b"
      (fun () -> ints [ Oracle.cmp_gt 2 2; Oracle.cmp_gt 1 2 ])
      [ "1"; "0" ];
    oracle "gt" "a >= b"
      (fun () -> ints [ Oracle.cmp_ge 2 2; Oracle.cmp_ge 3 2 ])
      [ "0"; "1" ];
    oracle "neq" "a = b"
      (fun () -> ints [ Oracle.cmp_eq 2 2; Oracle.cmp_eq 1 2 ])
      [ "0"; "1" ];
    oracle "eq" "a <> b"
      (fun () -> ints [ Oracle.cmp_ne 2 2; Oracle.cmp_ne 1 2 ])
      [ "1"; "0" ];
    oracle "or" "a && b"
      (fun () -> truth_table Oracle.con_and)
      (bools [ true; true; true; false ]);
    oracle "and" "a || b"
      (fun () -> truth_table Oracle.con_or)
      (bools [ true; false; false; false ]);
    oracle "sub" "a + b" (fun () -> ints [ Oracle.ari_add 5 3 ]) [ "2" ];
    oracle "add" "a - b" (fun () -> ints [ Oracle.ari_sub 5 3 ]) [ "8" ];
    oracle "fsub" "a +. b" (fun () -> floats [ Oracle.ari_fadd 5. 3. ]) [ "2." ];
    oracle "fadd" "a -. b" (fun () -> floats [ Oracle.ari_fsub 5. 3. ]) [ "8." ];
    (* A dropped case gives its value to the next case, past a guard that it
       no longer runs, and a dropped handler lets its exception go on. *)
    oracle "drop" "| 0 -> ..." (fun () -> [ Oracle.arm_pick 0 ]) [ "other" ];
    oracle "drop" "| n when n > 9 -> ..."
      (fun () -> [ Oracle.arm_guarded 10 ])
      [ "small" ];
    oracle "drop" "| Not_found -> ..."
      (fun () ->
        [
          (match Oracle.arm_handler (fun () -> raise Not_found) with
          | caught -> caught
          | exception Not_found -> "raised Not_found");
        ])
      [ "raised Not_found" ];
    oracle "skip" "incr count"
      (fun () -> ints [ Oracle.call_statement (ref 0) ])
      [ "0" ];
    oracle "skip" "incr total"
      (fun () -> ints [ Oracle.call_bound (ref 0) ])
      [ "0" ];
    oracle "inc" "41" (fun () -> ints [ Oracle.lit_int () ]) [ "42" ];
    oracle "inc" "(-1)" (fun () -> ints [ Oracle.lit_negative () ]) [ "0" ];
    oracle "one" "0L"
      (fun () -> [ Int64.to_string (Oracle.lit_zero_int64 ()) ])
      [ "1" ];
    oracle "inc" "7l"
      (fun () -> [ Int32.to_string (Oracle.lit_int32 ()) ])
      [ "8" ];
    oracle "inc" "3n"
      (fun () -> [ Nativeint.to_string (Oracle.lit_nativeint ()) ])
      [ "4" ];
    oracle "zero" "2.5" (fun () -> floats [ Oracle.lit_float () ]) [ "0." ];
    oracle "one" "0." (fun () -> floats [ Oracle.lit_zero_float () ]) [ "1." ];
    oracle "flip" "true" (fun () -> bools [ Oracle.lit_bool () ]) [ "false" ];
    oracle "none" "Some x"
      (fun () ->
        [ Option.fold ~none:"none" ~some:Int.to_string (Oracle.ret_some 1) ])
      [ "none" ];
    oracle "tail" "h :: t"
      (fun () -> ints (Oracle.ret_cons 1 [ 2; 3 ]))
      [ "2"; "3" ];
    (* Armed, the two encodings that bind their operands still evaluate each
       once, right to left, and the connective runs its right operand when the
       rewrite says so. *)
    oracle "le" "(note \"l\" a) < (note \"r\" b)"
      (fun () -> [ traced (fun () -> Oracle.cmp_order 1 2) ])
      [ "r,l" ];
    oracle "sub" "(note \"l\" a) + (note \"r\" b)"
      (fun () -> [ traced (fun () -> Oracle.ari_order 1 2) ])
      [ "r,l" ];
    oracle "or" "a && (note \"r\" b)"
      (fun () ->
        [
          traced (fun () -> Oracle.con_short false true);
          traced (fun () -> Oracle.con_short true true);
        ])
      [ "r"; "" ];
    (* Armed, a [ret] mutant evaluates what its [after] text holds alone. *)
    oracle "none" "Some (note \"e\" x)"
      (fun () -> [ traced (fun () -> Oracle.ret_some_order 1) ])
      [ "" ];
    oracle "tail" "(note \"h\" h) :: (note \"t\" t)"
      (fun () -> [ traced (fun () -> Oracle.ret_cons_order 1 [ 2 ]) ])
      [ "t" ];
    {
      file = "disambiguate.ml";
      rewrite = "add";
      before = "rect.Rect.x - x0";
      observe =
        (fun () -> ints [ Disambiguate.clip_collide collide 5 0 100 100 ]);
      mutated = [ "140" ];
    };
    {
      file = "disambiguate.ml";
      rewrite = "add";
      before = "line.Line.end_ - line.start";
      observe = (fun () -> ints [ Disambiguate.span line ]);
      mutated = [ "9" ];
    };
    {
      file = "disambiguate.ml";
      rewrite = "le";
      before = "line.Line.end_ < line.start";
      observe =
        (fun () ->
          ints [ Disambiguate.inverted line; Disambiguate.inverted empty_line ]);
      mutated = [ "0"; "1" ];
    };
    {
      file = "disambiguate.ml";
      rewrite = "fsub";
      before =
        "(((child.padding).left +. (child.padding).right) +. \
         (child.border).left) +. (child.border).right";
      observe = (fun () -> floats [ Disambiguate.horizontal item ]);
      mutated = [ "2." ];
    };
    {
      file = "expected_type.ml";
      rewrite = "le";
      before = "c < Green";
      observe =
        (fun () ->
          ints [ Expected_type.before_green Expected_type.Color.Green ]);
      mutated = [ "1" ];
    };
    {
      file = "expected_type.ml";
      rewrite = "le";
      before = "p < { x = 0; y = 10 }";
      observe = (fun () -> ints [ Expected_type.below (point 10) ]);
      mutated = [ "1" ];
    };
  ]

let arming_name a = strf "%s: %s, armed %s" a.file a.before a.rewrite

let armed_row a =
  equal (list string) a.mutated
    (armed ~file:a.file ~rewrite:a.rewrite ~before:a.before a.observe)

let armed_mutants =
  group "Armed"
    [
      cases "an armed mutant computes the rewrite its site names"
        ~name:arming_name armings armed_row;
    ]

(* Every mutant *)

(* [forced ()] reads the functions of forced.ml that its mutants change. A
   dropped case can raise [Match_failure], which is a reading too. *)
let forced () =
  match
    strf "%d %d %.1f %b %b %b %b %d %d %d %d %b %s %d %d %d" (Forced.sum 2 3)
      (Forced.diff 9 4) (Forced.fsum 1.5 2.5) (Forced.both true false)
      (Forced.either false true) (Forced.window 0 10 5)
      (Forced.chain true true false)
      (Forced.below 1 2) (Forced.same 1 1) (Forced.at_least 3 3)
      (Forced.scaled 2 3)
      (Forced.search (fun x -> x > 2) [ 1; 2; 3 ])
      (Forced.show_shape Forced.Bool true)
      (Forced.handled (fun () -> raise Not_found))
      (Forced.bump (ref 0))
      (Forced.bump_bound (ref 0))
  with
  | reading -> reading
  | exception e -> "raised " ^ Printexc.to_string e

let every_forced_mutant () =
  let original = forced () in
  let reading (m : Mutate.mutant) =
    ignore
      (require_ok ~pp:Mutate.pp_arm_error (Mutate.arm m.id) : Mutate.mutant);
    let armed = forced () in
    disarm ();
    (Mutate.id_to_string m.id, armed, forced ())
  in
  let readings = List.map reading (mutants_of "forced.ml") in
  let ids keep =
    List.filter_map
      (fun ((id, _, _) as r) -> if keep r then Some id else None)
      readings
  in
  not_equal ~msg:"the mutants that change the reading" (list string) []
    (ids (fun (_, armed, _) -> armed <> original));
  equal ~msg:"the mutants that leave a change after disarming" (list string) []
    (ids (fun (_, _, after) -> after <> original))

let every_mutant =
  group "Every mutant"
    [
      test "arming a mutant changes a reading and disarming restores it"
        every_forced_mutant;
    ]

(* A file that declares the constructors of a guard *)

(* The test reads [size], so that the module is linked and registers its
   sites. *)
let lost_families () =
  let rewrite (m : Mutate.mutant) = m.id.rewrite in
  equal int 3 Windtrap_mutate_forced.Own_constructors.size;
  equal (list string) [ "ge"; "one"; "inc" ]
    (List.map rewrite (mutants_of "own_constructors.ml"))

let lost =
  group "Lost families"
    [
      test "a file that declares Some, (::) and true keeps no ret and no flip"
        lost_families;
    ]

let () =
  exit
    (run "mutate registration" [ disarmed; armed_mutants; every_mutant; lost ])
