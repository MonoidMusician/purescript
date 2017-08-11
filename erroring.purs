module Main where

data Typ = Typ

class Cls t where
  dflt :: t
  todflt :: forall a. a -> t

instance typCls :: Cls Typ where
  dflt = Typ
  todflt = const dflt

dfltCopy :: forall t. Cls t => t
dfltCopy = dflt
todfltCopy = todflt

const x y = x

todfltDefault :: forall a t. Cls t => a -> t
todfltDefault a = dflt
