(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

open Windtrap
module Instr = Windtrap_runtime.Instr
module Mutate = Windtrap_runtime.Mutate
module Verdicts = Windtrap_runtime.Verdicts

let strf = Printf.sprintf
let read path = In_channel.with_open_bin path In_channel.input_all
let id file line col rewrite = { Mutate.file; line; col; rewrite }

let record ?(before = "b") ?(after = "a") ?end_ ?source_digest ?previous
    (id : Mutate.id) verdict =
  let end_line, end_col =
    Option.value end_ ~default:(id.line, id.col + String.length before)
  in
  {
    Verdicts.id;
    end_line;
    end_col;
    before;
    after;
    source_digest;
    verdict;
    previous;
  }

let collection records = List.fold_left Verdicts.add Verdicts.empty records

(* Rows. Every string is quoted, so a row tells any two values apart. *)

let quoted names = String.concat " " (List.map (strf "%S") names)

let verdict_row = function
  | Verdicts.Killed -> "killed"
  | Killed_elsewhere { exe } -> strf "killed elsewhere by %S" exe
  | Unknown reason -> "unknown: " ^ reason
  | Survived { first; others } ->
      "survived by "
      ^ String.concat ", "
          (List.map (fun t -> "[" ^ quoted t ^ "]") (first :: others))
  | Not_evaluated -> "not evaluated"
  | Outside_tests -> "outside tests"
  | Unreached -> "unreached"

let outcome_row = function
  | `Killed -> "killed"
  | `Survived -> "survived"
  | `Not_evaluated -> "not evaluated"

let record_row (r : Verdicts.record) =
  strf "%S:%d:%d:%s (to %d:%d) %S -> %S%s: %s%s" r.id.file r.id.line r.id.col
    r.id.rewrite r.end_line r.end_col r.before r.after
    (Option.fold ~none:"" ~some:(strf " of %s") r.source_digest)
    (verdict_row r.verdict)
    (Option.fold ~none:"" ~some:(fun o -> " was " ^ outcome_row o) r.previous)

let rows t = List.map record_row (Verdicts.records t)
let verdict = Testable.contramap verdict_row Testable.string
let records = Testable.contramap rows (list string)
let identity_row (i : Verdicts.identity) = strf "%S %s" i.exe i.digest
let identity = Testable.contramap identity_row Testable.string

let error_row = function
  | Verdicts.Unknown_format { path; header } ->
      strf "unknown format %s %S" path header
  | Unreadable { path; _ } -> "unreadable " ^ path
  | Corrupt { path; reason } -> strf "corrupt %s: %s" path reason

let load_rows = function
  | Ok { Verdicts.verdicts; identity; suite = _; refused = _ } ->
      Ok (rows verdicts, Option.map identity_row identity)
  | Error e -> Error (error_row e)

let load_text s =
  let path = Filename.concat (temp_dir ()) "f.mutants" in
  Out_channel.with_open_bin path (fun oc -> output_string oc s);
  (path, Verdicts.load path)

let corrupt_path = function
  | Error (Verdicts.Corrupt { path; _ }) -> Some path
  | _ -> None

let saved ?identity ?suite t =
  let path = Filename.concat (temp_dir ()) "saved.mutants" in
  Verdicts.save ?identity ?suite path t;
  read path

(* Generators *)

let pp_verdict ppf v = Format.pp_print_string ppf (verdict_row v)
let pp_record ppf r = Format.pp_print_string ppf (record_row r)
let pp_records ppf t = Format.pp_print_string ppf (String.concat "\n" (rows t))
let pp_identity ppf i = Format.pp_print_string ppf (identity_row i)

(* Few names and identifiers, so that two draws often share one. *)
let small_verdict =
  let path =
    Gen.list ~size:(Gen.int_range 1 2) (Gen.of_list [ "g"; "t"; "u" ])
  in
  Gen.with_pp pp_verdict
    (Gen.frequency
       [
         (1, Gen.constant Verdicts.Killed);
         ( 1,
           Gen.map
             (fun exe -> Verdicts.Killed_elsewhere { exe })
             (Gen.of_list [ "x"; "y" ]) );
         (1, Gen.map (fun r -> Verdicts.Unknown r) (Gen.of_list [ "x"; "y" ]));
         (1, Gen.constant Verdicts.Not_evaluated);
         (3, Gen.map Verdicts.survived (Gen.list ~size:(Gen.int_range 1 3) path));
         (1, Gen.constant Verdicts.Outside_tests);
         (1, Gen.constant Verdicts.Unreached);
       ])

let small_digest =
  Gen.option (Gen.of_list [ String.make 32 'a'; String.make 32 'b' ])

let any_previous =
  Gen.option (Gen.of_list [ `Killed; `Survived; `Not_evaluated ])

let small_record =
  Gen.with_pp pp_record
    (Gen.map
       (fun ( (file, (line, stop), (before, after, source_digest), verdict),
              previous ) ->
         record ~before ~after ~end_:(line, stop) ?source_digest ?previous
           (id file line 0 "lt") verdict)
       (Gen.pair
          (Gen.quad
             (Gen.of_list [ "lib/a.ml"; "lib/b.ml" ])
             (Gen.pair (Gen.int_range 1 2) (Gen.int_range 1 2))
             (Gen.triple
                (Gen.of_list [ "a"; "b" ])
                (Gen.of_list [ "a"; "b" ])
                small_digest)
             small_verdict)
          any_previous))

