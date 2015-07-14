{-# LANGUAGE ViewPatterns #-}

import Control.Arrow

data Nat = Z | S Nat deriving Show

plus m Z = m
plus m (S (plus m -> sum)) = S sum


fib :: Nat -> Nat
fib zero@Z = zero
fib one@(S Z) = one
fib (S (fib&&&id -> (f, S (fib -> g)))) = f `plus` g
