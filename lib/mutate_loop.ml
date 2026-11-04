(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Not mutated. The scheduler, the run state, the report and this loop judge
   mutants, and a mutant armed among them does not fail the tests that reach
   it: it hangs them or corrupts the verdict. Coverage still measures these
   files. *)
[@@@mutate exclude_file]

module Mutate = Windtrap_runtime.Mutate
module Verdicts = Windtrap_runtime.Verdicts

let strf = Printf.sprintf

let ordinary ~suite (config : Run.config) tests =
  Report.run ~suite { config with mutation = Run.No_mutation } tests

(* Population *)

let in_scope ~(scope : Run.scope) (id : Mutate.id) =
  (scope.prefixes = []
  || List.exists
       (fun prefix -> String.starts_with ~prefix id.file)
       scope.prefixes)
  &&
  match scope.lines with
  | None -> true
  | Some lines -> Lines.mem lines ~file:id.file ~line:id.line

(* The scope as the reader gave it: the prefixes, then the lines. *)
let spelled ~prefixes ~lines (scope : Run.scope) =
  String.concat " "
    ((match scope.prefixes with [] -> [] | ps -> [ prefixes ps ])
    @
    match scope.lines with
    | None -> []
    | Some l -> [ lines (Lines.to_string l) ])

type no_mutant =
  | Uninstrumented
  | Out_of_scope
  | No_site_on_lines (* the lines name no line, or none with a site *)
  | All_dismissed

(* Lines that name no line, or only lines of instrumented files with no site
   on them, describe the change, not a mistake: a change to comments or
   documentation leaves nothing to mutate. Lines that name no instrumented
   file stay [Out_of_scope], as a typo would. *)
let population ~scope =
  let catalogue = Mutate.catalogue () in
  let scoped =
    List.filter (fun (m : Mutate.mutant) -> in_scope ~scope m.id) catalogue
  in
  let undismissed =
    List.filter (fun (m : Mutate.mutant) -> Option.is_none m.dismissed) scoped
  in
  let names_a_file lines =
    Lines.is_empty lines
    ||
    let files = Lines.files lines in
    List.exists
      (fun (m : Mutate.mutant) ->
        List.mem m.id.file files
        && in_scope ~scope:{ scope with lines = None } m.id)
      catalogue
  in
  match (catalogue, scoped, undismissed) with
  | [], _, _ when { scope with skip_killed = false } = Run.every_mutant ->
      Error Uninstrumented
  | _ :: _, [], _
    when Option.fold ~none:false ~some:names_a_file scope.Run.lines ->
      Error No_site_on_lines
  | _, [], _ -> Error Out_of_scope
  | _, _, [] -> Error All_dismissed
  | _, _, population -> Ok population

let no_site_on_lines =
  "the selected lines hold no mutation site, so nothing on them is \
   mutation-tested"

(* A prefix that leaves nothing is one sentence whatever the catalogue holds:
   the prefix is what the reader typed, and a build that is instrumented and
   fine must not be blamed for it. *)
let refusal ~scope = function
  | Uninstrumented ->
      "this executable links no instrumented module, so there is nothing to \
       mutate: instrument the library under test with ppx_windtrap.mutate and \
       re-run"
  | Out_of_scope ->
      strf
        "%s leaves no mutant in this executable's catalogue: no instrumented \
         file matches the %s (is the library under test instrumented with \
         ppx_windtrap.mutate?), or the matched %s no mutation sites"
        (spelled scope
           ~prefixes:(fun ps -> "--mutate=" ^ String.concat "," ps)
           ~lines:(fun l -> "--lines=" ^ l))
        (if scope.lines = None then "prefix" else "scope")
        (if scope.lines = None then "files have" else "lines hold")
  | No_site_on_lines -> no_site_on_lines
  | All_dismissed ->
      "every mutant this run could test is dismissed by [@mutate off]; there \
       is nothing to test"

let unmutated ~scope reason =
  let why =
    match reason with
    | Uninstrumented -> "this executable links no instrumented module"
    | Out_of_scope ->
        strf "no mutant of this executable's catalogue is %s"
          (spelled scope
             ~prefixes:(fun ps -> "under " ^ String.concat "," ps)
             ~lines:(fun l -> "on " ^ l))
    | No_site_on_lines -> no_site_on_lines
    | All_dismissed ->
        "every mutant of this executable is dismissed by [@mutate off]"
  in
  strf "WINDTRAP_MUTATE is set, but %s, so the suite runs without mutation" why

(* The reach map *)

type site = {
  mutable tests : string list list; (* the reaching tests, newest first *)
  mutable hits : int; (* the evaluations, saturating at [max_int] *)
}

