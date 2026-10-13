(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* What git gives is pinned by test/cram/bin/since.t, which runs it in a
   repository of its own. This suite reads diffs that it states. It runs
   [of_git] only with no git on [PATH], or with a script in place of git. *)

open Windtrap
module Changed_lines = Windtrap.Private.Changed_lines

(* The lines from 1 to 12 of [file] that [t] holds. *)
let held t file =
  List.filter (fun line -> Changed_lines.mem t ~file ~line) (List.init 12 succ)

let parsed text =
  require_ok ~pp:Format.pp_print_string (Changed_lines.of_diff text)

let refused text =
  require_error
    ~pp:(fun ppf _ -> Format.pp_print_string ppf "lines")
    (Changed_lines.of_diff text)

let diff =
  String.concat "\n"
    [
      "diff --git a/lib/a.ml b/lib/a.ml";
      "index d68dd40..6fe8acc 100644";
      "--- a/lib/a.ml";
      "+++ b/lib/a.ml";
      "@@ -2 +2 @@ let a = 1";
      "-let b = 2";
      "+let b = 3";
      "@@ -4,0 +5,2 @@ let d = 4";
      "+let e = 5";
      "+++ b/lib/fake.ml";
      "@@ -7,2 +8,0 @@";
      "-let g = 7";
      "-let h = 8";
      "@@ -11 +10 @@";
      "-let k = 1";
      "\\ No newline at end of file";
      "+let k = 2";
      "\\ No newline at end of file";
      "diff --git a/lib/gone.ml b/lib/gone.ml";
      "deleted file mode 100644";
      "--- a/lib/gone.ml";
      "+++ /dev/null";
      "@@ -1,2 +0,0 @@";
      "-let x = 1";
      "-let y = 2";
      "diff --git a/lib/new.ml b/lib/new.ml";
      "new file mode 100644";
      "--- /dev/null";
      "+++ b/lib/new.ml";
      "@@ -0,0 +1,3 @@";
      "+let x = 1";
      "+let y = 2";
      "+let z = 3";
      "diff --git a/img.png b/img.png";
      "Binary files a/img.png and b/img.png differ";
      "diff --git a/lib/sp ace.ml b/lib/sp ace.ml";
      "--- a/lib/sp ace.ml\t";
      "+++ b/lib/sp ace.ml\t";
      "@@ -1 +1 @@";
      "-one";
      "+two";
      {|diff --git "a/lib/q\"\303\251.ml" "b/lib/q\"\303\251.ml"|};
      {|--- "a/lib/q\"\303\251.ml"|};
      {|+++ "b/lib/q\"\303\251.ml"|};
      "@@ -3 +3 @@";
      "-q";
      "+Q";
      {|+++ "b/\a\b\t\n\v\f\r\"\\\101.ml"|};
      "@@ -4 +4 @@";
      "-e";
      "+E";
      "";
    ]

let reads_a_diff () =
  let t = parsed diff in
  let rows =
    List.map
      (fun file -> (file, held t file))
      [
        "lib/a.ml";
        "lib/fake.ml";
        "lib/gone.ml";
        "lib/new.ml";
        "img.png";
        "lib/sp ace.ml";
        "lib/q\"\u{e9}.ml";
        "\007\b\t\n\011\012\r\"\\A.ml";
      ]
  in
  equal
    (list (pair string (list int)))
    [
      ("lib/a.ml", [ 2; 5; 6; 10 ]);
      ("lib/fake.ml", []);
      ("lib/gone.ml", []);
      ("lib/new.ml", [ 1; 2; 3 ]);
      ("img.png", []);
      ("lib/sp ace.ml", [ 1 ]);
      ("lib/q\"\u{e9}.ml", [ 3 ]);
      ("\007\b\t\n\011\012\r\"\\A.ml", [ 4 ]);
    ]
    rows

