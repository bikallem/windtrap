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

let record ?(before = "b") ?(after = "a") ?source_digest ?previous id verdict =
  { Verdicts.id; before; after; source_digest; verdict; previous }

let killed = Verdicts.Killed { by = None }
let killed_by test = Verdicts.Killed { by = Some test }
let collection records = List.fold_left Verdicts.add Verdicts.empty records

(* Rows. Every string is quoted, so a row tells any two values apart. *)

let quoted names = String.concat " " (List.map (strf "%S") names)

let verdict_row = function
  | Verdicts.Killed { by = None } -> "killed"
  | Killed { by = Some test } -> "killed by [" ^ quoted test ^ "]"
  | Survived { first; others; runs } ->
      "survived by "
      ^ String.concat ", "
          (List.map (fun t -> "[" ^ quoted t ^ "]") (first :: others))
      ^ if runs = 1 then "" else strf " (%d runs)" runs
  | Killed_elsewhere { exe } -> strf "killed elsewhere by %S" exe
  | Flaky { test; failure } -> strf "flaky by [%s]: %S" (quoted test) failure
  | Not_evaluated -> "not evaluated"
  | Outside_tests -> "outside tests"
  | Filtered reason -> strf "filtered %S" reason
  | Unreached -> "unreached"

let record_row (r : Verdicts.record) =
  strf "%S:%d:%d:%s %S -> %S%s: %s%s" r.id.file r.id.line r.id.col r.id.rewrite
    r.before r.after
    (Option.fold ~none:"" ~some:(strf " in %s") r.source_digest)
    (verdict_row r.verdict)
    (match r.previous with None -> "" | Some v -> " was " ^ verdict_row v)

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
  | Ok (t, i, suite) -> Ok (rows t, Option.map identity_row i, suite)
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
  (* One case in 8 saturates the sum of the runs of a merge. *)
  let runs =
    Gen.frequency [ (7, Gen.int_range 1 3); (1, Gen.constant max_int) ]
  in
  Gen.with_pp pp_verdict
    (Gen.frequency
       [
         (1, Gen.constant killed);
         (1, Gen.map killed_by path);
         ( 1,
           Gen.map
             (fun exe -> Verdicts.Killed_elsewhere { exe })
             (Gen.of_list [ "x"; "y" ]) );
         ( 1,
           Gen.map
             (fun (test, failure) -> Verdicts.Flaky { test; failure })
             (Gen.pair path (Gen.of_list [ "e"; "f" ])) );
         (1, Gen.constant Verdicts.Not_evaluated);
         ( 3,
           Gen.map
             (fun (runs, ts) -> Verdicts.survived ~runs ts)
             (Gen.pair runs (Gen.list ~size:(Gen.int_range 1 3) path)) );
         (1, Gen.constant Verdicts.Outside_tests);
         (1, Gen.map (fun r -> Verdicts.Filtered r) (Gen.of_list [ "a"; "b" ]));
         (1, Gen.constant Verdicts.Unreached);
       ])

let small_record =
  Gen.with_pp pp_record
    (Gen.map
       (fun ((file, line, (before, after, source_digest), verdict), previous) ->
         record ~before ~after ?source_digest ?previous (id file line 0 "lt")
           verdict)
       (Gen.pair
          (Gen.quad
             (Gen.of_list [ "lib/a.ml"; "lib/b.ml" ])
             (Gen.int_range 1 2)
             (Gen.triple
                (Gen.of_list [ "a"; "b" ])
                (Gen.of_list [ "a"; "b" ])
                (Gen.of_list [ None; Some (String.make 32 'a') ]))
             small_verdict)
          (Gen.option small_verdict)))

let small_collection =
  Gen.with_pp pp_records
    (Gen.map collection (Gen.list ~size:(Gen.int_range 0 6) small_record))

(* Any bytes in every name, and any identifier that load accepts. *)
let hex_digest =
  Gen.string_of ~size:(Gen.constant 32)
    (Gen.of_list (List.of_seq (String.to_seq "0123456789abcdef")))

let any_record =
  let name = Gen.string in
  let path = Gen.list ~size:(Gen.int_range 0 3) name in
  let verdict =
    Gen.one_of
      [
        Gen.of_list Verdicts.[ killed; Not_evaluated; Outside_tests; Unreached ];
        Gen.map killed_by path;
        Gen.map (fun e -> Verdicts.Killed_elsewhere { exe = "e" ^ e }) name;
        Gen.map
          (fun (test, failure) -> Verdicts.Flaky { test; failure })
          (Gen.pair path name);
        Gen.map
          (fun (runs, ts) -> Verdicts.survived ~runs ts)
          (Gen.pair (Gen.int_range 1 3)
             (Gen.list ~size:(Gen.int_range 1 3) path));
        Gen.map (fun r -> Verdicts.Filtered r) name;
      ]
  in
  Gen.map
    (fun ( ((file, line, col, rewrite), (before, after), source_digest, verdict),
           previous ) ->
      record ~before ~after ?source_digest ?previous (id file line col rewrite)
        verdict)
    (Gen.pair
       (Gen.quad
          (Gen.quad
             (Gen.map (fun s -> "f" ^ s) name)
             (Gen.map succ Gen.nat) Gen.nat
             (Gen.of_list Mutate.rewrites))
          (Gen.pair name name) (Gen.option hex_digest) verdict)
       (Gen.option verdict))

let any_identity =
  Gen.option
    (Gen.with_pp pp_identity
       (Gen.map
          (fun (exe, digest) -> { Verdicts.exe = "e" ^ exe; digest })
          (Gen.pair Gen.string hex_digest)))

