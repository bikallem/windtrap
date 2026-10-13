let x_or_y p = match p with ~x:0, ~y:(1 [@mutate off "one"]) -> 1 | ~x, ~y:_ -> x
