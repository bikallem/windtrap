(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf
let ( let* ) = Result.bind

module Files = Map.Make (String)

(* The lines of one file: all of them, or ranges of [count] lines from
   [first]. *)
type lines = All | Ranges of (int * int) list
type t = lines Files.t

let empty = Files.empty

let rec relative file =
  if String.starts_with ~prefix:"./" file then
    relative (String.sub file 2 (String.length file - 2))
  else file

let mem t ~file ~line =
  match Files.find_opt (relative file) t with
  | None -> false
  | Some All -> true
  | Some (Ranges ranges) ->
      List.exists
        (fun (first, count) -> first <= line && line < first + count)
        ranges

let add_file t file = Files.add file All t

let add_range t file range =
  Files.update file
    (function
      | None -> Some (Ranges [ range ])
      | Some All -> Some All
      | Some (Ranges ranges) -> Some (Ranges (range :: ranges)))
    t

(* The diff *)

exception Unreadable of string

let unreadable fmt = Printf.ksprintf (fun s -> raise (Unreadable s)) fmt

(* A path that git quotes is in double quotes, with the escapes of C: a
   backslash and a letter of [abtnvfr], a double quote or a backslash, or
   three octal digits for a byte. *)
let unquote quoted =
  let n = String.length quoted in
  let b = Buffer.create n in
  let fail what = unreadable "the quoted path %s %s" quoted what in
  (* The byte at [i], which comes before the closing quote. *)
  let at i = if i >= n then fail "has no end" else quoted.[i] in
  let octal i =
    match at i with
    | '0' .. '7' as c -> Char.code c - Char.code '0'
    | _ -> fail "has a bad escape"
  in
  let rec go i =
    match at i with
    | '"' when i = n - 1 -> Buffer.contents b
    | '"' -> fail "has bytes after its end"
    | '\\' -> (
        match at (i + 1) with
        | '0' .. '3' ->
            let code =
              (octal (i + 1) * 64) + (octal (i + 2) * 8) + octal (i + 3)
            in
            Buffer.add_char b (Char.chr code);
            go (i + 4)
        | c ->
            Buffer.add_char b
              (match c with
              | 'a' -> '\007'
              | 'b' -> '\b'
              | 't' -> '\t'
              | 'n' -> '\n'
              | 'v' -> '\011'
              | 'f' -> '\012'
              | 'r' -> '\r'
              | '"' | '\\' -> c
              | _ -> fail "has a bad escape");
            go (i + 2))
    | c ->
        Buffer.add_char b c;
        go (i + 1)
  in
  go 1

(* The path of a [+++] line, which git ends with a tab when the path holds a
   space. *)
let new_path header =
  let path =
    if String.ends_with ~suffix:"\t" header then
      String.sub header 0 (String.length header - 1)
    else header
  in
  if path = "/dev/null" then None
  else
    let path =
      if String.starts_with ~prefix:"\"" path then unquote path else path
    in
    if String.starts_with ~prefix:"b/" path then
      Some (String.sub path 2 (String.length path - 2))
    else unreadable "the file %S has no b/ prefix" path

(* [range "c,d"] is [(c, d)], and [range "c"] is [(c, 1)]. *)
let range header spec =
  let digits s =
    s <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) s
  in
  let number s =
    match if digits s then int_of_string_opt s else None with
    | Some n -> n
    | None -> unreadable "the hunk header %S" header
  in
  match String.split_on_char ',' spec with
  | [ first ] -> (number first, 1)
  | [ first; count ] -> (number first, number count)
  | _ -> unreadable "the hunk header %S" header

(* [@@ -a,b +c,d @@ context]: [b] lines that the hunk removes, and [d] lines
   from [c] that it adds. *)
let hunk header =
  let after prefix s =
    if String.starts_with ~prefix s then
      Some (String.sub s 1 (String.length s - 1))
    else None
  in
  match String.split_on_char ' ' header with
  | "@@" :: old :: added :: "@@" :: _ -> (
      match (after "-" old, after "+" added) with
      | Some old, Some added -> (snd (range header old), range header added)
      | _ -> unreadable "the hunk header %S" header)
  | _ -> unreadable "the hunk header %S" header

let of_diff text =
  (* [removed] and [added] are the lines of the hunk that remain to read. *)
  let rec read t file ~removed ~added = function
    | [] ->
        if removed > 0 || added > 0 then unreadable "a hunk ends early" else t
    | line :: lines when removed > 0 || added > 0 -> (
        match if line = "" then ' ' else line.[0] with
        | '-' when removed > 0 ->
            read t file ~removed:(removed - 1) ~added lines
        | '+' when added > 0 -> read t file ~removed ~added:(added - 1) lines
        | '\\' -> read t file ~removed ~added lines
        | _ -> unreadable "a hunk ends early, at %S" line)
    | line :: lines ->
        if String.starts_with ~prefix:"+++ " line then
          let file = new_path (String.sub line 4 (String.length line - 4)) in
          read t (Some file) ~removed:0 ~added:0 lines
        else if String.starts_with ~prefix:"@@ " line then
          let removed, (first, count) = hunk line in
          let t =
            match file with
            | None -> unreadable "a hunk comes before its file"
            | Some None -> t
            | Some (Some _) when count = 0 -> t
            | Some (Some path) -> add_range t path (first, count)
          in
          read t file ~removed ~added:count lines
        else read t file ~removed:0 ~added:0 lines
  in
  match
    read empty None ~removed:0 ~added:0 (String.split_on_char '\n' text)
  with
  | t -> Ok t
  | exception Unreadable reason ->
      Error ("cannot read the output of git diff: " ^ reason)