let small_collection =
  Gen.with_pp pp_records
    (Gen.map collection (Gen.list ~size:(Gen.int_range 0 6) small_record))

(* Any bytes in every name, and any identifier that load accepts. *)
let any_record =
  let name = Gen.string in
  let path = Gen.list ~size:(Gen.int_range 0 3) name in
  let verdict =
    Gen.one_of
      [
        Gen.of_list Verdicts.[ Killed; Not_evaluated; Outside_tests; Unreached ];
        Gen.map (fun e -> Verdicts.Killed_elsewhere { exe = "e" ^ e }) name;
        Gen.map (fun r -> Verdicts.Unknown r) name;
        Gen.map Verdicts.survived (Gen.list ~size:(Gen.int_range 1 3) path);
      ]
  in
  let digest =
    Gen.option
      (Gen.string_of ~size:(Gen.constant 32)
         (Gen.of_list (List.of_seq (String.to_seq "0123456789abcdef"))))
  in
  Gen.map
    (fun ( ( (file, line, col, rewrite),
             (lines, stop),
             (before, after, source_digest),
             verdict ),
           previous ) ->
      let end_ = (line + lines, if lines = 0 then col + stop else stop) in
      record ~before ~after ~end_ ?source_digest ?previous
        (id file line col rewrite) verdict)
    (Gen.pair
       (Gen.quad
          (Gen.quad
             (Gen.map (fun s -> "f" ^ s) name)
             (Gen.map succ Gen.nat) Gen.nat
             (Gen.of_list Mutate.rewrites))
          (Gen.pair Gen.nat Gen.nat)
          (Gen.triple name name digest)
          verdict)
       any_previous)

let any_identity =
  Gen.option
    (Gen.with_pp pp_identity
       (Gen.map
          (fun (exe, digest) -> { Verdicts.exe = "e" ^ exe; digest })
          (Gen.pair Gen.string
             (Gen.string_of ~size:(Gen.constant 32)
                (Gen.of_list (List.of_seq (String.to_seq "0123456789abcdef")))))))

let any_file =
  Gen.triple any_identity (Gen.option Gen.string)
    (Gen.with_pp pp_records
       (Gen.map collection (Gen.list ~size:(Gen.int_range 0 5) any_record)))

(* Verdicts *)

let rank = function
  | Verdicts.Killed -> 6
  | Killed_elsewhere _ -> 5
  | Unknown _ -> 4
  | Not_evaluated -> 3
  | Survived _ -> 2
  | Outside_tests -> 1
  | Unreached -> 0

(* The verdict of a mutant that one executable saw as [a] and another as [b],
   as add states it. *)
let join a b =
  match (a, b) with
  | Verdicts.Survived x, Verdicts.Survived y ->
      Verdicts.survived ((x.first :: x.others) @ (y.first :: y.others))
  | Verdicts.Unknown x, Verdicts.Unknown y -> Verdicts.Unknown (min x y)
  | Verdicts.Killed_elsewhere x, Verdicts.Killed_elsewhere y ->
      Verdicts.Killed_elsewhere { exe = min x.exe y.exe }
  | _ -> if rank a >= rank b then a else b

let combined (a, b) =
  let m = id "lib/lattice.ml" 1 0 "add" in
  let t = collection [ record m a; record m b ] in
  equal verdict (join a b)
    (require_match
       (function [ r ] -> Some r.Verdicts.verdict | _ -> None)
       (Verdicts.records t))

let reaching = function
  | Verdicts.Survived { first; others } -> Some (first :: others)
  | _ -> None

let sorted_names ts =
  equal
    (list (list string))
    (List.sort_uniq compare ts)
    (require_match ~pp:pp_verdict reaching (Verdicts.survived ts))

let lattice_examples =
  let s = Verdicts.survived in
  let e exe = Verdicts.Killed_elsewhere { exe } in
  Verdicts.
    [
      (Killed, e "x");
      (e "x", Unknown "crashed");
      (e "x", Not_evaluated);
      (e "y", e "x");
      (s [ [ "a" ] ], e "x");
      (Unreached, e "x");
      (Killed, s [ [ "a" ] ]);
      (Unreached, Killed);
      (Unknown "crashed", Killed);
      (Unknown "crashed", s [ [ "a" ] ]);
      (Unknown "crashed", Not_evaluated);
      (Unknown "refused", Unknown "crashed");
      (Not_evaluated, s [ [ "a" ] ]);
      (Outside_tests, s [ [ "a" ] ]);
      (Not_evaluated, Outside_tests);
      (Unreached, Outside_tests);
      (s [ [ "b" ]; [ "a" ] ], s [ [ "c" ]; [ "b" ] ]);
    ]

let outcome_cases =
  [
    ("Killed", Verdicts.Killed, Some "killed");
    ( "Killed_elsewhere",
      Verdicts.Killed_elsewhere { exe = "default/test/a.exe" },
      None );
    ("Unknown", Verdicts.Unknown "crashed", None);
    ("Survived", Verdicts.survived [ [ "t" ] ], Some "survived");
    ("Not_evaluated", Verdicts.Not_evaluated, Some "not evaluated");
    ("Outside_tests", Verdicts.Outside_tests, None);
    ("Unreached", Verdicts.Unreached, None);
  ]

let outcome (_, verdict, expected) =
  equal (option string) expected
    (Option.map outcome_row (Verdicts.outcome verdict))

