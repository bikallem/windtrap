(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Mutation verdicts: what a run made of each mutant, and the [.mutants] file
    that carries the verdicts of one executable to the merge.

    The mutation loop writes one verdict file for each test executable.
    [windtrap mutants] loads the files of a project and combines them with
    {!merge}, under which a mutant that is killed anywhere is killed. Nothing
    here runs when the module loads or when the process exits. *)

(** {1:verdicts Verdicts}

    A verdict is one of seven cases, and never a boolean or an exit code. A
    failure to supervise the child that arms a mutant is none of the seven, and
    a caller must record no verdict for it. *)

type reaching_test = string list
(** The type for a test that evaluated a mutant, by its path: the names of its
    groups, the outermost first, and then its own, as [["arithmetic"; "adds"]].
*)

(** The type for verdicts. A survivor always names a reaching test, because a
    mutant that no test reached is {!Outside_tests} or {!Unreached}. *)
type verdict =
  | Killed of { by : reaching_test option }
      (** A test failed in or after the first test that evaluated the armed
          site, or a fixture release failed after an evaluation. Or the child
          that armed the mutant crashed or hung. [by] is the first test that
          failed in this way. It is [None] when no one test is known: the child
          crashed, hung or recorded no test, or a fixture release failed. [by]
          is a reaching test, except in exec mode of the loop: there, a child
          can also run the tests before the reaching tests, and one of them can
          fail. *)
  | Killed_elsewhere of { exe : string }
      (** No child tested the mutant. The verdict file of the executable [exe]
          gave it {!Killed}, with the source digest of this run. [exe] is the
          identity on that file ({!Instr.identity}), and it is not [""]. Only a
          loop under [--mutate-skip-killed] gives it. *)
  | Survived of {
      first : reaching_test;
      others : reaching_test list;
      runs : int;
          (** The runs of the child of the mutant that gave this verdict, [1] or
              more. Each run let the mutant survive. A merge adds the runs
              ({!add}). *)
    }
      (** A process of the child evaluated the armed site. No test failed in or
          after the first test that evaluated it, and no fixture release failed.
          A test that failed before that test does not count. [first] and
          [others] are the reaching tests, sorted and without duplicates, and
          [first] is the first. *)
  | Not_evaluated
      (** The child did not evaluate the armed site, so it ran the code of the
          unmutated program and tells nothing about the mutant. The dry run
          evaluated the site and the child did not, as when the dry run cached
          the result of the site in a table or a forced lazy value. A test that
          failed in the child failed for a reason of its own, and does not kill
          the mutant. *)
  | Outside_tests
      (** No test reached the site, and the dry run evaluated it outside every
          test, at module initialization or in a fixture release. The loop forks
          no child for the mutant. *)
  | Filtered of string
      (** The rewriter filtered the mutant, for this reason (see
          {!Mutate.dismissal.Filtered}). The loop forks no child for the mutant,
          and a score does not count it. *)
  | Unreached
      (** No test reached the site, and the dry run did not evaluate it outside
          every test either. The loop forks no child for the mutant. *)

val survived : ?runs:int -> reaching_test list -> verdict
(** [survived ?runs ts] is the {!Survived} verdict whose reaching tests are
    [ts], sorted and without duplicates, with [runs] runs, [1] by default.
    Raises [Invalid_argument] if [ts] is empty or if [runs] is below [1]. *)

type scored = [ `Killed | `Survived | `Not_evaluated ]
(** The type for the classes of the verdicts that a score counts. *)

val scored : verdict -> scored option
(** [scored v] is the class of [v]: [`Killed] for {!Killed} and
    {!Killed_elsewhere}, [`Survived] for {!Survived}, [`Not_evaluated] for
    {!Not_evaluated}, and [None] for the other verdicts. *)

(** {1:collections Collections} *)

type record = {
  id : Mutate.id;  (** The identifier of the mutant. *)
  before : string;
      (** The text of the original site, as {!Mutate.type-mutant} gives it. *)
  after : string;
      (** The text of the mutant, as {!Mutate.type-mutant} gives it. *)
  source_digest : string option;
      (** The lowercase hexadecimal MD5 of the source file of the mutant when
          the run read it, and [None] when the run could not read the file. A
          later run compares it with the file that it reads, to find out if the
          file changed. *)
  verdict : verdict;  (** What the run made of the mutant. *)
  previous : verdict option;
      (** The verdict of the mutant in the verdict file that the run replaced,
          when that record has the source digest of this record, and the digest
          is not [None]. It is [None] if not. The run that writes the file sets
          it. *)
}
(** The type for the record of one mutant. A record is self-describing: it
    carries the two renderings that a report draws the mutant with, so a report
    needs no catalogue and outlives the executable that produced it. *)

val record_of_mutant :
  ?source_digest:string -> Mutate.mutant -> verdict -> record
(** [record_of_mutant ?source_digest m v] is the record of [m] with the verdict
    [v], the digest [source_digest], [None] by default, and no previous verdict.
    [m.dismissed] is dropped. *)

val changed : record -> (scored * scored) option
(** [changed r] is [Some (was, is)] when [r.previous] is [Some p], [scored p] is
    [Some was], [scored r.verdict] is [Some is], and [was] is not [is]. It is
    [None] if not. *)

type t
(** The type for verdict collections: finite maps from {!Mutate.type-id} to
    {!type-record}, ordered by {!Mutate.compare_id}. They are immutable. *)

val empty : t
(** [empty] is the collection with no record. *)

