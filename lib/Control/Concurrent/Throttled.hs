{-# LANGUAGE MultiWayIf, LambdaCase #-}

-- |
-- Module    : Control.Concurrent.Throttled
-- Copyright : (c) Colin Woodbury, 2012 - 2018
-- License   : BSD3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Handle concurrent fetches from a `Foldable`, throttled by the number
-- of CPUs that the user has available.
--
-- The canonical function is `throttle`. Notice the type of function
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
  ( throttle, throttle_
  , throttleMaybe, throttleMaybe_
  ) where

import Control.Concurrent (getNumCapabilities, threadDelay)
import Control.Concurrent.Async (replicateConcurrently_)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TVar
import Control.Monad (void)
import Data.Bifunctor (bimap)
import Data.Foldable (traverse_)
import Data.Functor (($>))

---

data Pool a b = Pool { threads :: !Word
                     , waiters :: !(TVar Word)
                     , job     :: !(TVar JobStatus)
                     , source  :: !(TQueue a)
                     , target  :: !(TQueue b) }

newPool :: Foldable f => f a -> IO (Pool a b)
newPool xs = Pool
  <$> (fromIntegral <$> getNumCapabilities)
  <*> newTVarIO 0
  <*> newTVarIO Fantastic
  <*> atomically (newTQueue >>= \q -> traverse_ (writeTQueue q) xs $> q)
  <*> atomically newTQueue

data ThreadStatus = Waiting | Working

data JobStatus = Failed | Fantastic

-- | Concurrently traverse over some `Foldable` using 1 thread per
-- CPU that the user has. The user's function is also passed the
-- source `TQueue`, in case they wish to dynamically add work to it.
--
-- The order of elements of the original `Foldable` is not maintained.
throttle :: Foldable f => (TQueue a -> a -> IO b) -> f a -> IO (TQueue b)
throttle f xs = either id id <$> throttleGen (\q b -> atomically $ writeTQueue q b) (\q a -> Just <$> f q a) xs

-- | Like `throttle`, but doesn't store any output.
-- This is more efficient than @void . throttle@.
throttle_ :: Foldable f => (TQueue a -> a -> IO b) -> f a -> IO ()
throttle_ f = void . throttleGen (\_ _ -> mempty) (\q a -> Just <$> f q a)

-- | Like `throttle`, but stop all threads safely if one finds a `Nothing`.
-- The final `TQueue` contains as much completed work as the threads could
-- manage before they completed / died. Matching on the `Either` will tell
-- you which scenario occurred.
throttleMaybe :: Foldable f => (TQueue a -> a -> IO (Maybe b)) -> f a -> IO (Either (TQueue b) (TQueue b))
throttleMaybe = throttleGen (\q b -> atomically $ writeTQueue q b)

-- | Like `throttleMaybe`, but doesn't store any output.
-- Pattern matching on the `Either` will still let you know if a failure occurred.
throttleMaybe_ :: Foldable f => (TQueue a -> a -> IO (Maybe b)) -> f a -> IO (Either () ())
throttleMaybe_ f xs = bimap (const ()) (const ()) <$> throttleGen (\_ _ -> mempty) f xs

-- | The generic case. The caller can choose what to do with the value produced by the work.
throttleGen :: Foldable f => (TQueue b -> b -> IO ()) -> (TQueue a -> a -> IO (Maybe b)) -> f a -> IO (Either (TQueue b) (TQueue b))
throttleGen g f xs = do
  p <- newPool xs
  replicateConcurrently_ (fromIntegral $ threads p) (check p Working)
  ($ target p) . jobStatus <$> readTVarIO (job p)
  where check p s = readTVarIO (job p) >>= \case
          Failed    -> pure ()  -- Another thread failed.
          Fantastic -> atomically (tryReadTQueue $ source p) >>= work p s

        work p Waiting Nothing = do
          ws <- readTVarIO $ waiters p
          if | ws == threads p -> pure ()  -- All our threads have completed.
             | otherwise       -> threadDelay 100000 *> check p Waiting

        work p Working Nothing = do
          atomically $ modifyTVar' (waiters p) succ
          threadDelay 100000
          check p Waiting

        work p Waiting j@(Just _) = do
          atomically $ modifyTVar' (waiters p) pred
          work p Working j

        work p Working (Just x) = f (source p) x >>= \case
          Nothing  -> atomically $ writeTVar (job p) Failed
          Just res -> g (target p) res >> check p Working

jobStatus :: JobStatus -> (a -> Either a a)
jobStatus Failed    = Left
jobStatus Fantastic = Right