let verdicts =
  group "Verdicts"
    [
      cases "outcome is the verdict that the tests of a suite give"
        ~id:(fun (name, _, _) -> name)
        outcome_cases outcome;
      prop "survived sorts its reaching tests and drops duplicates"
        ~examples:[ [ [ "b" ]; [ "a" ]; [ "b" ] ] ]
        (Gen.list ~size:(Gen.int_range 1 4)
           (Gen.list ~size:(Gen.int_range 0 2) (Gen.of_list [ "a"; "b"; "" ])))
        sorted_names;
      test "survived raises Invalid_argument on no reaching test" (fun () ->
          raises
            (Invalid_argument
               "Windtrap_runtime.Verdicts.survived: a survivor names at least \
                one test") (fun () -> Verdicts.survived []));
    ]

(* Collections *)

let record_of_mutant () =
  let m =
    {
      Mutate.id = id "lib/calc.ml" 4 2 "sub";
      end_line = 4;
      end_col = 7;
      before = "a - b";
      after = "a + b";
      dismissed = Some "equivalent";
      source_digest = Some (String.make 32 'a');
    }
  in
  equal string
    {|"lib/calc.ml":4:2:sub (to 4:7) "a - b" -> "a + b" of aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: killed|}
    (record_row (Verdicts.record_of_mutant m Verdicts.Killed));
  equal string {|"lib/calc.ml":4:2:sub (to 4:7) "a - b" -> "a + b": killed|}
    (record_row
       (Verdicts.record_of_mutant
          { m with source_digest = None }
          Verdicts.Killed))

(* The previous outcomes of two records combine as their verdicts do, and a
   missing one leaves the other unchanged. *)
let join_previous a b =
  let verdict = function
    | `Killed -> Verdicts.Killed
    | `Survived -> Verdicts.survived [ [ "t" ] ]
    | `Not_evaluated -> Verdicts.Not_evaluated
  in
  match (a, b) with
  | None, p | p, None -> p
  | Some x, Some y -> Verdicts.outcome (join (verdict x) (verdict y))

(* Two records of one mutant keep the smaller rendering, and the verdict and
   the previous outcome both combine into, in either order. *)
let kept_rendering (a, b) =
  let key (r : Verdicts.record) =
    (r.before, r.after, r.end_line, r.end_col, r.source_digest)
  in
  let a = { a with Verdicts.id = b.Verdicts.id } in
  let smaller = if compare (key a) (key b) <= 0 then a else b in
  let expected =
    [
      {
        smaller with
        verdict = join a.verdict b.verdict;
        previous = join_previous a.previous b.previous;
      };
    ]
  in
  equal records (collection expected) (collection [ a; b ]);
  equal records (collection expected) (collection [ b; a ])

let ordered added =
  let ids records =
    List.map (fun (r : Verdicts.record) -> Mutate.id_to_string r.id) records
  in
  equal (list string)
    (ids
       (List.sort_uniq
          (fun (a : Verdicts.record) b -> Mutate.compare_id a.id b.id)
          added))
    (ids (Verdicts.records (collection added)))

let changed_cases =
  let s = Verdicts.survived [ [ "t" ] ] in
  [
    ("no previous outcome", None, Verdicts.Killed, None);
    ( "survived to killed",
      Some `Survived,
      Verdicts.Killed,
      Some "survived, killed" );
    ("killed to survived", Some `Killed, s, Some "killed, survived");
    ( "not evaluated to killed",
      Some `Not_evaluated,
      Verdicts.Killed,
      Some "not evaluated, killed" );
    ( "survived to not evaluated",
      Some `Survived,
      Verdicts.Not_evaluated,
      Some "survived, not evaluated" );
    ("killed to killed", Some `Killed, Verdicts.Killed, None);
    ( "survived to other reaching tests",
      Some `Survived,
      Verdicts.survived [ [ "a" ]; [ "b" ] ],
      None );
    ( "survived to killed elsewhere",
      Some `Survived,
      Verdicts.Killed_elsewhere { exe = "x" },
      None );
    ("killed to unknown", Some `Killed, Verdicts.Unknown "crashed", None);
    ("survived to unreached", Some `Survived, Verdicts.Unreached, None);
    ("killed to outside tests", Some `Killed, Verdicts.Outside_tests, None);
  ]

let changed (_, previous, verdict, expected) =
  let r = record ?previous (id "lib/a.ml" 1 0 "lt") verdict in
  equal (option string) expected
    (Option.map
       (fun (was, is) -> outcome_row was ^ ", " ^ outcome_row is)
       (Verdicts.changed r))

let source = String.make 32 'a'

(* The collection that [with_previous] reads: one record of [m]. *)
let prior ?(source_digest = Some source) ?(before = "b") ?previous verdict =
  collection
    [ record ?source_digest ~before ?previous (id "lib/a.ml" 1 0 "lt") verdict ]

let with_previous_cases =
  let m = id "lib/a.ml" 1 0 "lt" in
  let s = Verdicts.survived [ [ "t" ] ] in
  let other = String.make 32 'b' in
  let r = record ~source_digest:source m Verdicts.Killed in
  [
    ("the same mutant", prior ~previous:`Killed s, r, Some "survived");
    ( "another digest",
      prior s,
      record ~source_digest:other m Verdicts.Killed,
      None );
    ("no digest in the collection", prior s, record m Verdicts.Killed, None);
    ("no digest in the prior", prior ~source_digest:None s, r, None);
    ("another rendering", prior ~before:"c" s, r, None);
    ( "another end",
      prior s,
      record ~source_digest:source ~end_:(2, 0) m Verdicts.Killed,
      None );
    ( "another identifier",
      prior s,
      record ~source_digest:source (id "lib/b.ml" 1 0 "lt") Verdicts.Killed,
      None );
    ( "a previous outcome of its own and no prior record",
      Verdicts.empty,
      record ~source_digest:source ~previous:`Survived m Verdicts.Killed,
      None );
    ( "a prior skip keeps the outcome before it",
      prior ~previous:`Survived (Verdicts.Killed_elsewhere { exe = "x" }),
      r,
      Some "survived" );
    ( "a prior skip with no outcome before it",
      prior (Verdicts.Killed_elsewhere { exe = "x" }),
      r,
      None );
    ( "a prior unknown verdict keeps the outcome before it",
      prior ~previous:`Not_evaluated (Verdicts.Unknown "crashed"),
      r,
      Some "not evaluated" );
    ( "a prior unreached mutant keeps the outcome before it",
      prior ~previous:`Survived Verdicts.Unreached,
      r,
      Some "survived" );
  ]

