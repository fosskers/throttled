-- |
-- Module    : Control.Concurrent.Throttled
-- Copyright : (c) Colin Woodbury, 2012 - 2018
-- License   : BSD3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Handle concurrent fetches from a `Foldable`, throttled by the number
-- of CPUs that the user has available.
--
-- The canonical function is `throttled`. Notice the type of function
-- it expects as an argument:
--
-- @(TQueue a -> a -> IO b)@
--
-- This `TQueue` is an input queue derived from the given `Foldable`. This is
-- exposed so that any concurrent action can dynamically grow the input.
--
-- The output is a `TQueue` of the result of each `IO` action.
-- This be can fed to further concurrent operations, or drained into a list via:
--
-- @
-- import Control.Concurrent.STM (atomically)
-- import Control.Concurrent.STM.TQueue (TQueue, flushTQueue)
--
-- flush :: TQueue a -> IO [a]
-- flush = atomically . flushTQueue
-- @

module Control.Concurrent.Throttled
  ( throttled
  , throttled_
  ) where

import Control.Concurrent (getNumCapabilities, threadDelay)
import Control.Concurrent.Async (replicateConcurrently_)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TVar
import Control.Monad (void)
import Data.Foldable (traverse_)
import Data.Functor (($>))

---

data Pool a b = Pool { threads :: !Word
                     , waiters :: !(TVar Word)
                     , source  :: !(TQueue a)
                     , target  :: !(TQueue b) }

newPool :: Foldable f => f a -> IO (Pool a b)
newPool xs = Pool
  <$> (fromIntegral <$> getNumCapabilities)
  <*> newTVarIO 0
  <*> atomically (newTQueue >>= \q -> traverse_ (writeTQueue q) xs $> q)
  <*> atomically newTQueue

data Status = Waiting | Working

-- | Concurrently traverse over some `Foldable` using 1 thread per
-- CPU that the user has. The user's function is also passed the
-- source `TQueue`, in case they wish to dynamically add work to it.
--
-- The order of elements in the original `Foldable` is not maintained.
throttled :: Foldable f => (TQueue a -> a -> IO b) -> f a -> IO (TQueue b)
throttled = throttledGen (\q b -> atomically $ writeTQueue q b)

-- | Like `throttled`, but doesn't store any output.
throttled_ :: Foldable f => (TQueue a -> a -> IO ()) -> f a -> IO ()
throttled_ f xs = void $ throttledGen (\_ _ -> pure ()) f xs

-- | The generic case. The caller can choose what to do with the value produced by the work.
throttledGen :: Foldable f => (TQueue b -> b -> IO ()) -> (TQueue a -> a -> IO b) -> f a -> IO (TQueue b)
throttledGen g f xs = do
  p <- newPool xs
  replicateConcurrently_ (fromIntegral $ threads p) (work p Working)
  pure $ target p
  where work p s = do
          mx <- atomically . tryReadTQueue $ source p
          ws <- atomically . readTVar $ waiters p
          case (mx, s) of
            (Nothing, Waiting) | ws == threads p -> pure ()  -- All our threads have completed.
                               | otherwise -> threadDelay 100000 *> work p Waiting
            (Nothing, Working) -> do
              atomically $ modifyTVar' (waiters p) succ
              threadDelay 100000
              work p Waiting
            (Just x, Waiting) -> do
              atomically $ modifyTVar' (waiters p) pred
              f (source p) x >>= g (target p) >> work p Working
            (Just x, Working) -> f (source p) x >>= g (target p) >> work p Working