let unreadable =
  [
    ( "a hunk before its file",
      "@@ -1 +1 @@\n-a\n+b\n",
      "a hunk comes before its file" );
    ( "a header without its ranges",
      "+++ b/a.ml\n@@ -1 @@\n-a\n",
      {|the hunk header "@@ -1 @@"|} );
    ( "a range that is not a number",
      "+++ b/a.ml\n@@ -1 +x,2 @@\n+a\n+b\n",
      {|the hunk header "@@ -1 +x,2 @@"|} );
    ( "a negative count",
      "+++ b/a.ml\n@@ -1 +1,-2 @@\n",
      {|the hunk header "@@ -1 +1,-2 @@"|} );
    ( "a removed range without its -",
      "+++ b/a.ml\n@@ 1 +1 @@\n+b\n",
      {|the hunk header "@@ 1 +1 @@"|} );
    ( "an added range without its +",
      "+++ b/a.ml\n@@ -1 1 @@\n-a\n",
      {|the hunk header "@@ -1 1 @@"|} );
    ( "a range with a separator in its number",
      "+++ b/a.ml\n@@ -1 +1_0 @@\n",
      {|the hunk header "@@ -1 +1_0 @@"|} );
    ( "a removed line past the removed range",
      "+++ b/a.ml\n@@ -1,0 +1 @@\n-a\n+b\n",
      {|a hunk ends early, at "-a"|} );
    ( "an added line past the added range",
      "+++ b/a.ml\n@@ -1 +1,0 @@\n+b\n-a\n",
      {|a hunk ends early, at "+b"|} );
    ( "a hunk shorter than its header",
      "+++ b/a.ml\n@@ -1,2 +1 @@\n-a\n+b\n",
      {|a hunk ends early, at ""|} );
    ( "a hunk at the end of the diff",
      "+++ b/a.ml\n@@ -1 +1 @@\n-a",
      "a hunk ends early" );
    ( "a context line in a hunk",
      "+++ b/a.ml\n@@ -1 +1 @@\n a\n",
      {|a hunk ends early, at " a"|} );
    ( "a file without the b/ prefix",
      "+++ a.ml\n@@ -1 +1 @@\n-a\n+b\n",
      {|the file "a.ml" has no b/ prefix|} );
    ( "a quoted path without its end",
      "+++ \"b/a.ml\n@@ -1 +1 @@\n-a\n+b\n",
      {|the quoted path "b/a.ml has no end|} );
    ( "a quoted path that ends in a backslash",
      "+++ \"b/a\\",
      {|the quoted path "b/a\ has no end|} );
    ( "a quoted path that ends in an octal escape",
      "+++ \"b/\\30",
      {|the quoted path "b/\30 has no end|} );
    ( "a quoted path with bytes after its end",
      "+++ \"b/a\" x\n@@ -1 +1 @@\n-a\n+b\n",
      {|the quoted path "b/a" x has bytes after its end|} );
    ( "a bad octal escape",
      "+++ \"b/\\39\"\n@@ -1 +1 @@\n-a\n+b\n",
      {|the quoted path "b/\39" has a bad escape|} );
    ( "a bad escape",
      "+++ \"b/a\\q.ml\"\n@@ -1 +1 @@\n-a\n+b\n",
      {|the quoted path "b/a\q.ml" has a bad escape|} );
  ]

(* The descriptors of the process, on a system that lists them. *)
let descriptors () =
  match Sys.readdir "/proc/self/fd" with
  | fds -> Some (Array.length fds)
  | exception Sys_error _ -> None

(* A [PATH] that holds no git: [Unix.create_process_env] raises. *)
let without_git () =
  let path = Sys.getenv_opt "PATH" in
  let empty = Filename.temp_dir "windtrap-path" "" in
  Fun.protect ~finally:(fun () ->
      Unix.putenv "PATH" (Option.value ~default:"" path);
      Sys.rmdir empty)
  @@ fun () ->
  Unix.putenv "PATH" empty;
  let before = descriptors () in
  let result = Changed_lines.of_git ~root:"." "HEAD" in
  (match (before, descriptors ()) with
  | Some before, Some after -> equal int before after
  | None, _ | _, None -> ());
  starts_with ~affix:"git rev-parse failed: "
    (require_error ~pp:(fun ppf _ -> Format.pp_print_string ppf "lines") result)

(* A [PATH] whose git is a script. The script writes its arguments to a
   file, one on each line, then a warning and an error on standard error,
   and exits 128. *)
let failing_git () =
  if Sys.win32 then skip ~reason:"the git of this test is a shell script" ();
  let path = Sys.getenv_opt "PATH" in
  let dir = Filename.temp_dir "windtrap-path" "" in
  let git = Filename.concat dir "git" and args = Filename.concat dir "args" in
  Out_channel.with_open_bin git (fun oc ->
      Printf.fprintf oc
        "#!/bin/sh\n\
         printf '%%s\\n' \"$@\" > %s\n\
         echo 'warning: a warning' >&2\n\
         echo 'fatal: an error' >&2\n\
         exit 128\n"
        (Filename.quote args));
  Unix.chmod git 0o755;
  Fun.protect ~finally:(fun () ->
      Unix.putenv "PATH" (Option.value ~default:"" path);
      List.iter
        (fun file -> try Sys.remove file with Sys_error _ -> ())
        [ git; args ];
      Sys.rmdir dir)
  @@ fun () ->
  Unix.putenv "PATH" dir;
  let result = Changed_lines.of_git ~root:"/the/root" "HEAD" in
  equal string "git rev-parse failed: fatal: an error"
    (require_error ~pp:(fun ppf _ -> Format.pp_print_string ppf "lines") result);
  equal (list string)
    [ "-C"; "/the/root"; "rev-parse"; "--verify"; "--quiet"; "HEAD"; "" ]
    (String.split_on_char '\n'
       (In_channel.with_open_bin args In_channel.input_all))

let lines =
  group "Changed lines"
    [
      test "empty holds no line" (fun () ->
          equal (list int) [] (held Changed_lines.empty "lib/a.ml"));
      test
        "of_diff reads the added lines of each file, and no line of a header \
         or of a removal"
        reads_a_diff;
      test "mem ignores a leading ./ of the file" (fun () ->
          let t = parsed "+++ b/lib/a.ml\n@@ -1 +1 @@\n-a\n+b\n" in
          equal (list int) [ 1 ] (held t "./lib/a.ml");
          equal (list int) [] (held t "a.ml"));
      test "add_file holds every line of the file" (fun () ->
          let t = Changed_lines.add_file Changed_lines.empty "lib/b.ml" in
          equal (list int) (List.init 12 succ) (held t "lib/b.ml");
          equal (list int) [] (held t "lib/a.ml"));
      test "add_file holds every line of a file that a diff changed" (fun () ->
          let t = parsed "+++ b/lib/a.ml\n@@ -1 +1 @@\n-a\n+b\n" in
          let t = Changed_lines.add_file t "lib/a.ml" in
          equal (list int) (List.init 12 succ) (held t "lib/a.ml"));
      cases "of_diff refuses a diff that it cannot read, and names the fault"
        ~name:(fun (name, _, _) -> name)
        unreadable
        (fun (_, text, reason) ->
          equal string
            ("cannot read the output of git diff: " ^ reason)
            (refused text));
      cases "of_git refuses a revision that git reads as an option"
        ~name:(Printf.sprintf "%S") [ ""; "-p"; "--output=x" ] (fun rev ->
          equal string
            (Printf.sprintf
               "%S is not a revision: it is empty or starts with -, which git \
                reads as an option"
               rev)
            (require_error
               ~pp:(fun ppf _ -> Format.pp_print_string ppf "lines")
               (Changed_lines.of_git ~root:"." rev)));
      test "of_git closes each descriptor when git cannot start" without_git;
      test
        "of_git runs git in the root, and a failure gives the last line that \
         git wrote on standard error"
        failing_git;
    ]

let () = exit (run "changed_lines" [ lines ])