let with_previous (_, prior, r, expected) =
  equal
    (list (option string))
    [ expected ]
    (List.map
       (fun (r : Verdicts.record) -> Option.map outcome_row r.previous)
       (Verdicts.records (Verdicts.with_previous ~prior (collection [ r ]))))

(* The oracle: a record takes the outcome of the prior record of the same
   mutant, or the previous outcome of that record when its verdict is no
   outcome. *)
let with_previous_oracle (prior, t) =
  let expected (r : Verdicts.record) =
    let previous =
      List.find_map
        (fun (p : Verdicts.record) ->
          if
            Mutate.compare_id p.id r.id = 0
            && r.source_digest <> None
            && p.source_digest = r.source_digest
            && (p.before, p.after, p.end_line, p.end_col)
               = (r.before, r.after, r.end_line, r.end_col)
          then
            Some
              (match Verdicts.outcome p.verdict with
              | Some o -> Some o
              | None -> p.previous)
          else None)
        (Verdicts.records prior)
    in
    record_row { r with previous = Option.join previous }
  in
  equal (list string)
    (List.map expected (Verdicts.records t))
    (rows (Verdicts.with_previous ~prior t))

let with_previous_keeps_the_rest (prior, t) =
  let bare t =
    List.map
      (fun (r : Verdicts.record) -> record_row { r with previous = None })
      (Verdicts.records t)
  in
  equal (list string) (bare t) (bare (Verdicts.with_previous ~prior t))

let commutes (a, b) = equal records (Verdicts.merge a b) (Verdicts.merge b a)

let associates (a, b, c) =
  equal records
    (Verdicts.merge (Verdicts.merge a b) c)
    (Verdicts.merge a (Verdicts.merge b c))

let idempotent a = equal records a (Verdicts.merge a a)

let empty_is_unit a =
  equal records a (Verdicts.merge a Verdicts.empty);
  equal records a (Verdicts.merge Verdicts.empty a)

let merge_is_add (a, b) =
  equal records
    (List.fold_left Verdicts.add a (Verdicts.records b))
    (Verdicts.merge a b)

let unreached_is_neutral a =
  let unreached =
    collection
      (List.map
         (fun (r : Verdicts.record) -> { r with verdict = Verdicts.Unreached })
         (Verdicts.records a))
  in
  equal records a (Verdicts.merge a unreached)

let unchecked_ids =
  [
    ("an empty file", id "" 1 0 "lt");
    ("line 0", id "a.ml" 0 0 "lt");
    ("a negative column", id "a.ml" 1 (-1) "lt");
    ("an unknown rewrite", id "a.ml" 1 0 "plus");
  ]

let unchecked (_, bad) =
  let t = Verdicts.add Verdicts.empty (record bad Verdicts.Unreached) in
  let path = Filename.concat (temp_dir ()) "bad.mutants" in
  Verdicts.save path t;
  equal (list string)
    [ Mutate.id_to_string bad ]
    (List.map
       (fun (r : Verdicts.record) -> Mutate.id_to_string r.id)
       (Verdicts.records t));
  equal string path (require_match corrupt_path (Verdicts.load path))

let unchecked_records =
  [
    ( "an empty killing executable",
      record (id "a.ml" 1 0 "lt") (Verdicts.Killed_elsewhere { exe = "" }) );
    ( "a short source digest",
      record ~source_digest:"abc" (id "a.ml" 1 0 "lt") Verdicts.Unreached );
    ( "an uppercase source digest",
      record ~source_digest:(String.make 32 'A') (id "a.ml" 1 0 "lt")
        Verdicts.Unreached );
  ]

let unchecked_record (_, bad) =
  let t = Verdicts.add Verdicts.empty bad in
  let path = Filename.concat (temp_dir ()) "bad.mutants" in
  Verdicts.save path t;
  equal (list string) [ record_row bad ] (rows t);
  equal string path (require_match corrupt_path (Verdicts.load path))