val add : t -> record -> t
(** [add t r] is [t] with [r] recorded. A {!Survived} verdict is sorted on its
    way in, and a [runs] below [1] becomes [1]. When [t] already holds a record
    under [r.id], the smaller [(before, after, source_digest)] triple in
    lexicographic order is kept, and the two verdicts combine into the verdict
    of a mutant that one executable saw one way and another the other way. It is
    {!Killed} if either is, and its killing test is the smaller of the two that
    are known, if any. Otherwise it is {!Killed_elsewhere} if either is, with
    the smaller [exe]. Otherwise it is {!Not_evaluated} if either is, then
    {!Survived} with the reaching tests of both and the sum of their runs, at
    most [max_int], if either is, then {!Outside_tests} if either is, then
    {!Filtered} with the smaller reason if either is, and {!Unreached} if both
    are. The two previous verdicts combine in the same way, and a missing one
    leaves the other unchanged.

    [add] checks nothing of [r.id], [r.source_digest] and the [exe] of a
    {!Killed_elsewhere}, in the verdict and in the previous verdict. It accepts
    an empty [file], a [line] below [1], a negative [col], a [rewrite] outside
    {!Mutate.rewrites}, a digest that is not 32 lowercase hexadecimal digits and
    an empty [exe], and {!load} then refuses the file that {!save} writes for
    the collection. *)

val records : t -> record list
(** [records t] is the records of [t], ordered by {!Mutate.compare_id}. *)

val filter : (record -> bool) -> t -> t
(** [filter keep t] is the records of [t] for which [keep] is [true]. *)

val merge : t -> t -> t
(** [merge a b] is the union of [a] and [b], where two records that share an
    identifier are combined as {!add} does. [merge] is commutative and
    associative, {!empty} is its unit, and an {!Unreached} verdict leaves the
    verdict it is combined with unchanged, so merging any number of files in any
    order gives one answer. [merge a a] is [a] with the runs of each survivor
    doubled, at most [max_int], in the verdict and in the previous verdict. Thus
    a merge must not get one file two times. The previous verdict of a merged
    record tells nothing of one executable. [windtrap mutants] reads the
    previous verdicts of each file before the merge. *)

val with_previous : prior:t -> t -> t
(** [with_previous ~prior t] is [t] in which the [previous] of each record [r]
    is [Some p.verdict] when [prior] has a record [p] under [r.id], and
    [p.source_digest] is [r.source_digest] and is not [None]. It is [None] if
    not. The [previous] of [p] is not used. *)

(** {1:files Verdict files}

    An executable has one verdict file, at {!output_file}.

    The first line of a file is the magic line [windtrap-mutants-v8], which
    carries the version of the format. A file with another first line is
    refused, never converted, and nothing is promised from one version to the
    next. *)

(** The type for the errors of reading a verdict file, which is {!Instr.error},
    where each case is described. *)
type error = Instr.error =
  | Unknown_format of { path : string; header : string }
  | Unreadable of { path : string; reason : string }
  | Corrupt of { path : string; reason : string }

val pp_error : Format.formatter -> error -> unit
(** [pp_error ppf e] is [Instr.pp_error format ppf e]. *)

type identity = Instr.identity = { exe : string; digest : string }
(** The type for the identity of the writer of a verdict file, which is
    {!Instr.identity}. *)

val format : Instr.format
(** [format] is the constants of the [.mutants] format: the magic line above,
    the data directory [mutants], the extension [mutants] and the kind
    [verdict]. *)

val writer_identity : exe:string -> identity option
(** [writer_identity ~exe] is the identity to record for the executable at
    [exe], whose [exe] is [Instr.exe_identity ~exe], or [None] when [exe] cannot
    be read. *)

val output_file : exe:string -> string
(** [output_file ~exe] is [Instr.output_file format ~exe], the one verdict file
    of the executable at [exe]. An executable that is renamed or moved leaves
    its previous file behind. *)

val load : string -> (t * identity option * string option, error) result
(** [load path] is [Ok (t, identity, suite)] when the file at [path] is a
    verdict file, where [identity] is the recorded writer and [suite] the
    recorded suite, if any. The file is read with {!Instr.read_file}, and every
    error names [path]. Otherwise it is the error of the read,
    [Error (Unknown_format _)] for another first line, or [Error (Corrupt _)]
    for data that is truncated or invalid:
    - a negative count, or a count larger than the input,
    - an empty file name, a line below [1] or a negative column,
    - a rewrite outside {!Mutate.rewrites}, an unknown verdict, or a missing or
      unknown previous verdict,
    - a source digest that is not empty and not 32 lowercase hexadecimal digits,
    - a survivor with no reaching test or with fewer than one run, a killed
      mutant with more than one killing test, an empty killing executable, or a
      second record for one identifier,
    - a malformed identity line, a suite count that is not [0] or [1], or bytes
      after the last record.

    A previous verdict obeys the rules of a verdict.

    Nothing is repaired, and a file with one malformed record is not read at
    all. *)

val save : ?identity:identity -> ?suite:string -> string -> t -> unit
(** [save ?identity ?suite path t] writes [t] to [path] in the format of a
    verdict file, with {!Instr.write_file}. Records are ordered by
    {!Mutate.compare_id} and reaching tests are sorted, so equal collections
    give equal files. [identity] is recorded after the magic line when it is
    given, and then [suite], the name that the writer gave to [Windtrap.run],
    when it is given. A merged collection has no single writer and is written
    without the two.

    [load path] is then [Ok (t, identity, suite)] for every [t] whose
    identifiers {!load} accepts, and [Error (Corrupt _)] for any other (see
    {!add}). A collection built from the mutants of {!Mutate.val-catalogue}
    round-trips, unless a source file was registered under the name [""].

    Raises [Invalid_argument] before anything is written if [identity.exe] is
    empty or if [identity.digest] is not 32 lowercase hexadecimal digits, and
    [Sys_error] if the file cannot be written. *)
