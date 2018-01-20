-- @shouldFailWith MissingNewtypeSuperclassInstance
module Main where

import Prelude
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (logShow, log, CONSOLE)

newtype Const a b = Const a
instance functorConst :: Functor (Const a) where
  map _ (Const a) = Const a
instance applyConst :: Semigroup a => Apply (Const a) where
  apply (Const a) (Const b) = Const (a <> b)
instance eqConst :: Eq a => Eq (Const a b) where
  eq (Const a) (Const b) = a == b

newtype S a = S (Const String a)

derive newtype instance eqS :: Eq (S a)
derive newtype instance applyS :: Apply S

instance functorS :: Functor S where map _ _ = S (Const "unlawful")

oneMap :: forall f a b. Apply f => (a -> b) -> f a -> f b
oneMap = map

otherMap :: forall f a b. Functor f => (a -> b) -> f a -> f b
otherMap = map

main :: Eff ( console :: CONSOLE ) Unit
main = logShow $ let v = S (Const "lawful") in oneMap (_+0) v == otherMap (_+0) v