let collections =
  group "Collections"
    [
      test
        "record_of_mutant keeps the identifier, the renderings and the source \
         digest, not the dismissal"
        record_of_mutant;
      test "empty holds no record" (fun () ->
          equal (list string) [] (rows Verdicts.empty));
      prop
        "add combines two verdicts by Killed > Killed_elsewhere > Unknown > \
         Not_evaluated > Survived > Outside_tests > Unreached, keeps the \
         smaller killing executable, and unites the reaching tests"
        ~examples:lattice_examples
        (Gen.pair small_verdict small_verdict)
        combined;
      prop
        "add keeps the smaller (before, after, end, source digest) of two \
         records of a mutant"
        (Gen.pair small_record small_record)
        kept_rendering;
      test "add sorts a survivor's reaching tests and drops duplicates"
        (fun () ->
          let unsorted =
            Verdicts.Survived { first = [ "b" ]; others = [ [ "a" ]; [ "b" ] ] }
          in
          equal (list string)
            [
              {|"lib/a.ml":1:0:lt (to 1:1) "b" -> "a": survived by ["a"], ["b"]|};
            ]
            (rows (collection [ record (id "lib/a.ml" 1 0 "lt") unsorted ])));
      cases "changed is the change between a previous outcome and a verdict"
        ~id:(fun (name, _, _, _) -> name)
        changed_cases changed;
      cases
        "with_previous takes the outcome of the same mutant, with the same \
         source digest that is not None"
        ~id:(fun (name, _, _, _) -> name)
        with_previous_cases with_previous;
      prop "with_previous sets the previous outcome by the rule of the mutant"
        (Gen.pair small_collection small_collection)
        with_previous_oracle;
      prop "with_previous changes no identifier, rendering, digest or verdict"
        (Gen.pair small_collection small_collection)
        with_previous_keeps_the_rest;
      prop "records are in identifier order, one for each identifier"
        (Gen.list ~size:(Gen.int_range 0 6) small_record)
        ordered;
      prop "merge is commutative"
        (Gen.pair small_collection small_collection)
        commutes;
      prop "merge is associative"
        (Gen.triple small_collection small_collection small_collection)
        associates;
      prop "merge is idempotent" small_collection idempotent;
      prop "empty is the unit of merge" small_collection empty_is_unit;
      prop "merge combines two records of a mutant as add does"
        (Gen.pair small_collection small_collection)
        merge_is_add;
      prop "an Unreached verdict leaves the verdict it is merged with unchanged"
        small_collection unreached_is_neutral;
      cases "add checks no identifier, and load refuses the file save writes"
        ~id:fst unchecked_ids unchecked;
      cases
        "add checks no killing executable and no source digest, and load \
         refuses the file save writes"
        ~id:fst unchecked_records unchecked_record;
    ]

(* Verdict files *)

let sample =
  collection
    [
      record ~before:"a - b" ~after:"a + b" (id "lib/a.ml" 1 2 "add")
        Verdicts.Unreached;
      record ~before:"p && q" ~after:"not (p && q)" ~previous:`Not_evaluated
        (id "lib/b.ml" 3 4 "not") Verdicts.Killed;
      record ~before:"a || b" ~after:"a && b" ~previous:`Killed
        (id "lib/b.ml" 5 0 "or")
        (Verdicts.survived [ [ "y"; "z" ]; [ "x" ] ]);
      record ~before:"a + b" ~after:"a - b" (id "lib/c.ml" 7 1 "sub")
        Verdicts.Not_evaluated;
      record ~before:"a - b" ~after:"a + b" (id "lib/c.ml" 9 0 "add")
        Verdicts.Outside_tests;
      record ~before:"a < b" ~after:"a <= b" (id "lib/c.ml" 11 3 "le")
        (Verdicts.Unknown "its run was killed by SIGSEGV");
      record ~before:"a - b" ~after:"a + b" ~source_digest:(String.make 32 'c')
        (id "lib/d.ml" 1 0 "add")
        (Verdicts.Killed_elsewhere { exe = "default/test/a.exe" });
    ]

let digest = String.make 32 'a'

let round_trip (identity, suite, t) =
  let path = Filename.concat (temp_dir ()) "saved.mutants" in
  Verdicts.save ?identity ?suite path t;
  let loaded = Verdicts.load path in
  equal
    (result (pair (list string) (option string)) string)
    (Ok (rows t, Option.map identity_row identity))
    (load_rows loaded);
  equal (option string) suite
    (Result.fold
       ~ok:(fun (f : Verdicts.file) -> f.suite)
       ~error:(fun _ -> None)
       loaded)

let order_free records =
  let dir = temp_dir () in
  let saved name t =
    let path = Filename.concat dir name in
    Verdicts.save path t;
    read path
  in
  equal string
    (saved "a.mutants" (collection records))
    (saved "b.mutants" (collection (List.rev records)))

let refusal () =
  let path = Filename.concat (temp_dir ()) "saved.mutants" in
  let reason = "the suite is not deterministic:\nfailed twice" in
  Verdicts.save ~refused:reason path sample;
  expect_exact
    (String.concat "\n"
       (List.filteri (fun i _ -> i < 3) (String.split_on_char '\n' (read path))))
  @@ __POS_OF__
       {|windtrap-mutants-v13
refused 44 the suite is not deterministic:
failed twice|};
  equal (option string) (Some reason)
    (Result.fold
       ~ok:(fun (f : Verdicts.file) -> f.refused)
       ~error:(fun _ -> None)
       (Verdicts.load path))

let replaced () =
  let path = Filename.concat (temp_dir ()) "saved.mutants" in
  Verdicts.save ~identity:{ exe = "test/a.exe"; digest } path sample;
  Verdicts.save path Verdicts.empty;
  equal
    (result (pair (list string) (option string)) string)
    (Ok ([], None))
    (load_rows (Verdicts.load path))

