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