(* Git *)

(* Git writes a warning before its error, and the error last. *)
let last_line s =
  match List.rev (String.split_on_char '\n' (String.trim s)) with
  | line :: _ -> String.trim line
  | [] -> ""

let rec read_all fd b chunk =
  match Unix.read fd chunk 0 (Bytes.length chunk) with
  | 0 -> Buffer.contents b
  | n ->
      Buffer.add_subbytes b chunk 0 n;
      read_all fd b chunk
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_all fd b chunk

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

(* A [-u] option in [GIT_DIFF_OPTS] has priority over [--unified=0]. Its
   context lines would end a hunk early in {!of_diff}, thus git gets the
   environment of the process without this variable. *)
let environment () =
  Array.of_list
    (List.filter
       (fun binding ->
         not (String.starts_with ~prefix:"GIT_DIFF_OPTS=" binding))
       (Array.to_list (Unix.environment ())))

(* Standard error goes to a file: git can fill a pipe there while this
   process reads the other. [silent] is the reason of a failure that writes
   nothing on standard error. *)
let git ?silent ~root args =
  let command = match args with sub :: _ -> "git " ^ sub | [] -> "git" in
  let argv = Array.of_list ("git" :: "-C" :: root :: args) in
  let failed reason = Error (strf "%s failed: %s" command reason) in
  match Filename.temp_file "windtrap-git" ".err" with
  | exception Sys_error reason -> failed reason
  | err_path -> (
      Fun.protect ~finally:(fun () ->
          try Sys.remove err_path with Sys_error _ -> ())
      @@ fun () ->
      match
        let open_file path flags =
          Unix.openfile path (Unix.O_CLOEXEC :: flags) 0o600
        in
        let closing fd fn = Fun.protect ~finally:(fun () -> Unix.close fd) fn in
        (* Each descriptor closes also when a later call raises. *)
        let pid, out =
          let stdin = open_file Filename.null [ Unix.O_RDONLY ] in
          closing stdin @@ fun () ->
          let stderr = open_file err_path [ Unix.O_WRONLY; Unix.O_TRUNC ] in
          closing stderr @@ fun () ->
          let out, into = Unix.pipe ~cloexec:true () in
          match
            closing into (fun () ->
                Unix.create_process_env "git" argv (environment ()) stdin into
                  stderr)
          with
          | pid -> (pid, out)
          | exception e ->
              Unix.close out;
              raise e
        in
        let output =
          Fun.protect
            ~finally:(fun () -> Unix.close out)
            (fun () -> read_all out (Buffer.create 4096) (Bytes.create 4096))
        in
        (output, wait pid)
      with
      | exception Unix.Unix_error (error, _, _) ->
          failed (Unix.error_message error)
      | output, Unix.WEXITED 0 -> Ok output
      | _, status -> (
          let said =
            last_line
              (try In_channel.with_open_bin err_path In_channel.input_all
               with Sys_error _ -> "")
          in
          match (said, status, silent) with
          | "", Unix.WEXITED _, Some reason -> Error reason
          | "", Unix.WEXITED code, None -> failed (strf "exit code %d" code)
          | "", (Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
              failed "killed by a signal"
          | said, _, _ -> failed said))

let of_git ~root rev =
  let* () =
    if rev = "" || String.starts_with ~prefix:"-" rev then
      Error
        (strf
           "%S is not a revision: it is empty or starts with -, which git \
            reads as an option"
           rev)
    else Ok ()
  in
  (* Git reads all of the text after [:/] as a regex of a commit message. A
     [^{commit}] suffix on [rev] thus becomes part of that regex. Git first
     gives the object that [rev] names, and then peels it to a commit. *)
  let rev_parse name =
    Result.map String.trim
      (git
         ~silent:(strf "%S names no commit" rev)
         ~root
         [ "rev-parse"; "--verify"; "--quiet"; name ])
  in
  let* object_name = rev_parse rev in
  let* commit = rev_parse (object_name ^ "^{commit}") in
  (* Under [diff.interHunkContext], git joins two near hunks with the lines
     between them, also at [--unified=0]. For a file that it finds binary,
     by its bytes or by an attribute, git gives no hunk. The options below
     stop the two, so each line of a hunk is a changed line. *)
  let* diff =
    git ~root
      [
        "diff";
        "--unified=0";
        "--inter-hunk-context=0";
        "--text";
        "--relative";
        "--no-renames";
        "--no-color";
        "--no-ext-diff";
        "--no-textconv";
        "--src-prefix=a/";
        "--dst-prefix=b/";
        commit;
        "--";
      ]
  in
  let* untracked =
    git ~root [ "ls-files"; "-z"; "--others"; "--exclude-standard" ]
  in
  let* t = of_diff diff in
  Ok
    (List.fold_left
       (fun t file -> if file = "" then t else add_file t file)
       t
       (String.split_on_char '\000' untracked))