let bad_identities =
  [
    ("an empty exe", { Verdicts.exe = ""; digest });
    ("a short digest", { exe = "a"; digest = "abc" });
    ("an uppercase digest", { exe = "a"; digest = String.make 32 'A' });
    ( "a digest that is not hexadecimal",
      { exe = "a"; digest = String.make 32 'x' } );
  ]

let refused_identity (_, identity) =
  let dir = temp_dir () in
  raises_match (Exn.invalid_arg ~sub:"Windtrap_runtime.Verdicts") (fun () ->
      Verdicts.save ~identity
        (Filename.concat dir "unwritten.mutants")
        Verdicts.empty);
  equal (list string) [] (Array.to_list (Sys.readdir dir))

let headers =
  [
    ("the empty file", "");
    ("a coverage file", "windtrap-coverage-v3\n1\n");
    ("the upstream version before", "windtrap-mutants-v5\ntested\n0\n");
    ("the version before", "windtrap-mutants-v12\ntested\n0\n");
    ("two versions before", "windtrap-mutants-v11\ntested\n0\n");
    ("a fork version before", "windtrap-mutants-v10\ntested\n0\n");
    ("a later version", "windtrap-mutants-v14\ntested\n0\n");
    ("the magic in uppercase", "WINDTRAP-MUTANTS-V1\n0\n");
    ("the magic and a digit", "windtrap-mutants-v130\ntested\n0\n");
    ("plain text", "hello\nworld\n");
  ]

let unknown_format (_, text) =
  let path, loaded = load_text text in
  equal string path
    (require_match
       (function
         | Error (Verdicts.Unknown_format { path; _ }) -> Some path | _ -> None)
       loaded)

let record_prefix = "windtrap-mutants-v13\ntested\n1\n8 lib/a.ml "

