module Main where

import Prelude
import Control.Monad (ap)

data Option a = None | Some a
derive instance functorOption :: Functor Option
instance applicativeOption :: Applicative Option where
  pure = Some
instance applyOption :: Apply Option where
  apply (Some f) (Some a) = Some (f a)
  apply _ _ = None
instance bindOption :: Bind Option where
  bind (Some a) f = f a
  bind None _ = None
instance monadOption :: Monad Option