type reach = {
  sites : (Mutate.id, site) Hashtbl.t;
  outside : (Mutate.id, unit) Hashtbl.t; (* evaluated outside every test *)
}

let xfail_paths tests =
  let paths = Hashtbl.create 16 in
  List.iter
    (fun (case : Test_tree.case) ->
      if Option.is_some case.xfail then Hashtbl.replace paths case.path ())
    (Test_tree.flatten tests);
  Hashtbl.mem paths

let saturating_add a b = if a > max_int - b then max_int else a + b

(* What the workers of the dry run report. A test marked xfail reaches no
   mutant, so what it evaluated is dropped. *)
let observe reach ~xfail test sites =
  match test with
  | None -> List.iter (fun (id, _) -> Hashtbl.replace reach.outside id ()) sites
  | Some path when xfail path -> ()
  | Some path ->
      List.iter
        (fun (id, hits) ->
          match Hashtbl.find_opt reach.sites id with
          | None -> Hashtbl.add reach.sites id { tests = [ path ]; hits }
          | Some site ->
              site.tests <- path :: site.tests;
              site.hits <- saturating_add site.hits hits)
        sites

(* The verdict file *)

let narrows_suite (config : Run.config) ~focus =
  config.filter <> [] || config.exclude <> [] || config.tags <> []
  || config.exclude_tags <> [] || config.failed_only || focus
  || config.shard <> None

(* What the file of [suite] holds, whatever build wrote it. *)
let earlier ~suite =
  let exe = Windtrap_runtime.Instr.executable in
  match Verdicts.load (Verdicts.output_file ~exe ~suite) with
  | Ok ({ suite = Some s; _ } as file) when String.equal s suite -> Some file
  | Ok _ | Error _ -> None

let by_this_build = function
  | Some ({ Verdicts.identity = Some writer; _ } as file)
    when Verdicts.writer_identity ~exe:Windtrap_runtime.Instr.executable
         = Some writer ->
      Some file
  | Some _ | None -> None

let this_build ~suite = by_this_build (earlier ~suite)

(* Under a scope, the records of the other files stay when this build wrote
   them and tested its suite. The result is the records of [records] whose
   verdict changed, and the note on a file that cannot be written. *)
let save ~suite ~scope ?refused records =
  let exe = Windtrap_runtime.Instr.executable in
  let earlier = earlier ~suite in
  let kept =
    match (by_this_build earlier, refused) with
    | Some { verdicts; refused = None; _ }, None ->
        List.filter
          (fun (r : Verdicts.record) -> not (in_scope ~scope r.id))
          (Verdicts.records verdicts)
    | _ -> []
  in
  let tested =
    Verdicts.with_previous
      ~prior:
        (Option.fold ~none:Verdicts.empty
           ~some:(fun (f : Verdicts.file) -> f.verdicts)
           earlier)
      (List.fold_left Verdicts.add Verdicts.empty records)
  in
  match
    Verdicts.save
      ?identity:(Verdicts.writer_identity ~exe)
      ~suite ?refused
      (Verdicts.output_file ~exe ~suite)
      (List.fold_left Verdicts.add tested kept)
  with
  | () ->
      ( List.filter
          (fun r -> Option.is_some (Verdicts.changed r))
          (Verdicts.records tested),
        None )
  | exception Sys_error message ->
      ([], Some (strf "could not write the verdict file: %s" message))

let recorded verdict = List.map (fun m -> Verdicts.record_of_mutant m verdict)

(* What a suite that could not be tested holds as unknown: what its run
   would have judged. A dry run that ran whole and green says what it never
   reached. *)
let unknown_records ?reach population reason =
  match reach with
  | None -> recorded (Verdicts.Unknown reason) population
  | Some (reached, unreached, outside) ->
      recorded (Verdicts.Unknown reason) (List.map fst reached)
      @ recorded Verdicts.Unreached unreached
      @ recorded Verdicts.Outside_tests outside