let corrupt_files =
  [
    ("the magic line alone", "windtrap-mutants-v13");
    ("a negative record count", "windtrap-mutants-v13\ntested\n-1\n");
    ("a record count past the input", "windtrap-mutants-v13\ntested\n99999999\n");
    ( "fewer records than the count",
      "windtrap-mutants-v13\n\
       tested\n\
       2\n\
       8 lib/a.ml 1 2 1 5 3 add 1 b 1 a 0  unreached none\n" );
    ( "an empty file name",
      "windtrap-mutants-v13\n\
       tested\n\
       1\n\
       0  1 2 1 5 3 add 0 0 1 b 1 a 0  unreached\n" );
    ( "a file name past the input",
      "windtrap-mutants-v13\n\
       tested\n\
       1\n\
       80 lib/a.ml 1 2 1 5 3 add 1 b 1 a 0  unreached\n" );
    ("line 0", record_prefix ^ "0 2 1 5 3 add 1 b 1 a 0  unreached\n");
    ("a negative line", record_prefix ^ "-3 2 1 5 3 add 1 b 1 a 0  unreached\n");
    ("a negative column", record_prefix ^ "1 -2 3 add 1 b 1 a 0  unreached\n");
    ("no end", record_prefix ^ "1 2 3 add 1 b 1 a 0  unreached\n");
    ( "an end column before the start",
      record_prefix ^ "1 2 1 1 3 add 1 b 1 a 0  unreached\n" );
    ( "an end line before the start",
      record_prefix ^ "2 2 1 5 3 add 1 b 1 a 0  unreached\n" );
    ( "a negative end column",
      record_prefix ^ "1 2 1 -5 3 add 1 b 1 a 0  unreached\n" );
    ( "a rewrite past the input",
      record_prefix ^ "1 2 1 5 30 add 1 b 1 a 0  unreached\n" );
    ( "an unknown rewrite",
      record_prefix ^ "1 2 1 5 4 plus 1 b 1 a 0  unreached\n" );
    ( "drop, which no instrumenter emits",
      record_prefix ^ "1 2 1 5 4 drop 1 b 1 a 0  unreached\n" );
    ( "a before past the input",
      record_prefix ^ "1 2 1 5 3 add 80 b 1 a 0  unreached\n" );
    ("no rendering", record_prefix ^ "1 2 1 5 3 add unreached\n");
    ( "an after past the input",
      record_prefix ^ "1 2 1 5 3 add 1 b 80 a unreached\n" );
    ("an unknown verdict", record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  errored\n");
    ("no verdict", record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0 \n");
    ("no source digest", record_prefix ^ "1 2 1 5 3 add 1 b 1 a\n");
    ( "a short source digest",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 3 abc unreached\n" );
    ( "an uppercase source digest",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 32 " ^ String.make 32 'A'
      ^ " unreached\n" );
    ( "a killing executable that is empty",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  killed_elsewhere 0 \n" );
    ( "no killing executable",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  killed_elsewhere\n" );
    ( "a survivor with no reaching test",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  survived 0\n" );
    ( "a reaching test count past the input",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  survived 99999999\n" );
    ( "a negative test path length",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  survived 1 -1\n" );
    ( "a test path shorter than its length",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  survived 2 1 1 g\n" );
    ( "a test name past the input",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  survived 1 1 80 g\n" );
    ( "two records of one identifier",
      "windtrap-mutants-v13\n\
       tested\n\
       2\n\
       8 lib/a.ml 1 2 1 5 3 add 1 b 1 a 0  unreached none\n\
       8 lib/a.ml 1 2 1 5 3 add 1 b 1 a 0  killed none\n" );
    ( "a malformed record after a valid one",
      "windtrap-mutants-v13\n\
       tested\n\
       2\n\
       8 lib/a.ml 1 2 1 5 3 add 1 b 1 a 0  killed none\n\
       8 lib/a.ml 0 2 1 5 3 add 1 b 1 a 0  unreached none\n" );
    ("no previous outcome", record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  killed\n");
    ( "an unknown previous outcome",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  killed maybe\n" );
    ( "was and no outcome",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  killed was\n" );
    ( "a previous verdict that is no outcome",
      record_prefix ^ "1 2 1 5 3 add 1 b 1 a 0  killed was unreached\n" );
    ("a short identity digest", "windtrap-mutants-v13\nexe abcd 1 a\n0\n");
    ("an empty identity exe", "windtrap-mutants-v13\nexe " ^ digest ^ " 0 \n0\n");
    ("no status", "windtrap-mutants-v13\n0\n");
    ("an unknown status", "windtrap-mutants-v13\nwhole\n0\n");
    ("a refusal past the input", "windtrap-mutants-v13\nrefused 80 r\n0\n");
    ("a suite past the input", "windtrap-mutants-v13\nsuite 80 s\ntested\n0\n");
    ("a suite and no status", "windtrap-mutants-v13\nsuite 1 s\n0\n");
    ( "two suite lines",
      "windtrap-mutants-v13\nsuite 1 s\nsuite 1 t\ntested\n0\n" );
    ( "a suite before the identity",
      "windtrap-mutants-v13\nsuite 1 s\nexe " ^ digest ^ " 1 a\ntested\n0\n" );
    ("bytes after the last record", "windtrap-mutants-v13\ntested\n0\nextra\n");
  ]

let corrupt (_, text) =
  let path, loaded = load_text text in
  equal string path (require_match corrupt_path loaded)

let corrupt_reasons () =
  let reason (name, text) =
    match snd (load_text text) with
    | Error (Corrupt { reason; _ }) -> strf "%s: %s" name reason
    | Error (Unknown_format _ | Unreadable _) | Ok _ -> name ^ ": not corrupt"
  in
  expect (String.concat "\n" (List.map reason corrupt_files))
  @@ __POS_OF__
       {|
    the magic line alone: expected status at offset 20
    a negative record count: negative record count
    a record count past the input: record count exceeds data
    fewer records than the count: expected file name length at offset 81
    an empty file name: empty file name
    a file name past the input: truncated file name
    line 0: line 0 is not 1-based
    a negative line: negative line
    a negative column: negative column
    no end: expected end column at offset 47
    an end column before the start: end 1:1 before start 1:2
    an end line before the start: end 1:5 before start 2:2
    a negative end column: negative end column
    a rewrite past the input: truncated rewrite
    an unknown rewrite: unknown rewrite "plus"
    drop, which no instrumenter emits: unknown rewrite "drop"
    a before past the input: truncated before
    no rendering: expected before length at offset 55
    an after past the input: truncated after
    an unknown verdict: unknown verdict "errored"
    no verdict: expected verdict at offset 66
    no source digest: expected source digest length at offset 63
    a short source digest: "abc" is not a source digest
    an uppercase source digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" is not a source digest
    a killing executable that is empty: empty killing executable
    no killing executable: expected killing executable length at offset 83
    a survivor with no reaching test: a survivor names no test (survived is not unreached)
    a reaching test count past the input: reaching test count exceeds data
    a negative test path length: negative test path length
    a test path shorter than its length: expected test path length at offset 83
    a test name past the input: truncated test name
    two records of one identifier: duplicate record for lib/a.ml:1:2:add
    a malformed record after a valid one: line 0 is not 1-based
    no previous outcome: expected previous outcome at offset 73
    an unknown previous outcome: unknown previous outcome "maybe"
    was and no outcome: expected previous outcome at offset 77
    a previous verdict that is no outcome: unknown previous outcome "unreached"
    a short identity digest: identity digest is not 32 hex characters at offset 25
    an empty identity exe: empty executable identity
    no status: unknown status "0"
    an unknown status: unknown status "whole"
    a refusal past the input: truncated refusal
    a suite past the input: truncated suite
    a suite and no status: unknown status "0"
    two suite lines: unknown status "suite"
    a suite before the identity: unknown status "exe"
    bytes after the last record: trailing data at offset 30
    |}

let error_messages () =
  let pp e = Format.asprintf "%a" Verdicts.pp_error e in
  expect
    (String.concat "\n"
       [
         pp (Unknown_format { path = "f.mutants"; header = "junk" });
         pp
           (Unreadable
              { path = "f.mutants"; reason = "No such file or directory" });
         pp
           (Corrupt
              { path = "f.mutants"; reason = "unknown verdict \"errored\"" });
       ])
  @@ __POS_OF__
       {|
    f.mutants: not a windtrap verdict file (expected header "windtrap-mutants-v13", found "junk"); files written by other windtrap versions are not readable - delete the stale verdict files, then re-run the mutation tests
    f.mutants: cannot read verdict file: No such file or directory
    f.mutants: corrupt verdict file: unknown verdict "errored"
    |}

(* Below a build directory, the identity is not the path. *)
let writer () =
  let build = Filename.concat (temp_dir ()) "_build" in
  Sys.mkdir build 0o755;
  let exe = Filename.concat build "t.exe" in
  Out_channel.with_open_bin exe (fun oc -> output_string oc "an executable");
  let digest = require_some (Instr.file_digest exe) in
  equal (option identity)
    (Some { Verdicts.exe = Instr.exe_identity ~exe; digest })
    (Verdicts.writer_identity ~exe)

let files =
  group "Verdict files"
    [
      test
        "format is the magic line, the mutants directory and extension, and \
         the verdict kind" (fun () ->
          equal (list string)
            [ "windtrap-mutants-v13"; "mutants"; "mutants"; "verdict" ]
            Verdicts.[ format.magic; format.dir; format.ext; format.kind ]);
      test
        "save writes the magic line, the count, then the records by identifier"
        (fun () ->
          expect_exact (saved sample)
          @@ __POS_OF__
               {|windtrap-mutants-v13
tested
7
8 lib/a.ml 1 2 1 7 3 add 5 a - b 5 a + b 0  unreached none
8 lib/b.ml 3 4 3 10 3 not 6 p && q 12 not (p && q) 0  killed was not_evaluated
8 lib/b.ml 5 0 5 6 2 or 6 a || b 6 a && b 0  survived 2 1 1 x 2 1 y 1 z was killed
8 lib/c.ml 7 1 7 6 3 sub 5 a + b 5 a - b 0  not_evaluated none
8 lib/c.ml 9 0 9 5 3 add 5 a - b 5 a + b 0  outside_tests none
8 lib/c.ml 11 3 11 8 2 le 5 a < b 6 a <= b 0  unknown 29 its run was killed by SIGSEGV none
8 lib/d.ml 1 0 1 5 3 add 5 a - b 5 a + b 32 cccccccccccccccccccccccccccccccc killed_elsewhere 18 default/test/a.exe none
|});
      test "save writes an identity after the magic line" (fun () ->
          expect_exact
            (saved ~identity:{ exe = "test/a.exe"; digest } Verdicts.empty)
          @@ __POS_OF__
               {|windtrap-mutants-v13
exe aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10 test/a.exe
tested
0
|});
      test "save writes the suite after the identity, as a name" (fun () ->
          expect_exact
            (saved
               ~identity:{ exe = "test/a.exe"; digest }
               ~suite:"lib/a b.ml\n" Verdicts.empty)
          @@ __POS_OF__
               {|windtrap-mutants-v13
exe aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10 test/a.exe
suite 11 lib/a b.ml

tested
0
|});
      test "save writes a refusal after the identity, and load reads it" refusal;
      test "load reads back a previous outcome of every kind" (fun () ->
          let t =
            collection
              (List.mapi
                 (fun i previous ->
                   record ?previous
                     (id "lib/a.ml" (i + 1) 0 "lt")
                     (Verdicts.Unknown "crashed"))
                 [ None; Some `Killed; Some `Survived; Some `Not_evaluated ])
          in
          let path = Filename.concat (temp_dir ()) "saved.mutants" in
          Verdicts.save path t;
          equal
            (result (list string) string)
            (Ok
               [
                 {|"lib/a.ml":1:0:lt (to 1:1) "b" -> "a": unknown: crashed|};
                 {|"lib/a.ml":2:0:lt (to 2:1) "b" -> "a": unknown: crashed was killed|};
                 {|"lib/a.ml":3:0:lt (to 3:1) "b" -> "a": unknown: crashed was survived|};
                 {|"lib/a.ml":4:0:lt (to 4:1) "b" -> "a": unknown: crashed was not evaluated|};
               ])
            (Result.map fst (load_rows (Verdicts.load path))));
      prop "load reads back what save wrote, identity and suite included"
        any_file round_trip;
      prop
        "save writes one file for a collection, whatever the order of its adds"
        (Gen.list ~size:(Gen.int_range 0 6) small_record)
        order_free;
      test "save replaces the file, identity included" replaced;
      cases
        "save raises Invalid_argument on a malformed identity and writes \
         nothing"
        ~id:fst bad_identities refused_identity;
      cases "load refuses another first line as Unknown_format, naming the path"
        ~id:fst headers unknown_format;
      cases "load refuses malformed data as Corrupt, naming the path" ~id:fst
        corrupt_files corrupt;
      test "a Corrupt reason names the field and its fault" corrupt_reasons;
      test "load of a missing file is Unreadable, naming the path" (fun () ->
          let path = Filename.concat (temp_dir ()) "missing.mutants" in
          equal string ("unreadable " ^ path)
            (Result.fold
               ~ok:(fun _ -> "loaded")
               ~error:error_row (Verdicts.load path)));
      test "pp_error names the file, the fault and what to do" error_messages;
      test
        "output_file is Instr.output_dir of format, then the digest of the \
         suite" (fun () ->
          let exe = "/w/p/_build/default/test/t.exe" in
          equal string
            (strf "%s-%s.mutants"
               (Instr.output_dir Verdicts.format ~exe)
               (Digest.to_hex (Digest.string "lib/a.ml")))
            (Verdicts.output_file ~exe ~suite:"lib/a.ml"));
      test "output_file gives each suite of an executable its own file"
        (fun () ->
          let exe = "/w/p/_build/default/test/t.exe" in
          let suites = [ ""; "adds"; "Adds"; "subs"; "lib/a.ml"; "lib_a.ml" ] in
          let files =
            List.map (fun suite -> Verdicts.output_file ~exe ~suite) suites
          in
          equal int (List.length suites)
            (List.length (List.sort_uniq String.compare files)));
      test "writer_identity is the executable's identity and digest" writer;
      test "writer_identity is None for a file that cannot be read" (fun () ->
          is_none ~pp:pp_identity
            (Verdicts.writer_identity
               ~exe:(Filename.concat (temp_dir ()) "no-such.exe")));
    ]

let () = exit (run "verdicts" [ verdicts; collections; files ])
