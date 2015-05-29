{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE TypeOperators       #-}

module Backend.Compiler.Compiler (
    compiler
  )
where

import Core

import Frontend.Stream (Stream(..), Str)
import Frontend.Signal (Signal(..), Sig)
import Frontend.Signal.Observ

import Backend.Ex
import Backend.Nested
import Backend.Compiler.Cycles
import Backend.Compiler.Linker
import Backend.Compiler.Sorter

import qualified Core            as C
import qualified Frontend.Stream as Str
import qualified Frontend.Signal as S

import Control.Monad.Reader
import Control.Monad.State hiding (State)
import Data.Reify
import Data.Maybe       (fromJust)
import Data.List        (sortBy, mapAccumR)
import Data.Traversable (traverse)
import Data.Function    (on)
import Data.Map         (Map, (!))
import Data.Constraint

import qualified Data.Map        as M

import Prelude hiding (reads)

--------------------------------------------------------------------------------
-- *
--------------------------------------------------------------------------------

compiler :: ( RefCMD  (IExp instr) :<: instr
            , VarPred (IExp instr) a
            , MapInstr instr
            , Typeable instr, Typeable a, Typeable b
            )
         =>    (Sig instr a -> Sig instr b)
         -> IO (Str instr a -> Str instr b)
compiler f = 
  do (Graph nodes root) <- reifyGraph f

     let links = linker nodes
         order = sorter root nodes
         cycle = cycles root nodes

     return $ case cycle of
       True  -> error "found cycle in graph"
       False -> compiler' nodes links order

--------------------------------------------------------------------------------
-- * Channels
--------------------------------------------------------------------------------

type Prog instr = Program instr

-- | Untyped binary trees over references
type REx instr = Ex (Ruple instr)

-- | ...
data Channel symbol instr = C {
    _ch_in  :: Map symbol (REx instr)
  , _ch_out :: Map symbol (REx instr)
  }

--------------------------------------------------------------------------------
-- hacky solution for now

-- |
initChannels :: (Ord s, Read s, Typeable instr, RefCMD (IExp instr) :<: instr)
             => Resolution s instr
             -> Prog instr (Channel s instr)
initChannels res = do
  outs <- M.traverseWithKey (const makeChannel) $ _output res
  return $ C {
    _ch_in  = M.map (copyChannel outs) $ _input res
  , _ch_out = outs
  }

-- |
makeChannel :: forall instr. (RefCMD (IExp instr) :<: instr) 
            => TEx instr
            -> Prog instr (REx instr)
makeChannel (Ex s) = makes s >>= return . Ex
  where
    makes :: Suple instr a -> Prog instr (Ruple instr a)
    makes (Seaf   _)   = C.newRef >>= return . Reaf
    makes (Sranch r l) = do
      r' <- makes r
      l' <- makes l
      return $ Rranch r' l'

-- |
copyChannel :: forall instr s. (Ord s, Read s, Typeable instr)
            => Map s (REx instr)
            -> TEx instr
            -> REx instr
copyChannel m (Ex s) = Ex $ copys s
  where
    copys :: Suple instr a -> Ruple instr a
    copys (Sranch l r) = Rranch (copys l) (copys r)
    copys (Seaf   i)   = case m ! read i of
      (Ex (Reaf r)) -> case gcast r of
        (Just x) -> Reaf x

--------------------------------------------------------------------------------
-- * Compiler
--------------------------------------------------------------------------------

-- | ...
data Enviroment symbol instr = Env
  { _links    :: Resolution symbol instr
  , _channels :: Channel    symbol instr 
  , _inputs   :: Ex (Prog instr :*: IExp instr)
  , _firsts   :: Map symbol (Ex C.Ref) -- todo: merge with _channels
  }

-- | 
type Type instr = ReaderT (Enviroment Unique instr) (Prog instr)

--------------------------------------------------------------------------------

reads :: (RefCMD (IExp instr) :<: instr)
      => Ruple instr a
      -> Prog  instr (Tuple instr a)
reads (Reaf   r)   = C.getRef r >>= return . Leaf
reads (Rranch l r) = do
  l' <- reads l
  r' <- reads r
  return $ Branch l' r'

writes :: (RefCMD (IExp instr) :<: instr)
       => Tuple instr a
       -> Ruple instr a
       -> Prog  instr ()
writes (Leaf   s)   (Reaf   r)   = C.setRef r s
writes (Branch l r) (Rranch u v) = writes l u >> writes r v

--------------------------------------------------------------------------------

-- | Read
read_in :: (RefCMD (IExp instr) :<: instr, Typeable a)
        => Unique
        -> Suple instr a
        -> Type  instr (Tuple instr a)
read_in u _ =
  do (Ex ch) <- asks ((! u) . _ch_in . _channels)
     case gcast ch of
       Just s  -> lift $ reads s
       Nothing -> error "hepa: type error"

-- | Read 
read_out :: (RefCMD (IExp instr) :<: instr, Typeable a)
         => Unique
         -> Suple instr a
         -> Type  instr (Tuple instr a)
read_out u _ =
  do (Ex ch) <- asks ((! u) . _ch_out . _channels)
     case gcast ch of
       Just s  -> lift $ reads s
       Nothing -> error "bepa: type error"

-- | Write
write_out :: (RefCMD (IExp instr) :<: instr, Typeable a)
          => Unique
          -> Tuple instr a
          -> Type  instr ()
write_out u s =
  do (Ex ch) <- asks ((! u) . _ch_out . _channels)
     case gcast ch of
       Just r  -> lift $ writes s r
       Nothing -> error "depa: type error"

--------------------------------------------------------------------------------

-- | ...
compile :: (RefCMD (IExp instr) :<: instr, MapInstr instr, Typeable instr)
        => (Unique, Node instr)
        -> Type instr ()
compile (i, TVar t@(Seaf _)) =
  do input <- asks (apa t . _inputs)
     value <- lift $ liftProgram input
     write_out i (Leaf value)
  where
    apa :: Typeable a => Suple instr (Empty instr a) -> Ex (f :*: g) -> f (g a)
    apa _ = unwrap

compile (i, TConst c) =
  do value <- lift $ liftProgram $ Str.run c
     write_out i (Leaf value)

compile (i, TLift (f :: Stream instr (IExp instr a) -> Stream instr (IExp instr b)) _) =
  do let t = undefined :: Suple instr (Empty instr a)
     (Leaf input) <- read_in i t
     value <- lift $ liftProgram $ Str.run $ f $ Str.repeat input
     write_out i (Leaf value)

-- I could remove the extra variable (value) if updating all delay
-- values was the last thing I did in the compiler, like for buffers.
compile (i, TDelay (e :: IExp instr a) _) =
  do let t = undefined :: Suple instr (Empty instr a)
     (Leaf input) <- read_in i t
     (Ex   first) <- asks ((! i) . _firsts)
     let f = case gcast first of
               Just x  -> x
               Nothing -> error "!"
     value <- lift $ liftProgram $
                do output <- C.getRef f
                   C.setRef f input
                   return output
     write_out i (Leaf value)

compile (i, TMap ti to f _) =
  do input <- read_in i ti
     value <- return $ f input
     write_out i value

compile _ = return ()

--------------------------------------------------------------------------------

-- | ...
compiler' :: forall instr a b.
             ( Typeable instr, Typeable a, Typeable b
             , RefCMD (IExp instr) :<: instr
             , MapInstr instr
             )
          => [(Unique, Node instr)]
          -> Resolution Unique instr
          -> Map Unique Order
          -> (Stream instr (IExp instr a) -> Stream instr (IExp instr b))
compiler' nodes links order input = Stream $
  do env <- init (Str.run input)
     return $
       do let sorted = sort nodes
          let last   = final sorted
          (Leaf value) <- flip runReaderT env $ do
            let t = undefined :: Suple instr (Empty instr b)
            mapM_ compile sorted
            read_out last t
          return value

  where
    -- Create initial eviroment
    init :: Prog instr (IExp instr a) -> Prog instr (Enviroment Unique instr)
    init i =
      do let delays = M.fromList [ x | x@(_, TDelay {}) <- nodes] :: Map Unique (Node instr)
             fnodes = map fst $ filterNOP nodes
             flinks = Resolution {
                 _output = M.filterWithKey (\k _ -> k `elem` fnodes) $ _output links
               , _input  = M.filterWithKey (\k _ -> k `elem` fnodes) $ _input  links
               }
         firsts   <- M.traverseWithKey (const $ init_delay) delays
         channels <- initChannels flinks
         return $ Env {
             _links    = links
           , _channels = channels
           , _firsts   = firsts
           , _inputs   = wrap i
           }
      where
        init_delay :: Node instr -> Prog instr (Ex C.Ref)
        init_delay (TDelay d _) = C.initRef d >>= return . Ex
        
    -- Sort graph nodes by the given ordering
    sort :: [(Unique, Node instr)] -> [(Unique, Node instr)]
    sort = fmap (fmap snd) . sortBy (compare `on` (fst . snd))
         . M.toList . M.intersectionWith (,) order
         . M.fromList

    -- Find final reference to read output from
    final :: [(Unique, Node instr)] -> Unique
    final = fst . last . filterNOP

    -- Filter unused nodes
    filterNOP :: [(Unique, Node instr)] -> [(Unique, Node instr)]
    filterNOP = filter (not . nop . snd)
      where nop (TLambda {}) = True
            nop (TJoin   {}) = True
            nop (TLeft   {}) = True
            nop (TRight  {}) = True
            nop _            = False

--------------------------------------------------------------------------------
