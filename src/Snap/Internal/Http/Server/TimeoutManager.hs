{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snap.Internal.Http.Server.TimeoutManager
  ( TimeoutManager
  , TimeoutThread
  , initialize
  , stop
  , register
  , tickle
  , set
  , modify
  , cancel
  ) where

------------------------------------------------------------------------------
import           Control.Exception                (evaluate, finally)
import qualified Control.Exception                as E
import           Control.Monad                    (Monad ((>>=), return), mapM_, void, when)
import qualified Data.ByteString.Char8            as S
import           Data.IORef                       (IORef, newIORef, readIORef, writeIORef)
import           Prelude                          (Bool, Double, IO, Int, Show (..), const, fromIntegral, max,  null, otherwise, round, ($), ($!), (+), (++), (-), (.), (<=), (==))
------------------------------------------------------------------------------
import           Control.Concurrent               (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
------------------------------------------------------------------------------
import           Snap.Internal.Http.Server.Clock  (ClockTime)
import qualified Snap.Internal.Http.Server.Clock  as Clock
import           Snap.Internal.Http.Server.Common (atomicModifyIORef', eatException)
import qualified Snap.Internal.Http.Server.Thread as T


------------------------------------------------------------------------------
type State = ClockTime

canceled :: State
canceled = 0

isCanceled :: State -> Bool
isCanceled = (== 0)


------------------------------------------------------------------------------
data TimeoutThread = TimeoutThread {
      _thread     :: !T.SnapThread
    , _state      :: !(IORef State)
    , _hGetTime   :: !(IO ClockTime)
    }

instance Show TimeoutThread where
    show = show . _thread


------------------------------------------------------------------------------
-- | Given a 'State' value and the current time, apply the given modification
-- function to the amount of time remaining.
--
smap :: ClockTime -> (ClockTime -> ClockTime) -> State -> State
smap now f deadline | isCanceled deadline = deadline
                    | otherwise = t'
  where
    remaining    = max 0 (deadline - now)
    newremaining = f remaining
    t'           = now + newremaining


------------------------------------------------------------------------------
data TimeoutManager = TimeoutManager {
      _defaultTimeout :: !ClockTime
    , _pollInterval   :: !ClockTime
    , _getTime        :: !(IO ClockTime)
    , _threads        :: !(IORef [TimeoutThread])
    , _morePlease     :: !(MVar ())
    , _managerThread  :: !(MVar T.SnapThread)
    }


------------------------------------------------------------------------------
-- | Create a new TimeoutManager.
initialize :: Double            -- ^ default timeout
           -> Double            -- ^ poll interval
           -> IO ClockTime      -- ^ function to get current time
           -> IO TimeoutManager
initialize defaultTimeout interval getTime = E.uninterruptibleMask_ $ do
    conns <- newIORef []
    mp    <- newEmptyMVar
    mthr  <- newEmptyMVar

    let tm = TimeoutManager (Clock.fromSecs defaultTimeout)
                            (Clock.fromSecs interval)
                            getTime
                            conns
                            mp
                            mthr

    thr <- T.fork "snap-server: timeout manager" $ managerThread tm
    putMVar mthr thr
    return tm


------------------------------------------------------------------------------
-- | Stop a TimeoutManager.
stop :: TimeoutManager -> IO ()
stop tm = readMVar (_managerThread tm) >>= T.cancelAndWait


------------------------------------------------------------------------------
wakeup :: TimeoutManager -> IO ()
wakeup tm = void $ tryPutMVar (_morePlease tm) $! ()


------------------------------------------------------------------------------
-- | Register a new thread with the TimeoutManager.
register :: TimeoutManager                        -- ^ manager to register
                                                  --   with
         -> S.ByteString                          -- ^ thread label
         -> ((forall a . IO a -> IO a) -> IO ())  -- ^ thread action to run
         -> IO TimeoutThread
register tm label action = do
    now <- getTime
    let !state = now + defaultTimeout
    stateRef <- newIORef state
    th <- E.uninterruptibleMask_ $ do
        t <- T.fork label action
        let h = TimeoutThread t stateRef getTime
        atomicModifyIORef' threads (\x -> (h:x, ())) >>= evaluate
        return $! h
    wakeup tm
    return th

  where
    getTime        = _getTime tm
    threads        = _threads tm
    defaultTimeout = _defaultTimeout tm


------------------------------------------------------------------------------
-- | Tickle the timeout on a connection to be at least N seconds into the
-- future. If the existing timeout is set for M seconds from now, where M > N,
-- then the timeout is unaffected.
tickle :: TimeoutThread -> Int -> IO ()
tickle th = modify th . max
{-# INLINE tickle #-}


------------------------------------------------------------------------------
-- | Set the timeout on a connection to be N seconds into the future.
set :: TimeoutThread -> Int -> IO ()
set th = modify th . const
{-# INLINE set #-}


------------------------------------------------------------------------------
-- | Modify the timeout with the given function.
modify :: TimeoutThread -> (Int -> Int) -> IO ()
modify th f = do
    now   <- getTime
    state <- readIORef stateRef
    let !state' = smap now f' state
    writeIORef stateRef state'

  where
    f' !x    = Clock.fromSecs $! fromIntegral $ f $ round $ Clock.toSecs x
    getTime  = _hGetTime th
    stateRef = _state th
{-# INLINE modify #-}


------------------------------------------------------------------------------
-- | Cancel a timeout.
cancel :: TimeoutThread -> IO ()
cancel h = E.uninterruptibleMask_ $ do
    T.cancel (_thread h)
      `E.finally` writeIORef (_state h) canceled
{-# INLINE cancel #-}


------------------------------------------------------------------------------
managerThread :: TimeoutManager -> (forall a. IO a -> IO a) -> IO ()
managerThread tm restore = restore loop `finally` cleanup
  where
    cleanup = E.uninterruptibleMask_ $
              eatException (readIORef threads >>= destroyAll)

    --------------------------------------------------------------------------
    getTime      = _getTime tm
    morePlease   = _morePlease tm
    pollInterval = _pollInterval tm
    threads      = _threads tm

    --------------------------------------------------------------------------
    loop = do
        now <- getTime
        E.uninterruptibleMask $ \restore' -> do
            handles <- atomicModifyIORef' threads (\x -> ([], x))
            if null handles
              then do restore' $ takeMVar morePlease
              else do
                handles' <- processHandles now handles
                atomicModifyIORef' threads (\x -> (handles' ++ x, ()))
                    >>= evaluate
        Clock.sleepFor pollInterval
        loop

    --------------------------------------------------------------------------
    processHandles now handles = go handles []
      where
        go [] !kept = return $! kept

        go (x:xs) !kept = do
            !state <- readIORef $ _state x
            !kept' <-
                if isCanceled state
                  then do b <- T.isFinished (_thread x)
                          return $! if b
                                      then kept
                                      else (x:kept)
                  else do when (state <= now) $ do
                            T.cancel (_thread x)
                            writeIORef (_state x) canceled
                          return (x:kept)
            go xs kept'

    --------------------------------------------------------------------------
    destroyAll xs = do
        mapM_ (T.cancel . _thread) xs
        mapM_ (T.wait . _thread) xs