let any_file =
  Gen.triple any_identity
    (Gen.option (Gen.with_pp Format.pp_print_string Gen.string))
    (Gen.with_pp pp_records
       (Gen.map collection (Gen.list ~size:(Gen.int_range 0 5) any_record)))

(* Verdicts *)

let rank = function
  | Verdicts.Killed _ -> 7
  | Killed_elsewhere _ -> 6
  | Flaky _ -> 5
  | Not_evaluated -> 4
  | Survived _ -> 3
  | Outside_tests -> 2
  | Filtered _ -> 1
  | Unreached -> 0

(* The sum of two runs, saturated at [max_int]. *)
let add_runs a b = if a > max_int - b then max_int else a + b

(* The verdict of a mutant that one executable saw as [a] and another as [b],
   as add states it. *)
let join a b =
  match (a, b) with
  | Verdicts.Survived x, Verdicts.Survived y ->
      Verdicts.survived ~runs:(add_runs x.runs y.runs)
        ((x.first :: x.others) @ (y.first :: y.others))
  | Killed { by = Some x }, Killed { by = Some y } -> killed_by (min x y)
  | Killed { by = None }, Killed { by } | Killed { by }, Killed { by = None } ->
      Killed { by }
  | Killed_elsewhere x, Killed_elsewhere y ->
      Killed_elsewhere { exe = min x.exe y.exe }
  | Filtered x, Filtered y -> Filtered (min x y)
  | Flaky x, Flaky y ->
      if compare (x.test, x.failure) (y.test, y.failure) <= 0 then Flaky x
      else Flaky y
  | _ -> if rank a >= rank b then a else b

let combined (a, b) =
  let m = id "lib/lattice.ml" 1 0 "add" in
  let t = collection [ record m a; record m b ] in
  equal verdict (join a b)
    (require_match
       (function [ r ] -> Some r.Verdicts.verdict | _ -> None)
       (Verdicts.records t))

let reaching = function
  | Verdicts.Survived { first; others; _ } -> Some (first :: others)
  | _ -> None

let sorted_names ts =
  equal
    (list (list string))
    (List.sort_uniq compare ts)
    (require_match ~pp:pp_verdict reaching (Verdicts.survived ts))

let lattice_examples =
  let s = Verdicts.survived in
  let e x = Verdicts.Killed_elsewhere { exe = x } in
  let f1 = Verdicts.Flaky { test = [ "b" ]; failure = "x" } in
  let f2 = Verdicts.Flaky { test = [ "a" ]; failure = "y" } in
  let f3 = Verdicts.Flaky { test = [ "a" ]; failure = "x" } in
  Verdicts.
    [
      (killed, s [ [ "a" ] ]);
      (Unreached, killed);
      (killed_by [ "b" ], killed_by [ "a"; "c" ]);
      (killed, killed_by [ "b" ]);
      (killed_by [ "b" ], Not_evaluated);
      (Not_evaluated, s [ [ "a" ] ]);
      (Outside_tests, s [ [ "a" ] ]);
      (Not_evaluated, Outside_tests);
      (Unreached, Outside_tests);
      (Filtered "a", killed);
      (killed_by [ "b" ], Filtered "a");
      (Filtered "a", s [ [ "a" ] ]);
      (Filtered "a", Outside_tests);
      (Unreached, Filtered "a");
      (Filtered "b", Filtered "a");
      (s [ [ "b" ]; [ "a" ] ], s [ [ "c" ]; [ "b" ] ]);
      (s ~runs:2 [ [ "a" ] ], s ~runs:3 [ [ "b" ] ]);
      (s ~runs:max_int [ [ "a" ] ], s [ [ "a" ] ]);
      (killed, e "x");
      (killed_by [ "b" ], e "x");
      (e "x", Not_evaluated);
      (e "y", e "x");
      (s [ [ "a" ] ], e "x");
      (Filtered "a", e "x");
      (Unreached, e "x");
      (killed, f1);
      (e "x", f1);
      (f1, Not_evaluated);
      (f1, s [ [ "a" ] ]);
      (Outside_tests, f1);
      (Filtered "a", f1);
      (Unreached, f1);
      (f1, f2);
      (f2, f3);
    ]

