(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The lines that changed since a git revision.

    [--mutate-since REV] tests only the mutants on these lines, and
    [windtrap mutants --since REV] reports only these mutants. The two read them
    here, from [git diff] of the work tree against [REV] and from the files that
    git does not track. A path is relative to the project root
    ({!Os.project_root}), as the file of a mutant identifier is. *)

type t
(** The type for a set of changed lines, by file. It is immutable. *)

val empty : t
(** [empty] holds no line. *)

val mem : t -> file:string -> line:int -> bool
(** [mem t ~file ~line] is [true] iff [t] holds the line [line] of [file]. A
    leading [./] of [file] is ignored. *)

val of_diff : string -> (t, string) result
(** [of_diff text] is the lines that [text] adds, where [text] is the output of
    [git diff --unified=0 --src-prefix=a/ --dst-prefix=b/].
    - The file of a hunk is the path of its [+++ b/] header line, with the C
      escapes of a quoted path read and a trailing tab removed. A file that the
      diff deletes ([+++ /dev/null]) has no line.
    - The lines of a hunk are those of the range [+c,d] of its [@@] header line:
      [d] lines from line [c], or the line [c] alone without [,d]. A hunk that
      only removes lines ([d = 0]) adds no line.
    - The header lines of a file and a [\ No newline at end of file] line add
      nothing. A line of a hunk is never read as a header, so an added line that
      starts with [++] is not a file.

    [Error reason] is for a hunk header that cannot be read, a hunk that has
    fewer lines than its header gives, or a hunk before the first file. *)

val add_file : t -> string -> t
(** [add_file t file] is [t] with every line of [file]. *)

val of_git : root:string -> string -> (t, string) result
(** [of_git ~root rev] runs git in the directory [root], and is the lines that
    changed in the work tree since the commit [rev]:
    + [git rev-parse --verify --quiet rev] gives the object that [rev] names,
      and a second [git rev-parse] peels it to a commit. A [rev] of the form
      [:/text] thus names a commit by a text of its message.
    + [git diff --unified=0 --inter-hunk-context=0 --text --relative
       --no-renames] against the commit gives the lines that the work tree adds
      or changes, in the tracked files under [root], read by {!of_diff}. A file
      that git finds binary is compared as text. A file that the work tree
      renamed is a new file, so each of its lines is changed. Uncommitted
      changes count, and the lines that a change only removes do not.
    + [git ls-files --others --exclude-standard] gives the files under [root]
      that git does not track and does not ignore. Each of their lines is
      changed.

    The paths are relative to [root]. Each command runs the [git] program that
    the [PATH] environment variable finds, with the environment of the process
    and an empty standard input. Its options stop the git configuration of the
    user from changing the output, for example with an external diff tool, a
    color or the context lines between two hunks. The environment of git does
    not hold [GIT_DIFF_OPTS], which could add context lines to each hunk.

    [Error reason] is for a [rev] that is empty or that starts with [-], which
    git would read as an option, and for a [rev] that names no commit. It is
    also for a git that cannot start, and for a git command that does not exit
    [0], with the last line of what it wrote on standard error, as for a [root]
    outside a git work tree. *)
