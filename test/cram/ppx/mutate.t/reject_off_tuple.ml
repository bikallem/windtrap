let first x = match x with 0, (b [@mutate off "unused"]) -> b | a, _ -> a