let class_name = function
  | `Killed -> "killed"
  | `Survived -> "survived"
  | `Not_evaluated -> "not evaluated"

let scored_cases =
  [
    ("Killed", killed, Some "killed");
    ("Killed with a test", killed_by [ "t" ], Some "killed");
    ("Killed_elsewhere", Verdicts.Killed_elsewhere { exe = "x" }, Some "killed");
    ("Flaky", Verdicts.Flaky { test = [ "t" ]; failure = "f" }, None);
    ("Survived", Verdicts.survived [ [ "t" ] ], Some "survived");
    ("Not_evaluated", Verdicts.Not_evaluated, Some "not evaluated");
    ("Outside_tests", Verdicts.Outside_tests, None);
    ("Filtered", Verdicts.Filtered "r", None);
    ("Unreached", Verdicts.Unreached, None);
  ]

let scored (_, verdict, expected) =
  equal (option string) expected
    (Option.map class_name (Verdicts.scored verdict))

let verdicts =
  group "Verdicts"
    [
      cases "scored is the class that a score counts"
        ~name:(fun (name, _, _) -> name)
        scored_cases scored;
      prop "survived sorts its reaching tests and drops duplicates"
        ~examples:[ [ [ "b" ]; [ "a" ]; [ "b" ] ] ]
        (Gen.list ~size:(Gen.int_range 1 4)
           (Gen.list ~size:(Gen.int_range 0 2) (Gen.of_list [ "a"; "b"; "" ])))
        sorted_names;
      test "survived has one run by default, and the runs it is given"
        (fun () ->
          let runs = function
            | Verdicts.Survived { runs; _ } -> Some runs
            | _ -> None
          in
          equal (option int) (Some 1) (runs (Verdicts.survived [ [ "t" ] ]));
          equal (option int) (Some 3)
            (runs (Verdicts.survived ~runs:3 [ [ "t" ] ])));
      test "survived raises Invalid_argument on no run" (fun () ->
          raises
            (Invalid_argument
               "Windtrap_runtime.Verdicts.survived: a survivor has at least \
                one run") (fun () -> Verdicts.survived ~runs:0 [ [ "t" ] ]));
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
      before = "a - b";
      after = "a + b";
      dismissed = Some (Mutate.Filtered "zero operand");
    }
  in
  equal (list string)
    [
      {|"lib/calc.ml":4:2:sub "a - b" -> "a + b": killed|};
      {|"lib/calc.ml":4:2:sub "a - b" -> "a + b" in 0123: killed by ["t"]|};
    ]
    [
      record_row (Verdicts.record_of_mutant m killed);
      record_row
        (Verdicts.record_of_mutant ~source_digest:"0123" m (killed_by [ "t" ]));
    ]

(* The previous verdicts of two records combine as the verdicts do, and a
   missing one leaves the other unchanged. *)
let join_previous a b =
  match (a, b) with None, x | x, None -> x | Some a, Some b -> Some (join a b)

(* Two records of one mutant keep the smaller rendering and digest and the
   verdict and previous verdict both combine into, in either order. *)
let kept_rendering (a, b) =
  let key (r : Verdicts.record) = (r.before, r.after, r.source_digest) in
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

let class_pair = Option.map (fun (a, b) -> (class_name a, class_name b))

let changed_cases =
  let s = Verdicts.survived [ [ "t" ] ] in
  let flaky = Verdicts.Flaky { test = [ "f" ]; failure = "x" } in
  let e = Verdicts.Killed_elsewhere { exe = "x" } in
  [
    ("no previous verdict", None, killed, None);
    ("survived to killed", Some s, killed, Some ("survived", "killed"));
    ("killed to survived", Some killed, s, Some ("killed", "survived"));
    ( "not evaluated to killed",
      Some Verdicts.Not_evaluated,
      killed_by [ "t" ],
      Some ("not evaluated", "killed") );
    ( "survived to not evaluated",
      Some s,
      Verdicts.Not_evaluated,
      Some ("survived", "not evaluated") );
    ("killed elsewhere to survived", Some e, s, Some ("killed", "survived"));
    ("another killing test", Some (killed_by [ "a" ]), killed_by [ "b" ], None);
    ("killed to killed elsewhere", Some killed, e, None);
    ( "other reaching tests",
      Some (Verdicts.survived [ [ "a" ] ]),
      Verdicts.survived [ [ "b" ]; [ "c" ] ],
      None );
    ( "more runs of a survivor",
      Some (Verdicts.survived ~runs:1 [ [ "t" ] ]),
      Verdicts.survived ~runs:3 [ [ "t" ] ],
      None );
    ("unreached to survived", Some Verdicts.Unreached, s, None);
    ("survived to unreached", Some s, Verdicts.Unreached, None);
    ("outside tests to killed", Some Verdicts.Outside_tests, killed, None);
    ("filtered to survived", Some (Verdicts.Filtered "r"), s, None);
    ("killed to filtered", Some killed, Verdicts.Filtered "r", None);
    ("killed to flaky", Some killed, flaky, None);
    ("flaky to survived", Some flaky, s, None);
  ]

let changed (_, previous, verdict, expected) =
  let r = record ?previous (id "lib/a.ml" 1 0 "lt") verdict in
  equal (option (pair string string)) expected (class_pair (Verdicts.changed r))

let source = String.make 32 'a'

(* The collection [with_previous] reads: one survivor that was killed before.
   Its own previous verdict is not the one a record takes. *)
let prior ?(source_digest = Some source) ?(runs = 1) () =
  collection
    [
      record ?source_digest ~previous:killed (id "lib/a.ml" 1 0 "lt")
        (Verdicts.survived ~runs [ [ "t" ] ]);
    ]

let with_previous_cases =
  let m = id "lib/a.ml" 1 0 "lt" in
  let row ?(file = "lib/a.ml") ?digest was =
    strf {|"%s":1:0:lt "b" -> "a"%s: killed%s|} file
      (Option.fold ~none:"" ~some:(strf " in %s") digest)
      was
  in
  let was = {| was survived by ["t"]|} in
  let other = String.make 32 'b' in
  [
    ( "the same identifier and digest",
      prior (),
      record ~source_digest:source m killed,
      row ~digest:source was );
    ( "another digest",
      prior (),
      record ~source_digest:other m killed,
      row ~digest:other "" );
    ( "the runs of the previous survivor",
      prior ~runs:3 (),
      record ~source_digest:source m killed,
      row ~digest:source {| was survived by ["t"] (3 runs)|} );
    ("no digest in the collection", prior (), record m killed, row "");
    ( "no digest in the prior",
      prior ~source_digest:None (),
      record ~source_digest:source m killed,
      row ~digest:source "" );
    ( "another identifier",
      prior (),
      record ~source_digest:source (id "lib/b.ml" 1 0 "lt") killed,
      row ~file:"lib/b.ml" ~digest:source "" );
    ( "a previous verdict of its own and no prior record",
      Verdicts.empty,
      record ~source_digest:source ~previous:killed m killed,
      row ~digest:source "" );
  ]

let with_previous (_, prior, r, expected) =
  equal (list string) [ expected ]
    (rows (Verdicts.with_previous ~prior (collection [ r ])))

(* The oracle: a record takes the verdict of the prior record of its
   identifier when the two have one digest, and the digest is not [None]. *)
let with_previous_oracle (prior, t) =
  let expected (r : Verdicts.record) =
    let previous =
      List.find_map
        (fun (p : Verdicts.record) ->
          if
            Mutate.compare_id p.id r.id = 0
            && p.source_digest = r.source_digest
            && r.source_digest <> None
          then Some p.verdict
          else None)
        (Verdicts.records prior)
    in
    record_row { r with previous }
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

(* [merge a a] is [a] with the runs of each survivor doubled. *)
let doubles a =
  let double = function
    | Verdicts.Survived s ->
        Verdicts.Survived { s with runs = add_runs s.runs s.runs }
    | v -> v
  in
  let doubled =
    collection
      (List.map
         (fun (r : Verdicts.record) ->
           {
             r with
             verdict = double r.verdict;
             previous = Option.map double r.previous;
           })
         (Verdicts.records a))
  in
  equal records doubled (Verdicts.merge a a)

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
  let verdicts t =
    List.map
      (fun (r : Verdicts.record) ->
        Mutate.id_to_string r.id ^ " " ^ verdict_row r.verdict)
      (Verdicts.records t)
  in
  equal (list string) (verdicts a) (verdicts (Verdicts.merge a unreached))

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

let collections =
  group "Collections"
    [
      test
        "record_of_mutant keeps the identifier, the renderings and the digest, \
         not the dismissal"
        record_of_mutant;
      test "empty holds no record" (fun () ->
          equal (list string) [] (rows Verdicts.empty));
      prop
        "add combines two verdicts by Killed > Killed_elsewhere > \
         Not_evaluated > Survived > Outside_tests > Filtered > Unreached, \
         keeps the smaller killing test and the smaller killing executable, \
         unites the reaching tests and keeps the smaller filter reason"
        ~examples:lattice_examples
        (Gen.pair small_verdict small_verdict)
        combined;
      prop
        "add keeps the smaller (before, after, source_digest) triple of two \
         records of a mutant"
        (Gen.pair small_record small_record)
        kept_rendering;
      test "add sorts a survivor's reaching tests and drops duplicates"
        (fun () ->
          let unsorted =
            Verdicts.Survived
              { first = [ "b" ]; others = [ [ "a" ]; [ "b" ] ]; runs = 1 }
          in
          equal (list string)
            [ {|"lib/a.ml":1:0:lt "b" -> "a": survived by ["a"], ["b"]|} ]
            (rows (collection [ record (id "lib/a.ml" 1 0 "lt") unsorted ])));
      test "add sorts the reaching tests of a previous survivor" (fun () ->
          let unsorted =
            Verdicts.Survived
              { first = [ "b" ]; others = [ [ "a" ]; [ "b" ] ]; runs = 1 }
          in
          equal (list string)
            [
              {|"lib/a.ml":1:0:lt "b" -> "a": killed was survived by ["a"], ["b"]|};
            ]
            (rows
               (collection
                  [ record ~previous:unsorted (id "lib/a.ml" 1 0 "lt") killed ])));
      test "add sums the runs of two survivors of a mutant" (fun () ->
          let m = id "lib/a.ml" 1 0 "lt" in
          equal verdict
            (Verdicts.Survived
               { first = [ "a" ]; others = [ [ "b" ] ]; runs = 5 })
            (require_match
               (function [ r ] -> Some r.Verdicts.verdict | _ -> None)
               (Verdicts.records
                  (collection
                     [
                       record m (Verdicts.survived ~runs:2 [ [ "a" ] ]);
                       record m (Verdicts.survived ~runs:3 [ [ "b" ] ]);
                     ]))));
      test "merge sums the runs of two survivors of a mutant" (fun () ->
          let m = id "lib/a.ml" 1 0 "lt" in
          let one runs ts =
            collection [ record m (Verdicts.survived ~runs ts) ]
          in
          equal verdict
            (Verdicts.Survived
               { first = [ "a" ]; others = [ [ "b" ] ]; runs = 5 })
            (require_match
               (function [ r ] -> Some r.Verdicts.verdict | _ -> None)
               (Verdicts.records
                  (Verdicts.merge (one 2 [ [ "a" ] ]) (one 3 [ [ "b" ] ])))));
      test "merge sums the runs of two previous survivors of a mutant"
        (fun () ->
          let m = id "lib/a.ml" 1 0 "lt" in
          let one runs =
            collection
              [
                record
                  ~previous:(Verdicts.survived ~runs [ [ "a" ] ])
                  m Verdicts.Unreached;
              ]
          in
          equal records
            (collection
               [
                 record
                   ~previous:(Verdicts.survived ~runs:5 [ [ "a" ] ])
                   m Verdicts.Unreached;
               ])
            (Verdicts.merge (one 2) (one 3)));
      test "add makes a runs below 1 one run, and merge then commutes"
        (fun () ->
          let m = id "lib/a.ml" 1 0 "lt" in
          let one ts runs =
            collection
              [ record m (Verdicts.Survived { first = ts; others = []; runs }) ]
          in
          let a = one [ "a" ] 3 and b = one [ "b" ] (-5) in
          equal records
            (collection [ record m (Verdicts.survived [ [ "b" ] ]) ])
            b;
          equal records (Verdicts.merge a b) (Verdicts.merge b a);
          equal records
            (collection
               [ record m (Verdicts.survived ~runs:4 [ [ "a" ]; [ "b" ] ]) ])
            (Verdicts.merge a b));
      test "the sum of the runs stops at max_int" (fun () ->
          let m = id "lib/a.ml" 1 0 "lt" in
          let runs_of t =
            require_match
              (function
                | [ { Verdicts.verdict = Verdicts.Survived { runs; _ }; _ } ] ->
                    Some runs
                | _ -> None)
              (Verdicts.records t)
          in
          let big = record m (Verdicts.survived ~runs:max_int [ [ "a" ] ]) in
          let one = record m (Verdicts.survived [ [ "b" ] ]) in
          equal int max_int (runs_of (collection [ big; one ]));
          equal int max_int (runs_of (collection [ one; big ]));
          equal int max_int
            (runs_of (Verdicts.merge (collection [ big ]) (collection [ one ]))));
      cases
        "changed is the change of class between a previous verdict and a \
         verdict"
        ~name:(fun (name, _, _, _) -> name)
        changed_cases changed;
      cases
        "with_previous takes the verdict of the same mutant when the digest is \
         the same and not None"
        ~name:(fun (name, _, _, _) -> name)
        with_previous_cases with_previous;
      prop "with_previous sets the previous verdict by the rule of its digest"
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
      prop
        "merge of a collection with itself doubles the runs of each survivor, \
         and changes nothing else"
        small_collection doubles;
      prop "empty is the unit of merge" small_collection empty_is_unit;
      prop "merge combines two records of a mutant as add does"
        (Gen.pair small_collection small_collection)
        merge_is_add;
      prop "an Unreached verdict leaves the verdict it is merged with unchanged"
        small_collection unreached_is_neutral;
      cases "add checks no identifier, and load refuses the file save writes"
        ~name:fst unchecked_ids unchecked;
    ]

(* Verdict files *)

let digest = String.make 32 'a'

let sample =
  collection
    [
      record ~before:"a - b" ~after:"a + b" (id "lib/a.ml" 1 2 "add")
        Verdicts.Unreached;
      record ~before:"p && q" ~after:"not (p && q)" (id "lib/b.ml" 3 4 "not")
        (killed_by [ "g"; "t" ]);
      record ~before:"p" ~after:"not p" (id "lib/b.ml" 4 0 "not") killed;
      record ~before:"a || b" ~after:"a && b" (id "lib/b.ml" 5 0 "or")
        (Verdicts.survived ~runs:3 [ [ "y"; "z" ]; [ "x" ] ]);
      record ~before:"a + b" ~after:"a - b" ~source_digest:digest
        (id "lib/c.ml" 7 1 "sub") Verdicts.Not_evaluated;
      record ~before:"a - b" ~after:"a + b" (id "lib/c.ml" 9 0 "add")
        Verdicts.Outside_tests;
      record ~before:"x + 0" ~after:"x - 0" (id "lib/d.ml" 2 3 "sub")
        (Verdicts.Filtered "zero operand");
      record ~before:"a - b" ~after:"a + b" (id "lib/e.ml" 1 0 "add")
        (Verdicts.Killed_elsewhere { exe = "default/test/a.exe" });
      record ~before:"a + b" ~after:"a - b" (id "lib/f.ml" 1 0 "sub")
        (Verdicts.Flaky { test = [ "g"; "t" ]; failure = "child run 5" });
    ]

let round_trip (identity, suite, t) =
  let path = Filename.concat (temp_dir ()) "saved.mutants" in
  Verdicts.save ?identity ?suite path t;
  equal
    (result (triple (list string) (option string) (option string)) string)
    (Ok (rows t, Option.map identity_row identity, suite))
    (load_rows (Verdicts.load path))

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

let replaced () =
  let path = Filename.concat (temp_dir ()) "saved.mutants" in
  Verdicts.save ~identity:{ exe = "test/a.exe"; digest } ~suite:"s" path sample;
  Verdicts.save path Verdicts.empty;
  equal
    (result (triple (list string) (option string) (option string)) string)
    (Ok ([], None, None))
    (load_rows (Verdicts.load path))

let empty_killing_exe () =
  let t =
    Verdicts.add Verdicts.empty
      (record (id "lib/a.ml" 1 0 "add")
         (Verdicts.Killed_elsewhere { exe = "" }))
  in
  equal (list string)
    [ {|"lib/a.ml":1:0:add "b" -> "a": killed elsewhere by ""|} ]
    (rows t);
  let path = Filename.concat (temp_dir ()) "empty-exe.mutants" in
  Verdicts.save path t;
  equal string path (require_match corrupt_path (Verdicts.load path))

let empty_previous_killing_exe () =
  let t =
    Verdicts.add Verdicts.empty
      (record
         ~previous:(Verdicts.Killed_elsewhere { exe = "" })
         (id "lib/a.ml" 1 0 "add") killed)
  in
  equal (list string)
    [ {|"lib/a.ml":1:0:add "b" -> "a": killed was killed elsewhere by ""|} ]
    (rows t);
  let path = Filename.concat (temp_dir ()) "empty-exe.mutants" in
  Verdicts.save path t;
  equal string path (require_match corrupt_path (Verdicts.load path))

let previous_text () =
  let t =
    collection
      [
        record (id "lib/a.ml" 1 2 "add") Verdicts.Unreached;
        record
          ~previous:(Verdicts.survived [ [ "t" ] ])
          (id "lib/a.ml" 1 3 "add") killed;
        record ~previous:(killed_by [ "t" ]) (id "lib/a.ml" 1 4 "add")
          (Verdicts.survived [ [ "g"; "t" ] ]);
        record (id "lib/a.ml" 1 5 "add")
          (Verdicts.survived ~runs:3 [ [ "g"; "t" ] ]);
        record
          ~previous:(Verdicts.Flaky { test = [ "t" ]; failure = "f" })
          (id "lib/a.ml" 1 6 "add")
          (Verdicts.Flaky { test = [ "g"; "t" ]; failure = "child run 5" });
      ]
  in
  equal string
    (String.concat ""
       [
         "windtrap-mutants-v10\n0\n5\n";
         "8 lib/a.ml 1 2 3 add 1 b 1 a 0  unreached none\n";
         "8 lib/a.ml 1 3 3 add 1 b 1 a 0  killed 0 was survived 1 1 1 1 t\n";
         "8 lib/a.ml 1 4 3 add 1 b 1 a 0  survived 1 1 2 1 g 1 t was killed 1 \
          1 1 t\n";
         "8 lib/a.ml 1 5 3 add 1 b 1 a 0  survived 3 1 2 1 g 1 t none\n";
         "8 lib/a.ml 1 6 3 add 1 b 1 a 0  flaky 2 1 g 1 t 11 child run 5 was \
          flaky 1 1 t 1 f\n";
       ])
    (saved t)

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
  raises_match (Exn.invalid_arg ~substring:"Windtrap_runtime.Verdicts")
    (fun () ->
      Verdicts.save ~identity
        (Filename.concat dir "unwritten.mutants")
        Verdicts.empty);
  equal (list string) [] (Array.to_list (Sys.readdir dir))

let headers =
  [
    ("the empty file", "");
    ("a coverage file", "windtrap-coverage-v3\n1\n");
    ("an earlier version", "windtrap-mutants-v3\n0\n");
    ("two versions before", "windtrap-mutants-v5\n0\n");
    ("the previous version", "windtrap-mutants-v9\n0\n");
    ("a later version", "windtrap-mutants-v11\n0\n");
    ("the magic in uppercase", "WINDTRAP-MUTANTS-V1\n0\n");
    ("the magic and a digit", "windtrap-mutants-v100\n0\n");
    ("plain text", "hello\nworld\n");
  ]

let unknown_format (_, text) =
  let path, loaded = load_text text in
  equal string path
    (require_match
       (function
         | Error (Verdicts.Unknown_format { path; _ }) -> Some path | _ -> None)
       loaded)

let record_prefix = "windtrap-mutants-v10\n0\n1\n8 lib/a.ml "

let corrupt_files =
  [
    ("the magic line alone", "windtrap-mutants-v10");
    ("a negative suite count", "windtrap-mutants-v10\n-1\n0\n");
    ("a suite count of 2", "windtrap-mutants-v10\n2 1 s 1 t\n0\n");
    ("a suite past the input", "windtrap-mutants-v10\n1 80 s\n0\n");
    ("no record count", "windtrap-mutants-v10\n0\n");
    ("a negative record count", "windtrap-mutants-v10\n0\n-1\n");
    ("a record count past the input", "windtrap-mutants-v10\n0\n99999999\n");
    ( "fewer records than the count",
      "windtrap-mutants-v10\n\
       0\n\
       2\n\
       8 lib/a.ml 1 2 3 add 1 b 1 a 0 unreached none\n" );
    ( "an empty file name",
      "windtrap-mutants-v10\n0\n1\n0  1 2 3 add 0 0 1 b 1 a 0 unreached\n" );
    ( "a file name past the input",
      "windtrap-mutants-v10\n0\n1\n80 lib/a.ml 1 2 3 add 1 b 1 a 0 unreached\n"
    );
    ("line 0", record_prefix ^ "0 2 3 add 1 b 1 a 0 unreached\n");
    ("a negative line", record_prefix ^ "-3 2 3 add 1 b 1 a 0 unreached\n");
    ("a negative column", record_prefix ^ "1 -2 3 add 1 b 1 a 0 unreached\n");
    ( "a rewrite past the input",
      record_prefix ^ "1 2 30 add 1 b 1 a 0 unreached\n" );
    ("an unknown rewrite", record_prefix ^ "1 2 4 plus 1 b 1 a 0 unreached\n");
    ( "swap, which no instrumenter emits",
      record_prefix ^ "1 2 4 swap 1 b 1 a 0 unreached\n" );
    ( "a before past the input",
      record_prefix ^ "1 2 3 add 80 b 1 a 0 unreached\n" );
    ("no rendering", record_prefix ^ "1 2 3 add unreached\n");
    ("an after past the input", record_prefix ^ "1 2 3 add 1 b 80 a unreached\n");
    ("an unknown verdict", record_prefix ^ "1 2 3 add 1 b 1 a 0 errored\n");
    ("a filter with no reason", record_prefix ^ "1 2 3 add 1 b 1 a 0 filtered\n");
    ( "a filter reason past the input",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 filtered 80 r\n" );
    ("no verdict", record_prefix ^ "1 2 3 add 1 b 1 a 0 \n");
    ( "a killing executable that is empty",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 killed_elsewhere 0 \n" );
    ( "no killing executable",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 killed_elsewhere\n" );
    ("no source digest", record_prefix ^ "1 2 3 add 1 b 1 a\n");
    ( "a short source digest",
      record_prefix ^ "1 2 3 add 1 b 1 a 3 abc unreached\n" );
    ( "an uppercase source digest",
      record_prefix ^ "1 2 3 add 1 b 1 a 32 " ^ String.make 32 'A'
      ^ " unreached\n" );
    ( "a killed mutant with two killing tests",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 killed 2 1 1 g 1 1 h\n" );
    ( "a killing test past the input",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 killed 1 1 80 g\n" );
    ( "a flaky kill with no failure",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 flaky 1 1 t\n" );
    ( "a flaky failure past the input",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 flaky 1 1 t 80 f\n" );
    ( "a flaky test name past the input",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 flaky 1 80 t\n" );
    ( "a survivor with no run",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 survived 0 1 1 1 t none\n" );
    ( "a survivor with no reaching test",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 survived 1 0\n" );
    ( "a reaching test count past the input",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 survived 1 99999999\n" );
    ( "a negative test path length",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 survived 1 1 -1\n" );
    ( "a test path shorter than its length",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 survived 1 2 1 1 g\n" );
    ( "a test name past the input",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 survived 1 1 1 80 g\n" );
    ( "two records of one identifier",
      "windtrap-mutants-v10\n\
       0\n\
       2\n\
       8 lib/a.ml 1 2 3 add 1 b 1 a 0 unreached none\n\
       8 lib/a.ml 1 2 3 add 1 b 1 a 0 killed 0 none\n" );
    ( "a malformed record after a valid one",
      "windtrap-mutants-v10\n\
       0\n\
       2\n\
       8 lib/a.ml 1 2 3 add 1 b 1 a 0 killed 0 none\n\
       8 lib/a.ml 0 2 3 add 1 b 1 a 0 unreached\n" );
    ("no previous verdict", record_prefix ^ "1 2 3 add 1 b 1 a 0 unreached\n");
    ( "an unknown previous verdict",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 unreached maybe\n" );
    ( "a previous survivor with no reaching test",
      record_prefix ^ "1 2 3 add 1 b 1 a 0 unreached was survived 1 0\n" );
    ("a short identity digest", "windtrap-mutants-v10\nexe abcd 1 a\n0\n");
    ("an empty identity exe", "windtrap-mutants-v10\nexe " ^ digest ^ " 0 \n0\n");
    ("bytes after the last record", "windtrap-mutants-v10\n0\n0\nextra\n");
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
    the magic line alone: expected suite count at offset 20
    a negative suite count: negative suite count
    a suite count of 2: suite count 2 is not 0 or 1
    a suite past the input: truncated suite
    no record count: expected record count at offset 23
    a negative record count: negative record count
    a record count past the input: record count exceeds data
    fewer records than the count: expected file name length at offset 71
    an empty file name: empty file name
    a file name past the input: truncated file name
    line 0: line 0 is not 1-based
    a negative line: negative line
    a negative column: negative column
    a rewrite past the input: truncated rewrite
    an unknown rewrite: unknown rewrite "plus"
    swap, which no instrumenter emits: unknown rewrite "swap"
    a before past the input: truncated before
    no rendering: expected before length at offset 46
    an after past the input: truncated after
    an unknown verdict: unknown verdict "errored"
    a filter with no reason: expected filter reason length at offset 65
    a filter reason past the input: truncated filter reason
    no verdict: expected verdict at offset 57
    a killing executable that is empty: empty killing executable
    no killing executable: expected killing executable length at offset 73
    no source digest: expected source digest length at offset 54
    a short source digest: "abc" is not a source digest
    an uppercase source digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" is not a source digest
    a killed mutant with two killing tests: a mutant has 2 killing tests
    a killing test past the input: truncated test name
    a flaky kill with no failure: expected flaky failure length at offset 68
    a flaky failure past the input: truncated flaky failure
    a flaky test name past the input: truncated test name
    a survivor with no run: a survivor has 0 runs
    a survivor with no reaching test: a survivor names no test (survived is not unreached)
    a reaching test count past the input: reaching test count exceeds data
    a negative test path length: negative test path length
    a test path shorter than its length: expected test path length at offset 75
    a test name past the input: truncated test name
    two records of one identifier: duplicate record for lib/a.ml:1:2:add
    a malformed record after a valid one: line 0 is not 1-based
    no previous verdict: expected previous verdict at offset 66
    an unknown previous verdict: unknown previous verdict "maybe"
    a previous survivor with no reaching test: a survivor names no test (survived is not unreached)
    a short identity digest: identity digest is not 32 hex characters at offset 25
    an empty identity exe: empty executable identity
    bytes after the last record: trailing data at offset 25
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
    f.mutants: not a windtrap verdict file (expected header "windtrap-mutants-v10", found "junk"); files written by other windtrap versions are not readable - delete the stale verdict files, then re-run the mutation tests
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

(* The MD5 of the executable identity [default/test/t.exe], then of the suite. *)
let suite_files =
  let exe = "windtrap-ecc2455c5e4d1d42c39f8d1631b3c7d5" in
  [
    ("calc", exe ^ "-74e338c3d6c13c11b54998028bd1adfb.mutants");
    ("", exe ^ "-d41d8cd98f00b204e9800998ecf8427e.mutants");
    ("lib/a.ml", exe ^ "-91b742a1b4614abe2a25a8c7f553e74f.mutants");
  ]

let files =
  group "Verdict files"
    [
      test
        "format is the magic line, the mutants directory and extension, and \
         the verdict kind" (fun () ->
          equal (list string)
            [ "windtrap-mutants-v10"; "mutants"; "mutants"; "verdict" ]
            Verdicts.[ format.magic; format.dir; format.ext; format.kind ]);
      test
        "save writes the magic line, the count, then the records by identifier"
        (fun () ->
          expect_exact (saved sample)
          @@ __POS_OF__
               {|windtrap-mutants-v10
0
9
8 lib/a.ml 1 2 3 add 5 a - b 5 a + b 0  unreached none
8 lib/b.ml 3 4 3 not 6 p && q 12 not (p && q) 0  killed 1 2 1 g 1 t none
8 lib/b.ml 4 0 3 not 1 p 5 not p 0  killed 0 none
8 lib/b.ml 5 0 2 or 6 a || b 6 a && b 0  survived 3 2 1 1 x 2 1 y 1 z none
8 lib/c.ml 7 1 3 sub 5 a + b 5 a - b 32 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa not_evaluated none
8 lib/c.ml 9 0 3 add 5 a - b 5 a + b 0  outside_tests none
8 lib/d.ml 2 3 3 sub 5 x + 0 5 x - 0 0  filtered 12 zero operand none
8 lib/e.ml 1 0 3 add 5 a - b 5 a + b 0  killed_elsewhere 18 default/test/a.exe none
8 lib/f.ml 1 0 3 sub 5 a + b 5 a - b 0  flaky 2 1 g 1 t 11 child run 5 none
|});
      test "save writes an identity after the magic line" (fun () ->
          expect_exact
            (saved ~identity:{ exe = "test/a.exe"; digest } Verdicts.empty)
          @@ __POS_OF__
               {|windtrap-mutants-v10
exe aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10 test/a.exe
0
0
|});
      test "save writes the suite after the identity" (fun () ->
          expect_exact
            (saved
               ~identity:{ exe = "test/a.exe"; digest }
               ~suite:"calc" Verdicts.empty)
          @@ __POS_OF__
               {|windtrap-mutants-v10
exe aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10 test/a.exe
1 4 calc
0
|});
      prop "load reads back what save wrote, identity and suite included"
        any_file round_trip;
      prop
        "save writes one file for a collection, whatever the order of its adds"
        (Gen.list ~size:(Gen.int_range 0 6) small_record)
        order_free;
      test "save replaces the file, identity and suite included" replaced;
      test
        "add accepts a Killed_elsewhere with no executable, save writes it and \
         load refuses it as Corrupt, naming the path"
        empty_killing_exe;
      test
        "add accepts a previous Killed_elsewhere with no executable, save \
         writes it and load refuses it as Corrupt, naming the path"
        empty_previous_killing_exe;
      test "save writes the previous verdict after the verdict" previous_text;
      cases
        "save raises Invalid_argument on a malformed identity and writes \
         nothing"
        ~name:fst bad_identities refused_identity;
      cases "load refuses another first line as Unknown_format, naming the path"
        ~name:fst headers unknown_format;
      cases "load refuses malformed data as Corrupt, naming the path" ~name:fst
        corrupt_files corrupt;
      test "a Corrupt reason names the field and its fault" corrupt_reasons;
      test "load of a missing file is Unreadable, naming the path" (fun () ->
          let path = Filename.concat (temp_dir ()) "missing.mutants" in
          equal string ("unreadable " ^ path)
            (Result.fold
               ~ok:(fun _ -> "loaded")
               ~error:error_row (Verdicts.load path)));
      test "pp_error names the file, the fault and what to do" error_messages;
      cases
        "output_file puts the MD5 of the suite before the extension of \
         Instr.output_file"
        ~name:(fun (suite, _) -> strf "%S" suite)
        suite_files
        (fun (suite, file) ->
          equal string
            ("/w/p/_build/_mutants/" ^ file)
            (Verdicts.output_file ~exe:"/w/p/_build/default/test/t.exe" ~suite));
      test
        "the files of two suites of one executable are two files of one \
         directory, and neither is the file of Instr.output_file" (fun () ->
          let exe = "/w/p/_build/default/test/t.exe" in
          let a = Verdicts.output_file ~exe ~suite:"lib/a.ml"
          and b = Verdicts.output_file ~exe ~suite:"lib/b.ml" in
          not_equal string a b;
          equal string (Filename.dirname a) (Filename.dirname b);
          let plain = Instr.output_file Verdicts.format ~exe in
          not_equal string plain a;
          not_equal string plain b);
      test "one suite of an executable spelled in two ways has one file"
        (fun () ->
          let paths =
            List.map
              (fun exe -> Verdicts.output_file ~exe ~suite:"calc")
              [
                "/w/p/_build/default/test/t.exe";
                "/w/p/_build/.sandbox/0f/default/test/t.exe";
                "/w/p/_build/default/test/../test/t.exe";
              ]
          in
          equal (list string) (List.map (fun _ -> List.hd paths) paths) paths);
      test "the name of a verdict file holds no byte of its suite" (fun () ->
          let name =
            Filename.basename
              (Verdicts.output_file ~exe:"/w/p/_build/default/test/t.exe"
                 ~suite:"a/b c\n\000")
          in
          equal int 82 (String.length name);
          is_true (String.starts_with ~prefix:"windtrap-" name);
          is_true (String.ends_with ~suffix:".mutants" name);
          let hash = String.sub name 9 65 in
          is_true
            (String.for_all
               (function '0' .. '9' | 'a' .. 'f' | '-' -> true | _ -> false)
               hash));
      test "writer_identity is the executable's identity and digest" writer;
      test "writer_identity is None for a file that cannot be read" (fun () ->
          is_none ~pp:pp_identity
            (Verdicts.writer_identity
               ~exe:(Filename.concat (temp_dir ()) "no-such.exe")));
    ]

let () = exit (run "verdicts" [ verdicts; collections; files ])
