{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Signal.Compiler (compiler, compile) where

import Signal.Core hiding (lift)
import Signal.Core.Stream
import Signal.Core.Witness
import Signal.Core.Reify
import qualified Signal.Core as S

import Signal.Compiler.Interface
import Signal.Compiler.Cycles
import Signal.Compiler.Sorter
import Signal.Compiler.Linker
import Signal.Compiler.Linker.Channels

import Control.Arrow        (first, second)
import Control.Monad.Reader (ReaderT, asks, lift, mapReaderT)
import Control.Monad.Identity
import Control.Monad.Operational.Compositional
import qualified Control.Monad.Reader as CMR

import Data.Either      (partitionEithers)
import Data.Maybe       (catMaybes)
import Data.List        (sortBy, delete)
import Data.Traversable (traverse)
import Data.Typeable
import Data.Function    (on)
import Data.Hashable
import Data.Constraint
import Data.Ref
import Data.Ref.Map     (Name)
import qualified Data.Ref.Map as Rim

import Language.VHDL    (Identifier(..))
import Language.Embedded.VHDL           hiding (name, compile)
import qualified Language.Embedded.VHDL as E

import System.Mem.StableName (eqStableName)

import Prelude hiding (read, lookup, Left, Right)
import qualified Prelude as P

--------------------------------------------------------------------------------
-- * Compiler
--------------------------------------------------------------------------------

compiler
  :: ( ConcurrentCMD (IExp i) :<: i
     , SequentialCMD (IExp i) :<: i
     , HeaderCMD     (IExp i) :<: i
     , CompileExp    (IExp i)
     , Compile       (IExp i)
     , PredicateExp  (IExp i) a
     , PredicateExp  (IExp i) b
     , PredicateExp  (IExp i) Bool -- !!!
     , Typeable i                  -- !!!
     , Typeable a
     , Typeable b
     )
  => (Sig i a -> Sig i b) -> IO (Str i a -> Str i b)
compiler sf =
  do (root, input, nodes) <- freify sf     
     let order = sorter root  nodes
         cycle = cycles root  nodes
         links = linker order nodes
     return $ case cycle of
       True  -> error "Compiler.compiler: found cycle"
       False -> fcompile' root input links order

compile
  :: ( ConcurrentCMD (IExp i) :<: i
     , SequentialCMD (IExp i) :<: i
     , HeaderCMD     (IExp i) :<: i
     , CompileExp    (IExp i)
     , Compile       (IExp i)
     , PredicateExp  (IExp i) a
     , PredicateExp  (IExp i) Bool -- !!!
     , Typeable a
     )
  => Sig i a -> IO (Str i a)
compile s =
  do (root, nodes) <- reify s
     let order = sorter root  nodes
         cycle = cycles root  nodes
         links = linker order nodes
     return $ case cycle of
       True  -> error "Compiler.compile: found cycle"
       False -> compile' root links order

--------------------------------------------------------------------------------
-- ** Compilation of graphs

type Order i = [Ordered i]

-- | Signals are translated into constant streams
compile'
  :: forall i a.
     ( ConcurrentCMD (IExp i) :<: i
     , SequentialCMD (IExp i) :<: i
     , HeaderCMD     (IExp i) :<: i
     , CompileExp    (IExp i)
     , Compile       (IExp i)
     , PredicateExp  (IExp i) a
     , PredicateExp  (IExp i) Bool
     , Typeable a
     )
  => Key i (Identity a)
  -> Links i
  -> Order i
  -> Str i a
compile' outp@(Key root) links order = Stream $ inArchitecture "test" $
  do clk  <- clock
     signalPort (find outp) Out (Nothing :: Maybe (IExp i a))
     return . run $ do       
       inProcess "combinatorial" sensitive $ do
         lift $ initialize channels links orders
         mapM_ comp' nodes
         mapM_ comp' delays
       inProcess "sequential" [clk] $ do
         mapReaderT (E.when (rising clk)) $
           mapM_ compDelay' delays
       read outp (name root)
  where
    (delays, nodes) = filterDelays channels links order
    channels        = fromLinks outp links 
    orders          = (Ordered root) `delete` order
    sensitive       = fmap find' delays
      where find' (Ordered n) = case Rim.lookup n links of
              Just (Linked (Delay {}) (Link out)) -> fst (lookupNode out channels)

    -- Run 'M' to produce its program
    run :: M i x -> Program i x
    run = flip CMR.runReaderT (links, channels)

    find :: (PredicateExp (IExp i) x, Typeable x) => Key i (Identity x) -> Identifier
    find (Key k) = fst $ lookupNode (name k) channels

    -- ! really bad temp fix, replace
    rising :: Identifier -> IExp i Bool
    rising (Ident formal) = varE . Ident $ "rising_edge(" ++ formal ++ ")"

--------------------------------------------------------------------------------

-- | Signal transformers are translated into functions over streams
fcompile'
  :: forall i a b.
     ( ConcurrentCMD (IExp i) :<: i
     , SequentialCMD (IExp i) :<: i
     , HeaderCMD     (IExp i) :<: i
     , CompileExp    (IExp i)
     , Compile       (IExp i)
     , PredicateExp  (IExp i) a
     , PredicateExp  (IExp i) b
     , PredicateExp  (IExp i) Bool -- !!!
     , Typeable a
     , Typeable b
     )
  => Key i (Identity b)
  -> Key i (Identity a)
  -> Links i
  -> Order i
  -> (Str i a -> Str i b)
fcompile' outp@(Key root) inp@(Key var) links order (Stream str) = Stream $ inArchitecture "test" $
  do next <- str
     clk  <- clock
     signalPort (find inp)  In  (Nothing :: Maybe (IExp i a))
     signalPort (find outp) Out (Nothing :: Maybe (IExp i a))

     -- main loop
     return . run $ do
       val <- lift $ next
       
       -- combinatorial part
       inProcess "combinatorial" sensitive $ do
         lift $ initialize channels links orders
         mapM_ comp' nodes
         mapM_ comp' delays

       -- sequential part
       inProcess "sequential" [clk] $ do
         mapReaderT (E.when (rising clk)) $
           mapM_ compDelay' delays

       -- return output
       read outp (name root)
  where
    (delays, nodes) = filterDelays channels links order
    channels        = fromLinks outp links
    orders          = foldr delete order [Ordered root, Ordered var]
    sensitive       = find inp : fmap find' delays
      where find' (Ordered n) = case Rim.lookup n links of
              Just (Linked (Delay {}) (Link out)) -> fst (lookupNode out channels)

    -- Run 'M' to produce its program
    run :: M i x -> Program i x
    run = flip CMR.runReaderT (links, channels)

    find :: (PredicateExp (IExp i) x, Typeable x) => Key i (Identity x) -> Identifier
    find (Key k) = fst $ lookupNode (name k) channels

    -- ! really bad temp fix, replace
    rising :: Identifier -> IExp i Bool
    rising (Ident formal) = varE . Ident $ "rising_edge(" ++ formal ++ ")"

--------------------------------------------------------------------------------

-- | Run the 'M' action inside a process
inProcess :: (ConcurrentCMD (IExp i) :<: i) => String -> [Identifier] -> M i () -> M i ()
inProcess name is = mapReaderT (process name is)

-- | Run a program inside an architecture
inArchitecture :: (HeaderCMD (IExp i) :<: i) => String -> Program i (Program i x) -> Program i (Program i x)
inArchitecture name = fmap (architecture name)

-- | ...
filterDelays :: Channels -> Links i -> Order i -> (Order i, Order i)
filterDelays channels links order = partitionEithers $ flip fmap order $
  \o@(Ordered n) -> case Rim.lookup n links of
      Just (Linked (Delay _ _) _) -> P.Left  o
      Just _                      -> P.Right o

--------------------------------------------------------------------------------
-- ** Compilation of nodes

type M i = ReaderT (Rim.Map (Linked i), Channels) (Program i)

comp'
  :: forall i.
     ( SequentialCMD (IExp i) :<: i
     , CompileExp (IExp i)
     , Compile (IExp i)
     )
  => Ordered i -> M i ()
comp' (Ordered sym) =
  do (Linked n olink@(Link out)) <- asks $ (Rim.! sym) . fst
     case n of
       (Repeat c) ->
         do write olink out c
       (Map f ilink@(Link s)) ->
         do v <- read ilink s
            write olink out (f v)
       (Delay _ ilink@(Link s)) ->
         do e <- read ilink s
            writeDelay olink out e
       (Mux ilink@(Link s) links) ->
         do state <- CMR.ask
            let (cs, ls) = unzip links
                choices  = flip fmap ls $ \clink@(Link c) -> run state $
                  do e <- read clink c
                     write olink out e
            v <- read ilink s
            lift $ switch v (zip (fmap literal cs) choices) (Nothing)
       _ -> return ()
  where
    run = flip CMR.runReaderT

compDelay' :: forall i. (SequentialCMD (IExp i) :<: i, CompileExp (IExp i)) => Ordered i -> M i ()
compDelay' (Ordered sym) =
  do (Linked (Delay _ (_ :: Link i (Identity b))) olink@(Link out)) <- asks $ (Rim.! sym) . fst
     (i, o) <- asks (lookupDelay out . snd)
     lift $ i <== (varE o :: IExp i b)

--------------------------------------------------------------------------------
-- ** Reading / Writing to and from Channels in environment

-- | Read a channels value
read 
  :: forall proxy i a. (CompileExp (IExp i), Witness i a)
  => proxy i a
  -> Names (S Symbol i a)
  -> M i (E i a)
read _ n = go (witness :: Wit i a) n
  where
    go :: Wit i x -> Names (S Symbol i x) -> M i (E i x)
    go (WE)     (name) = asks $ varE . fst . lookupNode name . snd
    go (WP u v) (l, r) =
      do l' <- go u l
         r' <- go v r
         return (l', r')

-- | Write some value to a channel
write 
  :: forall proxy i a. (SequentialCMD (IExp i) :<: i, Witness i a)
  => proxy i a
  -> Names (S Symbol i a)
  -> E i a
  -> M i ()
write _ n e = go (witness :: Wit i a) n e
  where
    go :: Wit i x -> Names (S Symbol i x) -> E i x -> M i ()
    go (WP u v) (l, r) (a, b) = go u l a >> go v r b
    go (WE)     (name) (expr) =
      do (c, k) <- asks $ lookupNode name . snd
         lift $ case k of
           E.Signal -> c <== expr
           _        -> c ==: expr

-- | Write a some value to a delay's channel
writeDelay
  :: forall proxy i a. (SequentialCMD (IExp i) :<: i, PredicateExp (IExp i) a)
  => proxy i (Identity a)
  -> Names (S Symbol i (Identity a))
  -> E i (Identity a)
  -> M i ()
writeDelay _ name e =
  do d <- asks $ snd . lookupDelay name . snd
     lift $ d <== e

--------------------------------------------------------------------------------
-- ** Initialization

-- | Declare signal/variable instances for each node in 'order'
initialize
  :: forall i.
     ( SequentialCMD (IExp i) :<: i
     , ConcurrentCMD (IExp i) :<: i
     )
  => Channels
  -> Links i
  -> Order i
  -> Program i ()
initialize channels links order = forM_ order $ \(Ordered n) ->
  case Rim.lookup n links of
    Nothing -> error "Compiler.compile'_init: lookup failed"
    Just (Linked (Delay v _) (Link o)) -> initDelay o (Just v)
    Just (Linked (Repeat  v) (Link o)) -> init      o (Nothing)
    Just (Linked (Map   _ _) (Link o :: Link i x)) ->
        dist (witness :: Wit i x) o
      where
        dist :: Wit i a -> Names (S Symbol i a) -> Program i ()
        dist (WP u v) (l, r) = dist u l >> dist v r
        dist (WE)     (name) = init name Nothing
    _ -> return ()
  where
    init :: forall a. PredicateExp (IExp i) a => Ix i a -> Maybe (IExp i a) -> Program i ()
    init n v =
      do let (i, k) = lookupNode n channels
         E.variableL i v

    initDelay :: forall a. PredicateExp (IExp i) a => Ix i a -> Maybe (IExp i a) -> Program i ()
    initDelay n v =
      do let (i, o) = lookupDelay n channels
         E.signalG i v
         E.signalG o (Nothing :: Maybe (IExp i a))

--------------------------------------------------------------------------------
