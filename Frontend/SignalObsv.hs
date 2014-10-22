{-# LANGUAGE GADTs               #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Frontend.SignalObsv where

import Expr

import           Frontend.Signal (Signal(..), Sig(..))
import qualified Frontend.Signal as Sig

import           Frontend.Stream (Stream)
import qualified Frontend.Stream as Str

import Control.Applicative hiding (Const)
import Data.Dynamic
import Data.Proxy
import Data.Typeable
import Data.Reify

--------------------------------------------------------------------------------
-- *
--------------------------------------------------------------------------------

data TSignal r
  where
    -- ^ Sig. func.
    TLambda :: (Typeable x) => Proxy x -> r -> r -> TSignal r
    TVar    :: TSignal r

    -- ^ Sig.
    TConst  :: Typeable a
              => Stream a
              -> TSignal r

    TLift   :: (Typeable a, Typeable b)
              => (Stream a -> Stream b)
              -> r
              -> TSignal r

    TMap    :: (Typeable a, Typeable b, Classy a)
              => (Struct a -> Struct b)
              -> r
              -> TSignal r

    TZip    :: r -> r -> TSignal r
    TFst    :: r      -> TSignal r
    TSnd    :: r      -> TSignal r

    TDelay  :: a -> r -> TSignal r

    -- ^ Buffers
    TVBuff  ::               r -> TSignal r
    TDBuff  :: Num n => n -> r -> TSignal r
  deriving Typeable

--------------------------------------------------------------------------------
-- **

instance MuRef (Signal a)
  where
    type DeRef (Signal a) = TSignal

    mapDeRef f node = case node of
      (Const sf)   -> pure $ TConst sf
      (Lift  sf s) -> TLift sf <$> f s
      (Map   sf s) -> TMap sf <$> f s
      (Zip   s u)  -> TZip <$> f s <*> f u
      (Fst   s)    -> TFst <$> f s
      (Snd   s)    -> TSnd <$> f s
      (Delay a s)  -> TDelay a <$> f s
      (SVar  _)    -> pure $ TVar

instance (Typeable a, Typeable b) => MuRef (Signal a -> Signal b)
  where
    type DeRef (Signal a -> Signal b) = TSignal

    mapDeRef f sf =
      let (v, sg) = let a = SVar (toDyn sf) in (a, sf a)
       in TLambda (Proxy :: Proxy b)
            <$> f v
            <*> f sg

instance (Typeable a, Typeable b) => MuRef (Sig a -> Sig b)
  where
    type DeRef (Sig a -> Sig b) = TSignal

    mapDeRef f sf = mapDeRef f (unSig . sf . Sig)

--------------------------------------------------------------------------------
-- ** Testing

instance Show (TSignal Unique) where
  show node = case node of
    (TLambda _ i b) -> "lam. " ++ show i ++ " " ++ show b
    (TVar)          -> "var. "

    (TConst _)   -> "const. "
    (TLift  _ s) -> "lift. " ++ show s

    (TMap _ s)   -> "map. " ++ show s
    (TZip s u)   -> "zip. " ++ show s ++ " " ++ show u
    (TFst s)     -> "fst. " ++ show s
    (TSnd s)     -> "snd. " ++ show s

    (TDelay _ s) -> "delay. " ++ show s
