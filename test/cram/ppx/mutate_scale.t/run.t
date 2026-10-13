The mutation rewriter compares the two branches of each if for the filter
"same branches". In an else-if chain, as a generated lexer has, the else
branch holds the remaining chain. The comparison stops at the size of the
smaller branch, so the time of the rewriter increases with the length of
the chain, not with its square. The limit on processor time stops a
rewriter that reads the full chain at each if:

  $ awk 'BEGIN { print "let f x ="; for (i = 0; i < 20000; i++) printf "  if x = %d then %d else\n", i, i; print "  -1" }' > chain.ml
  $ ulimit -t 30
  $ ../pp.exe -apply windtrap_mutate --impl ./chain.ml | ../elide.exe | head -3
  mutation sites of "./chain.ml" in Windtrap_mut_________chain___ml:
    0: 20001:5 "neq" "x = 19999" -> "x <> 19999"
    1: 20000:5 "neq" "x = 19998" -> "x <> 19998"

Two large branches of different sizes stop the counts later. The limit
of the counts doubles each time, so the comparison costs the size of the
smaller branch. A limit that increases by a fixed step makes the time
increase with the square of that size, and the limit on processor time
stops it:

  $ awk 'BEGIN { n = 300000; printf "let f c =\n  if c then [|"; for (i = 0; i < n; i++) printf "%d;", i; printf "|]\n  else [|"; for (i = 0; i <= n; i++) printf "%d;", i; print "|]" }' > arrays.ml
  $ ulimit -t 10
  $ ../pp.exe -apply windtrap_mutate --impl ./arrays.ml | ../elide.exe | head -2
  mutation sites of "./arrays.ml" in Windtrap_mut_________arrays___ml:
    0: 2:5 "not" "c" -> "not c"
