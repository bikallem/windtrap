(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

open Windtrap
module Json = Windtrap.Private.Json

let name3 (name, _, _) = name

let string_rows =
  [
    ("a plain string", "plain", {|"plain"|});
    ("the empty string", "", {|""|});
    ("a quote and a backslash", {|say "a\b"|}, {|"say \"a\\b\""|});
    ("LF, CR and TAB", "a\nb\rc\td", {|"a\nb\rc\td"|});
    ( "every other byte below 0x20, and DEL",
      "\x00\x1b\x1f\x7f",
      {|"\u0000\u001b\u001f\u007f"|} );
    ( "well-formed UTF-8 passes",
      "\u{e9}\u{20ac}\u{1d11e}",
      "\"\u{e9}\u{20ac}\u{1d11e}\"" );
    ("a lone byte", "a\xffb", "\"a\u{fffd}b\"");
    ("a cut sequence is one replacement", "a\xe2\x82b", "\"a\u{fffd}b\"");
    ("a sequence cut at the end", "a\xe2\x82", "\"a\u{fffd}\"");
    ( "an encoded surrogate is one replacement for each byte",
      "\xed\xa0\x80",
      "\"\u{fffd}\u{fffd}\u{fffd}\"" );
  ]

(* Up to 16 pieces, drawn from the ASCII range, the escaped bytes and the
   bytes that start or continue a UTF-8 sequence. *)
let bytes =
  Gen.with_pp
    (fun ppf s -> Format.fprintf ppf "%S" s)
    (Gen.map (String.concat "")
       (Gen.list ~size:(Gen.int_range 0 16)
          (Gen.of_list
             [
               "a";
               "\"";
               "\\";
               "\n";
               "\r";
               "\t";
               "\x01";
               "\x7f";
               "\xc3";
               "\xa9";
               "\xe2";
               "\xff";
             ])))

(* Reads back the escapes that [Json.string] writes. [None] for a raw quote
   before the last byte, and for an escaped last byte. *)
let unquote j =
  let b = Buffer.create (String.length j) in
  let rec loop i =
    if i < String.length j - 1 then (
      match j.[i] with
      | '\\' -> (
          match j.[i + 1] with
          | 'n' ->
              Buffer.add_char b '\n';
              loop (i + 2)
          | 'r' ->
              Buffer.add_char b '\r';
              loop (i + 2)
          | 't' ->
              Buffer.add_char b '\t';
              loop (i + 2)
          | 'u' ->
              let u = int_of_string ("0x" ^ String.sub j (i + 2) 4) in
              Buffer.add_utf_8_uchar b (Uchar.of_int u);
              loop (i + 6)
          | c ->
              Buffer.add_char b c;
              loop (i + 2))
      | '"' -> None
      | c ->
          Buffer.add_char b c;
          loop (i + 1))
    else if i = String.length j - 1 then Some (Buffer.contents b)
    else None
  in
  loop 1

let string_law s =
  let j = Json.string s in
  is_true ~msg:"quoted"
    (String.length j >= 2 && j.[0] = '"' && j.[String.length j - 1] = '"');
  is_true ~msg:"valid UTF-8" (String.is_valid_utf_8 j);
  is_false ~msg:"a raw control byte or DEL"
    (String.exists (fun c -> c < ' ' || c = '\x7f') j);
  let read = unquote j in
  is_true ~msg:"no raw quote inside" (Option.is_some read);
  if String.is_valid_utf_8 s then equal (option string) (Some s) read

let add_string_appends () =
  let b = Buffer.create 16 in
  Buffer.add_string b "x=";
  Json.add_string b "a\xffb";
  equal string "x=\"a\u{fffd}b\"" (Buffer.contents b)

let value v =
  let b = Buffer.create 64 in
  Json.add b v;
  Buffer.contents b

let value_rows =
  [
    ("an integer", Json.Int (-3), "-3");
    ("a float that reads back", Json.Float 0.1, "0.1");
    ( "a float that needs 17 digits",
      Json.Float (0.1 +. 0.2),
      "0.30000000000000004" );
    ("an infinite float", Json.Float Float.infinity, "null");
    ("a negative infinite float", Json.Float Float.neg_infinity, "null");
    ("NaN", Json.Float Float.nan, "null");
    ("a boolean", Json.Bool true, "true");
    ("a string", Json.String "a\xffb", "\"a\u{fffd}b\"");
    ("an empty list", Json.List [], "[]");
    ( "a list and an object",
      Json.List
        [ Json.Object [ ("k\n", Json.Int 1); ("v", Json.List [ Json.Int 2 ]) ] ],
      {|[{"k\n": 1, "v": [2]}]|} );
  ]

let () =
  exit
    (run "json"
       [
         cases
           "string escapes what JSON needs and replaces malformed UTF-8 with \
            U+FFFD"
           ~id:name3 string_rows (fun (_, s, quoted) ->
             equal string quoted (Json.string s));
         prop
           "string is quoted, valid UTF-8, has no raw control byte, DEL or \
            inner quote, and reads back as its input when the input is UTF-8"
           bytes string_law;
         test "unquote refuses a closing quote after a backslash" (fun () ->
             equal (option string) None (unquote {|"\"|}));
         test "add_string appends the literal of string" add_string_appends;
         cases "add writes a value on one line" ~id:name3 value_rows
           (fun (_, v, text) -> equal string text (value v));
       ])