(* A refusal still writes the file, which says why, so the merge names the
   suite and its mutants never read as the other suites' survivors. *)
let refuse ?(say = true) ?reach ~suite ~scope population message =
  if say then Os.say message;
  Option.iter Os.say
    (snd
       (save ~suite ~scope ~refused:message
          (unknown_records ?reach population message)));
  Error (Run.Mutation_refused message)

let narrowing =
  "its selection narrowed the suite, so it saved no verdict: run it whole"

(* A narrowed run cannot unsay what a whole run of the same build found. *)
let save_narrowed ~suite ~scope population =
  let note =
    "verdicts not saved: this run's selection narrows the suite, and a partial \
     run's verdicts would stand in the project merge as the whole."
  in
  match this_build ~suite with
  | Some _ -> Some note
  | None -> (
      match
        snd
          (save ~suite ~scope ~refused:narrowing
             (unknown_records population narrowing))
      with
      | None -> Some note
      | Some failed -> Some (note ^ " " ^ failed))

(* Jobs *)

let deadline_multiplier = 10.

(* The dry run's wall clock bounds what a job pays besides its tests: the
   start of its worker, and its share of a loaded machine. *)
let deadline ~wall ~durations paths =
  let took path = Option.value ~default:0. (Hashtbl.find_opt durations path) in
  let scheduled = List.fold_left (fun acc path -> acc +. took path) 0. paths in
  wall +. Float.max 1. (deadline_multiplier *. scheduled)

let budget_of hits =
  if hits > (max_int - 1000) / 8 then max_int else (hits * 8) + 1000

let counted_failure (r : Run.result) =
  r.counted
  && match r.outcome with Failure.Fail _ -> true | Pass | Skip _ -> false

let is_skip (r : Run.result) =
  match r.outcome with Failure.Skip _ -> true | Pass | Fail _ -> false

let not_a_number =
  "Mutation results over a non-deterministic suite are not a weaker number, \
   they are not a number"

(* The probe agrees iff it executed as many tests as the dry run, skipped as
   many and counted no failure. *)
let probe ~dry_run (ran : Supervisor.ran) =
  let executed = List.length dry_run in
  let skipped = List.length (List.filter is_skip dry_run) in
  let failed = List.filter counted_failure ran.results in
  let ran_skipped = List.length (List.filter is_skip ran.results) in
  match ran.ended with
  | Supervisor.Expired ->
      Error
        ("the determinism probe exceeded its deadline: the dry run completed \
          and its unarmed re-run did not. " ^ not_a_number)
  | Lost how ->
      Error
        (strf "the determinism probe's run %s, where the dry run's did not. %s"
           how not_a_number)
  | Ran
    when List.length ran.results = executed
         && ran_skipped = skipped && failed = [] ->
      Ok ()
  | Ran ->
      Error
        (strf
           "the suite is not deterministic: the dry run executed %d test%s, \
            skipping %d and failing none; the probe executed %d, skipping %d \
            and failing %d%s. %s"
           executed
           (if executed = 1 then "" else "s")
           skipped (List.length ran.results) ran_skipped (List.length failed)
           (match failed with
           | [] -> ""
           | failed ->
               " ("
               ^ String.concat ", "
                   (List.map
                      (fun (r : Run.result) -> Test_tree.path_to_string r.path)
                      failed)
               ^ ")")
           not_a_number)

(* A counted failure of a test not marked xfail. The unexpected pass of a
   test marked xfail fails the run and kills no mutant. *)
let kills (r : Run.result) = Option.is_none r.xfail && counted_failure r

(* Until the first evaluation of its site, the mutant runs the code of the
   program without it, so a failure before then has another cause. A job that
   cannot see forked processes cannot tell, and each failure counts. *)
let killed_by (ran : Supervisor.ran) =
  match if ran.witnessed then ran.evaluated else Some 0 with
  | None -> false
  | Some first ->
      ran.release_failures <> []
      || List.exists kills (List.filteri (fun i _ -> i >= first) ran.results)

(* The failure of a job that did not evaluate the armed site. *)
let uncaused (ran : Supervisor.ran) =
  match List.find_opt kills ran.results with
  | Some r -> Some (Test_tree.path_to_string r.path)
  | None when ran.release_failures <> [] -> Some "a fixture release"
  | None -> None

let seconds s = if s < 10. then strf "%.1fs" s else strf "%.0fs" s

(* A run that ended before its tests did judged nothing, and tests that did
   not evaluate the armed site tested nothing: neither is a survivor. *)
let verdict ~deadline paths (ran : Supervisor.ran) =
  match ran.ended with
  | Supervisor.Expired ->
      Verdicts.Unknown ("its run passed its deadline of " ^ seconds deadline)
  | Lost how -> Verdicts.Unknown ("its run " ^ how)
  | Ran -> (
      if killed_by ran then Verdicts.Killed
      else
        match ran.evaluated with
        | None -> Verdicts.Not_evaluated
        | Some _ -> Verdicts.survived paths)

(* Recorded paths are relative to the project root; under [dune runtest] the
   working directory is inside [_build], where they do not open. *)
let read_source =
  let cache = Hashtbl.create 16 in
  let read path =
    try Some (In_channel.with_open_bin path In_channel.input_all)
    with Sys_error _ -> None
  in
  fun file ->
    match Hashtbl.find_opt cache file with
    | Some source -> source
    | None ->
        let under_root =
          match Os.project_root () with
          | root -> Result.to_option (Os.reconstruct ~root file)
          | exception Sys_error _ -> None
        in
        let source =
          match Option.bind under_root read with
          | None -> read file
          | found -> found
        in
        Hashtbl.add cache file source;
        source

let shown (mutant : Mutate.mutant) : Report_sections.mutant =
  {
    id = Mutate.id_to_string mutant.id;
    file = mutant.id.file;
    line = mutant.id.line;
    col = mutant.id.col;
    end_line = mutant.end_line;
    end_col = mutant.end_col;
    before = mutant.before;
    after = mutant.after;
    source = read_source mutant.id.file;
  }

(* What the jobs found, newest first. Each entry has the index of its mutant
   in the catalogue order, because a later pass gives verdicts to earlier
   mutants. *)
type found = {
  mutable records : Verdicts.record list;
  mutable survivors : (int * Report_sections.survivor) list;
  mutable not_evaluated : (int * Report_sections.not_evaluated) list;
  mutable unknown : (int * Report_sections.unknown) list;
}

(* A survivor's block is committed when its last run is given, so a loop
   that dies has printed what it found. *)
let found_verdict renderer (config : Run.config) ~locations ~failed ~runs found
    (index, mutant) verdict =
  (match verdict with
  | Verdicts.Survived { first; others } ->
      let witness path : Report_sections.witness =
        let test = Test_tree.path_to_string path in
        {
          test;
          loc = Option.join (Hashtbl.find_opt locations test);
          exe = None;
        }
      in
      let survivor : Report_sections.survivor =
        {
          mutant = shown mutant;
          witnesses = List.map witness (first :: others);
        }
      in
      Report.mutation_survivor ~runs renderer survivor;
      found.survivors <- (index, survivor) :: found.survivors
  | Not_evaluated ->
      found.not_evaluated <-
        ( index,
          { mutant = shown mutant; invocation = config.invocation; failed } )
        :: found.not_evaluated
  | Unknown reason ->
      found.unknown <-
        ( index,
          { mutant = shown mutant; reason; invocation = config.invocation } )
        :: found.unknown
  | Killed | Killed_elsewhere _ | Outside_tests | Unreached -> ());
  found.records <- Verdicts.record_of_mutant mutant verdict :: found.records

(* Signals *)

(* The first signal from the dry run's end until the verdict file is
   written: one that a job's handlers did not take, came after the last job.
   The handler only records, since it runs at a safepoint of whatever the
   loop was doing, the report included. SIGPIPE's default action would kill
   the loop inside a write of the report, past every [Fun.protect]; handled,
   the write fails with [Sys_error] and unwinds. *)
let signal = ref None
let record s = if Option.is_none !signal then signal := Some s

let with_interrupts fn =
  signal := None;
  Os.with_signals [ Sys.sigpipe; Sys.sigint; Sys.sigterm; Sys.sighup ] record fn

let flush_descriptors () =
  Format.pp_print_flush Format.std_formatter ();
  Format.pp_print_flush Format.err_formatter ();
  (try flush Stdlib.stdout with Sys_error _ -> ());
  try flush Stdlib.stderr with Sys_error _ -> ()

(* The loop *)

exception Refused of string

type ended =
  | Refused_by of string
  | Interrupted of int * Mutate.mutant option
  | Finished of (Verdicts.record list * string option)

(* A job with a test that spawned a pool in the dry run runs alone: no other
   job runs at the same time as it. *)
let job ~deadline ~pooled ~bail ~armed paths =
  {
    Supervisor.cases = List.map Test_tree.path_to_string paths;
    deadline = deadline paths;
    bail;
    armed;
    alone = List.exists (Hashtbl.mem pooled) paths;
  }

let probe_job ~deadline ~pooled dry_run =
  job ~deadline ~pooled ~bail:false ~armed:None
    (List.map (fun (r : Run.result) -> r.path) dry_run)

(* The budget counts the job's evaluations, not the dry run's. *)
let mutant_job ~deadline ~pooled ((mutant : Mutate.mutant), site) =
  job ~deadline ~pooled ~bail:true
    ~armed:(Some (mutant.id, budget_of site.hits))
    (List.rev site.tests)

(* One pass: [jobs] in fresh workers, up to [-j] at once, given in order. *)
let pass (config : Run.config) ~suite tests jobs ~on_ran =
  Supervisor.fresh config ~suite tests jobs ~on_ran ~on_signal:record

(* The first pass runs the probe and then one job per reached mutant, in
   catalogue order. Each later pass runs again the jobs of the mutants that
   survived the pass before it, up to [config.mutate_retry] passes, and a
   survivor waits for its verdict until its last run. The loop starts no pass
   after a signal. *)
let test_mutants renderer ~suite (config : Run.config) tests ~dry_run ~pooled
    ~wall ~save reached =
  let durations = Hashtbl.create 256 in
  List.iter
    (fun (r : Run.result) -> Hashtbl.replace durations r.path r.duration)
    dry_run;
  let deadline = deadline ~wall ~durations in
  let locations = Hashtbl.create 256 in
  List.iter
    (fun (case : Test_tree.case) ->
      Hashtbl.replace locations (Test_tree.path_to_string case.path) case.loc)
    (Test_tree.flatten tests);
  let found =
    { records = []; survivors = []; not_evaluated = []; unknown = [] }
  in
  let mutants = Array.of_list reached in
  let total = Array.length mutants in
  let judged = Array.make total false in
  let probed = ref false in
  let last = 1 + config.mutate_retry in
  let testing i =
    if i < total then
      Report.mutation_testing renderer ~index:(i + 1) ~total
        ~id:(Mutate.id_to_string (fst mutants.(i) : Mutate.mutant).id)
  in
  (* The mutant [i] waits for another run when it survived and [run] is not
     its last. *)
  let judge ~run i (ran : Supervisor.ran) =
    let mutant, site = mutants.(i) in
    let paths = List.rev site.tests in
    match verdict ~deadline:(deadline paths) paths ran with
    | Verdicts.Survived _ when run < last -> `Again
    | verdict ->
        judged.(i) <- true;
        found_verdict renderer config ~locations ~failed:(uncaused ran)
          ~runs:run found (i, mutant) verdict;
        `Judged
  in
  let rec passes ~run = function
    | [] -> ()
    | _ when Option.is_some !signal -> ()
    | waiting ->
        let waiting = Array.of_list (List.rev waiting) in
        let again = ref [] in
        let on_ran j ran =
          (match judge ~run waiting.(j) ran with
          | `Again -> again := waiting.(j) :: !again
          | `Judged -> ());
          if j + 1 < Array.length waiting then testing waiting.(j + 1)
        in
        testing waiting.(0);
        pass config ~suite tests
          (Array.to_list
             (Array.map
                (fun i -> mutant_job ~deadline ~pooled mutants.(i))
                waiting))
          ~on_ran;
        passes ~run:(run + 1) !again
  in
  let again = ref [] in
  let on_ran index (ran : Supervisor.ran) =
    if index = 0 then begin
      probed := true;
      match probe ~dry_run ran with
      | Ok () -> testing 0
      | Error message -> raise (Refused message)
    end
    else begin
      (match judge ~run:1 (index - 1) ran with
      | `Again -> again := (index - 1) :: !again
      | `Judged -> ());
      testing index
    end
  in
  (* Signals are handled until the verdict file is written, so a loop that
     ended has its file whatever becomes of its report. A survivor that waits
     for a run has no verdict. *)
  let ended =
    with_interrupts @@ fun () ->
    match
      pass config ~suite tests
        (probe_job ~deadline ~pooled dry_run
        :: List.map (mutant_job ~deadline ~pooled) reached)
        ~on_ran
    with
    | exception Refused message -> Refused_by message
    | () -> (
        passes ~run:2 !again;
        let unjudged =
          Seq.find (fun i -> not judged.(i)) (Seq.init total Fun.id)
        in
        match (!signal, unjudged) with
        | Some s, _ when not !probed -> Interrupted (s, None)
        | Some s, Some i -> Interrupted (s, Some (fst mutants.(i)))
        | (Some _ | None), _ -> Finished (save (List.rev found.records)))
  in
  (ended, found)

let report ?(changed = []) ~narrowed ~dry_run ~reached ~unreached ~outside found
    : Report_sections.mutation =
  let lines = List.map (fun (m : Mutate.mutant) -> (m.id.file, m.id.line)) in
  let unstable (r : Verdicts.record) =
    Option.map
      (fun (previous, verdict) : Report_sections.unstable ->
        { id = Mutate.id_to_string r.id; exe = None; previous; verdict })
      (Verdicts.changed r)
  in
  let ordered entries =
    List.map snd (List.sort (fun (i, _) (j, _) -> Int.compare i j) entries)
  in
  {
    survivors = ordered found.survivors;
    not_evaluated = ordered found.not_evaluated;
    unknown = ordered found.unknown;
    unstable = List.filter_map unstable changed;
    refused = [];
    unreached = lines unreached;
    outside_tests = lines outside;
    killed =
      List.length
        (List.filter
           (fun (r : Verdicts.record) -> r.verdict = Verdicts.Killed)
           found.records);
    not_tested = List.length reached - List.length found.records;
    scope =
      (if narrowed then Report_sections.Selected (List.length dry_run)
       else Report_sections.Suite);
  }

(* Killed elsewhere *)

(* The loop opens only a regular file, because the read of a FIFO or of a
   device can block. *)
let regular path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false

(* The executable of the verdict file that killed each mutant of [reached],
   and the executable of each file that the loop used. A kill counts for the
   mutant of this executable only when the two compiled the same source and
   agree on the extent and the renderings. Only a direct kill counts, so a
   skip never comes from another skip. Of two killers the smaller stays, so
   the order of the files does not count. *)
let killed_elsewhere ~suite reached =
  let own =
    Verdicts.output_file ~exe:Windtrap_runtime.Instr.executable ~suite
  in
  let dir = Filename.dirname own in
  let wanted = Hashtbl.create 64 and killers = Hashtbl.create 64 in
  List.iter
    (fun ((m : Mutate.mutant), _) -> Hashtbl.replace wanted m.id m)
    reached;
  let ignored fmt =
    Printf.ksprintf (fun m -> Os.warn ("--skip-killed ignores " ^ m)) fmt
  in
  let use (file : Verdicts.file) exe =
    List.iter
      (fun (r : Verdicts.record) ->
        let same (m : Mutate.mutant) =
          Option.is_some m.source_digest
          && r.source_digest = m.source_digest
          && r.end_line = m.end_line && r.end_col = m.end_col
          && String.equal r.before m.before
          && String.equal r.after m.after
        in
        match (r.verdict, Hashtbl.find_opt wanted r.id) with
        | Verdicts.Killed, Some m when same m -> (
            match Hashtbl.find_opt killers r.id with
            | Some prior when String.compare prior exe <= 0 -> ()
            | Some _ | None -> Hashtbl.replace killers r.id exe)
        | _ -> ())
      (Verdicts.records file.verdicts)
  in
  let candidate name =
    Filename.check_suffix name ("." ^ Verdicts.format.ext)
    && name <> Filename.basename own
    && regular (Filename.concat dir name)
  in
  let names =
    match Sys.readdir dir with
    | names ->
        List.filter candidate (List.sort String.compare (Array.to_list names))
    | exception Sys_error _ -> []
  in
  let used =
    List.filter_map
      (fun name ->
        let path = Filename.concat dir name in
        match Verdicts.load path with
        | Error e ->
            ignored "%s" (Pp.to_string Verdicts.pp_error e);
            None
        | Ok { identity = None; _ } ->
            ignored "%s: the file names no executable" path;
            None
        | Ok { refused = Some _; _ } -> None
        | Ok ({ identity = Some identity; _ } as file) -> (
            match Windtrap_runtime.Instr.freshness ~path (Some identity) with
            | Orphan exe ->
                ignored "%s: its executable (%s) no longer exists" path exe;
                None
            | Stale exe ->
                ignored "%s: not written by the executable now at %s" path exe;
                None
            | Fresh ->
                use file identity.exe;
                Some identity.exe))
      names
  in
  (killers, used)

(* The line names the executable of each file that the loop used, so that a
   reader can find the run that gave a skip. *)
let elsewhere_line ~used skipped =
  let plural n = if n = 1 then "" else "s" in
  let n = List.length skipped in
  let files =
    match List.sort_uniq String.compare used with
    | [] -> "no other verdict file"
    | exes ->
        let count exe =
          List.length (List.filter (fun (_, e) -> e = exe) skipped)
        in
        strf "the verdict file%s of %s"
          (plural (List.length used))
          (String.concat ", "
             (List.map (fun exe -> strf "%s (%d)" exe (count exe)) exes))
  in
  strf "killed elsewhere: %d mutant%s, not tested, from %s" n (plural n) files

let loop renderer ~scope ~suite (config : Run.config) tests =
  let population = population ~scope in
  let all = Result.value population ~default:[] in
  let reach = { sites = Hashtbl.create 256; outside = Hashtbl.create 16 } in
  let started = Os.counter () in
  let refuse ?say ?reach message =
    refuse ?say ?reach ~suite ~scope all message
  in
  if not (Supervisor.can_spawn ()) then
    refuse
      "this run is in a process that has spawned a domain, after which OCaml \
       refuses Unix.fork, and that the test executable did not start as, so a \
       new start of the executable would not reach the run: mutation testing \
       runs every mutant in a fresh worker, so it cannot run here. Spawn the \
       domain in a test instead"
  else
    let on_reach = observe reach ~xfail:(xfail_paths tests) in
    let pooled = Hashtbl.create 4 in
    let on_pool path = Hashtbl.replace pooled path () in
    match
      Report.run
        ~execute:(fun ?on_event config ->
          Supervisor.execute ~on_reach ~on_pool ?on_event config)
        ~suite
        { config with junit = None }
        tests
    with
    | Error error ->
        (* [Report.run] said why. *)
        refuse ~say:false
          ("its dry run was refused: " ^ Run.startup_message error)
    | Ok outcome -> (
        let dry_run = Run.results outcome.run in
        if dry_run = [] then refuse "no test ran, so there is nothing to mutate"
        else if Run.exit_code (Ok outcome) <> 0 then
          refuse
            "the dry run is red. Mutation scores a passing suite; a score over \
             a failing one is not a score"
        else
          match population with
          | Error No_site_on_lines ->
              Os.say no_site_on_lines;
              Ok outcome
          | Error reason -> refuse (refusal ~scope reason)
          | Ok population -> (
              let reached, unreached =
                List.partition_map
                  (fun (m : Mutate.mutant) ->
                    match Hashtbl.find_opt reach.sites m.id with
                    | Some site -> Either.Left (m, site)
                    | None -> Either.Right m)
                  population
              in
              let outside, unreached =
                List.partition
                  (fun (m : Mutate.mutant) -> Hashtbl.mem reach.outside m.id)
                  unreached
              in
              let wall = Float.max 0.01 (Os.count_s started) in
              let skipped, to_test, lines =
                if not scope.skip_killed then ([], reached, [])
                else
                  let killers, used = killed_elsewhere ~suite reached in
                  let skipped, to_test =
                    List.partition_map
                      (fun (((m : Mutate.mutant), _) as mutant) ->
                        match Hashtbl.find_opt killers m.id with
                        | Some exe -> Either.Left (m, exe)
                        | None -> Either.Right mutant)
                      reached
                  in
                  (skipped, to_test, [ elsewhere_line ~used skipped ])
              in
              let narrowed = narrows_suite config ~focus:outcome.focus_active in
              let save records =
                if narrowed then ([], save_narrowed ~suite ~scope population)
                else
                  save ~suite ~scope
                    (records
                    @ List.map
                        (fun (m, exe) ->
                          Verdicts.record_of_mutant m
                            (Verdicts.Killed_elsewhere { exe }))
                        skipped
                    @ recorded Verdicts.Outside_tests outside
                    @ recorded Verdicts.Unreached unreached)
              in
              match
                test_mutants renderer ~suite config tests ~dry_run ~pooled ~wall
                  ~save to_test
              with
              | exception Sys_error _ when !signal = Some Sys.sigpipe ->
                  Os.die_by Sys.sigpipe
              | Refused_by message, _ ->
                  Report.mutation_refused renderer message;
                  refuse ~say:false ~reach:(reached, unreached, outside) message
              | (Finished _ | Interrupted _), _ when !signal = Some Sys.sigpipe
                ->
                  Os.die_by Sys.sigpipe
              | Interrupted (s, testing), found ->
                  Report.mutation_interrupted renderer ~lines
                    ~testing:
                      (Option.map
                         (fun (m : Mutate.mutant) -> Mutate.id_to_string m.id)
                         testing)
                    (report ~narrowed ~dry_run ~reached ~unreached ~outside
                       found);
                  flush_descriptors ();
                  Os.die_by s
              | Finished (changed, note), found -> (
                  Report.mutation_finish ?note ~lines renderer
                    (report ~changed ~narrowed ~dry_run ~reached ~unreached
                       ~outside found);
                  flush_descriptors ();
                  match !signal with
                  | Some s -> Os.die_by s
                  | None -> Ok outcome)))

(* The armed run *)

(* A dismissed site has no guard, so an armed run of its mutant is the
   unarmed run, and it would end on a false "not evaluated". *)
let dismissal (mutant : Mutate.mutant) reason =
  strf
    "%s: [@mutate off] dismisses this mutant%s, so its site has no guard and \
     no run can arm it"
    (Mutate.id_to_string mutant.id)
    (if reason = "" then "" else strf " (%s)" reason)

let armed renderer ~spec ~suite (config : Run.config) tests =
  match
    Result.bind (Mutate.id_of_string spec) (fun id -> Supervisor.arm id)
  with
  | Error (Mutate.Uncatalogued _ as error) ->
      Os.say (Pp.to_string Mutate.pp_arm_error error);
      ordinary ~suite config tests
  | Error error ->
      let message = Pp.to_string Mutate.pp_arm_error error in
      Os.say message;
      Error (Run.Mutation_refused message)
  | Ok ({ dismissed = Some reason; _ } as mutant) ->
      let message = dismissal mutant reason in
      Os.say message;
      Error (Run.Mutation_refused message)
  | Ok mutant ->
      let id = Mutate.id_to_string mutant.id in
      let config =
        { config with baseline = Baseline.Check; mutation = Run.Armed id }
      in
      Report.mutation_armed renderer ~id ~before:mutant.before
        ~after:mutant.after;
      flush_descriptors ();
      (* What module initialization evaluated ran before the mutant was. *)
      Mutate.reset_reach ();
      (* The evaluations of the armed site in each test and outside every
         test, and the tests whose worker ended first, which evaluations are
         unknown. An evaluation outside every test counts as before every
         test. *)
      let reaching = Hashtbl.create 16 and lost = Hashtbl.create 4 in
      let outside = ref None in
      let on_reach test sites =
        List.iter
          (fun (site, n) ->
            if Mutate.compare_id site mutant.id = 0 then
              match test with
              | None ->
                  outside :=
                    Some (saturating_add (Option.value !outside ~default:0) n)
              | Some path ->
                  let hits =
                    Option.value (Hashtbl.find_opt reaching path) ~default:0
                  in
                  Hashtbl.replace reaching path (saturating_add hits n))
          sites
      in
      let on_lost path = Hashtbl.replace lost path () in
      let blind () = not (Supervisor.forks_seen ()) in
      let before () = Option.is_some !outside || blind () in
      (* As in a job, a failure counts when its test or an earlier one, in
         the order of the selection, evaluated the site. *)
      let evaluated_in (r : Run.result) =
        Hashtbl.mem reaching r.path || Hashtbl.mem lost r.path
      in
      (* Under [-x] the run stops at the first failure that kills the
         mutant. *)
      let through = ref false in
      let stop_after (r : Run.result) =
        through := !through || evaluated_in r;
        config.bail && kills r && (!through || before ())
      in
      let result =
        Report.run
          ~execute:(fun ?on_event config ->
            Supervisor.execute ~on_reach ~on_lost ~stop_after ?on_event config)
          ~suite config tests
      in
      (match result with
      | Ok outcome when Run.results outcome.run <> [] -> (
          let results = Run.results outcome.run in
          let _, caused, failed_before =
            List.fold_left
              (fun (evaluated, caused, failed_before) (r : Run.result) ->
                let evaluated = evaluated || evaluated_in r in
                if not (kills r) then (evaluated, caused, failed_before)
                else if evaluated then (evaluated, true, failed_before)
                else (evaluated, caused, true))
              (before (), false, false)
              results
          in
          (* Only the rows that the run reported count. *)
          let hits xfailed =
            List.fold_left
              (fun acc (r : Run.result) ->
                match Hashtbl.find_opt reaching r.path with
                | Some n when Option.is_some r.xfail = xfailed ->
                    Some (saturating_add (Option.value acc ~default:0) n)
                | Some _ | None -> acc)
              None results
          in
          let in_other =
            match (!outside, hits false) with
            | None, None -> None
            | a, b ->
                Some
                  (saturating_add
                     (Option.value a ~default:0)
                     (Option.value b ~default:0))
          in
          let in_xfail = hits true in
          let release_failed = outcome.release_failures <> [] in
          let xfail_failed =
            List.exists
              (fun (r : Run.result) ->
                Option.is_some r.xfail && counted_failure r)
              results
          in
          match (in_other, in_xfail) with
          | _ when caused -> Report.mutation_killed renderer
          | (Some _, _ | _, Some _) when release_failed ->
              Report.mutation_killed renderer
          | _ when release_failed && blind () -> Report.mutation_killed renderer
          | None, None ->
              Report.mutation_not_evaluated renderer
                ~failed:(failed_before || release_failed)
          | None, Some _ -> Report.mutation_not_reached renderer
          | Some n, x ->
              Report.mutation_survived renderer
                ~hits:(saturating_add n (Option.value x ~default:0))
                ~xfail_failed ~failed_before)
      | Ok _ | Error _ -> ());
      flush_descriptors ();
      result

let execute_and_report ~suite (config : Run.config) tests =
  match config.mutation with
  | Run.No_mutation -> ordinary ~suite config tests
  | Run.Armed spec -> armed (Report.terminal config) ~spec ~suite config tests
  | Run.Loop _ when Sys.win32 ->
      let message =
        "mutation testing needs worker processes, which windtrap does not \
         start on Windows"
      in
      Os.say message;
      Error (Run.Mutation_refused message)
  | Run.Loop scope when not config.broadcast.mutate ->
      loop (Report.terminal config) ~scope ~suite config tests
  | Run.Loop scope -> (
      match (population ~scope, Run.list_selection config ~suite tests) with
      | Error reason, _ ->
          Os.say (unmutated ~scope reason);
          ordinary ~suite config tests
      | Ok _, Ok [] -> ordinary ~suite config tests
      | Ok _, (Ok (_ :: _) | Error _) ->
          loop (Report.terminal config) ~scope ~suite config tests)
