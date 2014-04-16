-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.Traversals
-- Copyright   :  (c) 2014 Phil Freeman
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- | Common functions for implementing generic traversals
--
-----------------------------------------------------------------------------

module Language.PureScript.Traversals where

import Control.Applicative

fstM :: (Functor f) => (a -> f c) -> (a, b) -> f (c, b)
fstM f (a, b) = flip (,) b <$> f a

sndM :: (Functor f) => (b -> f c) -> (a, b) -> f (a, c)
sndM f (a, b) = (,) a <$> f b

maybeM :: (Applicative f) => (a -> f b) -> Maybe a -> f (Maybe b)
maybeM _ Nothing = pure Nothing
maybeM f (Just a) = Just <$> f a
