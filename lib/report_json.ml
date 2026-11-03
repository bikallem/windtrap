(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

open Json

(* Tests *)

let vacuous failures =
  failures <> [] && List.for_all Failure.is_vacuous failures

let failures (r : Run.result) =
  match r.outcome with Fail failures -> failures | Pass | Skip _ -> []

let verdict (r : Run.result) =
  match r.outcome with
  | Pass -> "pass"
  | Skip _ -> "skip"
  | Fail _ when not r.counted -> "xfail"
  | Fail failures when vacuous failures -> "vacuous"
  | Fail _ -> "fail"

let reason (r : Run.result) =
  match r.outcome with
  | Skip (Some reason) -> [ ("reason", String reason) ]
  | Fail failures when r.counted && vacuous failures ->
      let text (f : Failure.t) =
        match f.kind with Vacuous t -> t.kept | _ -> ""
      in
      [ ("reason", String (String.concat "; " (List.map text failures))) ]
  | Pass | Skip None | Fail _ -> []

let failure (f : Failure.t) =
  Object
    (("headline", String (Report_sections.headline f))
    ::
    (match f.loc with
    | Some loc -> [ ("file", String loc.file); ("line", Int loc.line) ]
    | None -> []))

let property (r : Run.result) (s : Property.stats) =
  let label (label, cases) =
    Object [ ("label", String label); ("cases", Int cases) ]
  in
  let cover (c : Property.cover_status) =
    let share =
      match c.share with
      | None -> []
      | Some s ->
          [
            ( "share",
              Object
                [
                  ("demand", Float s.demand);
                  ("hits", Int s.hits);
                  ("cases", Int s.cases);
                  ("low", Float s.low);
                  ("high", Float s.high);
                ] );
          ]
    in
    Object
      ([
         ("label", String c.label);
         ("cases", Int c.hits);
         ("met", Bool c.satisfied);
       ]
      @ share)
  in
  [
    ("cases", Int (s.cases - s.examples));
    ("examples", Int s.examples);
    ("count", Int s.count);
    ("discards", Int s.discards);
  ]
  @ (if s.replayed > 0 then [ ("replayed", Int s.replayed) ] else [])
  @ (match s.whole with
    | Some n -> [ ((if r.table then "rows" else "values"), Int n) ]
    | None -> [])
  @ (match r.skipped_rows with
    | Some { count; _ } -> [ ("skipped", Int count) ]
    | None -> if r.table then [ ("skipped", Int 0) ] else [])
  @ [
      ("labels", List (List.map label s.collected));
      ("cover", List (List.map cover s.coverage));
    ]

let tolerance (s : Check.tolerance) =
  Object
    ((match s.site with
       | Some loc -> [ ("file", String loc.file); ("line", Int loc.line) ]
       | None -> [])
    @ [
        ("comparisons", Int s.comparisons);
        ("error", Float s.error);
        ("tolerance", Float s.tolerance);
      ])

let scope (r : Run.result) =
  Object
    ((match r.prop_stats with Some s -> property r s | None -> [])
    @ [ ("tolerances", List (List.map tolerance r.tolerances)) ])

let test (r : Run.result) =
  Object
    ([ ("path", List (List.map (fun s -> String s) r.path)) ]
    @ [ ("verdict", String (verdict r)) ]
    @ reason r
    @ [
        ("attempts", Int r.attempts);
        ("duration", Float r.duration);
        ("failures", List (List.map failure (failures r)));
        ("scope", scope r);
      ])

(* Counts *)

let counts ~selected ~duration ~release_failures results =
  let count p = List.length (List.filter p results) in
  let is v (r : Run.result) = String.equal (verdict r) v in
  Object
    [
      ("tests", Int selected);
      ("passed", Int (count (is "pass")));
      ("failed", Int (count (is "fail") + List.length release_failures));
      ("vacuous", Int (count (is "vacuous")));
      ("skipped", Int (count (is "skip")));
      ("expected_failures", Int (count (is "xfail")));
      ( "flaky",
        Int (count (fun (r : Run.result) -> is "pass" r && r.attempts > 1)) );
      ("not_run", Int (max 0 (selected - List.length results)));
      ("release_failures", Int (List.length release_failures));
      ("duration", Float duration);
    ]

(* The document *)

(* One test per line, so a line-oriented tool reads a test at a time. *)
let render ~suite ~seed ~selected ~duration ~results ~release_failures () =
  let b = Buffer.create 4096 in
  Buffer.add_string b "{\"version\": 1, \"suite\": ";
  add_string b suite;
  Buffer.add_string b ", \"seed\": ";
  add_string b (Seed.to_string seed);
  Buffer.add_string b ", \"tests\": [";
  List.iteri
    (fun i r ->
      Buffer.add_string b (if i = 0 then "\n  " else ",\n  ");
      add b (test r))
    results;
  Buffer.add_string b "\n], \"counts\": ";
  add b (counts ~selected ~duration ~release_failures results);
  Buffer.add_string b "}\n";
  Buffer.contents b

(* Writing *)

let names_file target = Filename.check_suffix target ".json"

let path ~suite target =
  if names_file target then target
  else Filename.concat target (Os.sanitize_component suite ^ ".json")

let write ~suite ~seed ~selected ~duration ~results ~release_failures target =
  let file = path ~suite target in
  let document =
    render ~suite ~seed ~selected ~duration ~results ~release_failures ()
  in
  try
    if not (names_file target) then Os.mkdir_p (Filename.dirname file);
    Os.atomic_write ~path:file document
  with (Sys_error _ | Unix.Unix_error _) as e ->
    Os.warn
      (strf "could not write JSON report to %s: %s" (Os.display_path file)
         (Os.failure_reason ~path:file e))
