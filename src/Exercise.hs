{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Exercise
    ( remoteTable
    , master
    -- * Internal functions
    -- | These functions are exposed for testing purposes.
    , result
    , selectLeader
    ) where

import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import Data.Binary (Binary)

import Data.List (sort)
import Control.Monad (forM, when)
import Text.Printf (printf)
import System.Random (random, mkStdGen, RandomGen, randoms, StdGen)

import Control.Distributed.Process (
    ProcessId, SendPort, ReceivePort, Process, RemoteTable, NodeId
    , say, send, newChan, receiveChan, sendChan, mergePortsBiased, expect, getSelfPid, spawn, monitor, liftIO, spawnLocal)
import Control.Concurrent (threadDelay, newEmptyMVar, putMVar, forkIO)
import Control.Distributed.Process.Closure (mkClosure, remotable)
import Control.Distributed.Process.Backend.SimpleLocalnet (Backend, terminateAllSlaves)

type AckChan = SendPort (ProcessId, [Double])

data Msg = AckMsg {
        content :: Content
        , ackChan :: AckChan
    }
    deriving (Typeable, Generic)

data Content = Init {
        ps :: [ProcessId]
    }
    | Number {
        num :: Double
    }
    | DoneFromMaster
    | DoneFromLeader
    deriving (Show, Typeable, Generic)

instance Binary Content
instance Binary Msg

data ShutdownState = Shutdown {
    masterChan :: Maybe AckChan
    , leaderChan :: Maybe AckChan
}

setMasterChan :: ShutdownState -> AckChan -> ShutdownState
setMasterChan (Shutdown _ l) m = Shutdown (Just m) l

setLeaderChan :: ShutdownState -> AckChan -> ShutdownState
setLeaderChan (Shutdown m _) l = Shutdown m (Just l)

-- | toIndex converts the randomly generated number double [0,1) to an index in the list.
toIndex :: [a] -> Double -> Int
toIndex ps d = truncate $ d * fromIntegral (length ps)

-- | isLeader checks whether the random number is accosiated with the given item in the list.
isLeader :: Double -> [ProcessId] -> Process Bool
isLeader n ps = do
    self <- getSelfPid
    let l = self == ps !! toIndex ps n
    say $ printf "leader = %s" (show l)
    return l

-- | selectLeader returns the leader by removing it from the list and returning both the leader and the rest of the list.
selectLeader :: (Eq a) => Double -> [a] -> (a, [a])
selectLeader r ps = 
    let index = toIndex ps r
        (h, t) = splitAt index ps
    in (head t, h ++ tail t)

sendToAll :: Content -> [ProcessId] -> Process [ReceivePort (ProcessId, [Double])]
sendToAll msg ps = forM ps $ \pid -> do
    (sendport,recvport) <- newChan
    send pid (AckMsg msg sendport)
    return recvport

-- | waitForAll waits to receive an ack from each process, but stops immediately if the process it receives an ack from is itself.
-- This allows us to short circuit the wait loop, by sending a message from ourselves.
waitForAll :: ReceivePort (ProcessId, [Double]) -> [ProcessId] -> Process [[Double]] 
waitForAll _ [] = do
    say "all acks received"
    return []
waitForAll port ps = do
    (pid, rs) <- receiveChan port
    self <- getSelfPid
    if pid == self
        then do
            say "short circuited acks"
            return []
        else do rss <- waitForAll port (filter (/= pid) ps)
                return (rs:rss)

-- | sendAndWait sends content to all processes (excluding self) and waits for acks
sendAndWait :: Content -> [ProcessId] -> Process [[Double]]
sendAndWait _ [] = return []
sendAndWait msg ps = do
    self <- getSelfPid
    let others = filter (/= self) ps
    say $ printf "sending message: %s -> %s" (show msg) (show others)
    ports <- sendToAll msg others
    oneport <- mergePortsBiased ports
    waitForAll oneport others

data RandomProcess g = RandomProcess [ProcessId] ProcessId g

newRandomProcess :: [ProcessId] -> Int -> Process (RandomProcess StdGen)
newRandomProcess ps seed = do
    self <- getSelfPid
    return $ RandomProcess ps self (mkStdGen seed)

-- | rand randomly generates a random number that won't reselect the current node as the leader.
rand :: (RandomGen g) => RandomProcess g -> (Double, RandomProcess g)
rand r@(RandomProcess ps self g) = 
    let (r, g') = random g
        index = toIndex ps r
    in if self == (ps !! index)
        then rand (RandomProcess ps self g')
        else (r, RandomProcess ps self g')

initNumberNode :: Int -> Process ()
initNumberNode seed = do
    AckMsg msg@(Init ps) okChan <- expect
    say $ printf "message received: <- %s" (show msg)
    ack okChan []
    leader <- isLeader 0 ps
    g <- newRandomProcess ps seed
    if leader then do
        let (r, g') = rand g
        propogateNumber ps r
        numberNode [r] g' (Shutdown Nothing Nothing) ps
    else numberNode [] g (Shutdown Nothing Nothing) ps

numberNode :: (RandomGen g) => [Double] -> RandomProcess g -> ShutdownState -> [ProcessId] -> Process ()
numberNode rs g shutdown ps = do
    AckMsg msg ackChan <- expect
    say $ printf "message received: <- %s" (show msg)
    case msg of
        (Number thisr) -> do 
            leader <- isLeader thisr ps
            let newrs = thisr:rs
            ack ackChan []
            if leader
            then case masterChan shutdown of
                Nothing -> do
                    let (newr, g') = rand g
                    propogateNumber ps newr
                    numberNode (newr:newrs) g' shutdown ps
                (Just s) -> do
                    say "leader is starting shutdown"
                    sendAndWait DoneFromLeader ps
                    say $ printf "result: %s" (show $ result newrs)
                    say "shutting down"
                    ack s newrs
            else numberNode newrs g shutdown ps
        DoneFromMaster -> nodeShutdown rs g (setMasterChan shutdown ackChan) ps
        DoneFromLeader -> nodeShutdown rs g (setLeaderChan shutdown ackChan) ps

ack :: AckChan -> [Double] -> Process ()
ack chan rs = do
    self <- getSelfPid
    sendChan chan (self, rs)

-- | result calculates the tuple to be printed out given the reversed list of messages.
result :: [Double] -> (Int, Double)
result = foldr (\d (size, sum) -> (size+1, sum + d * fromIntegral (size+1))) (0,0.0)

nodeShutdown :: (RandomGen g) => [Double] -> RandomProcess g -> ShutdownState -> [ProcessId] -> Process ()
nodeShutdown rs g shutdown ps = case shutdown of
    (Shutdown (Just m) (Just l)) -> do
        say $ printf "result: %s" (show $ result rs)
        say "shutting down"
        ack l []
        ack m rs
    _ -> numberNode rs g shutdown ps

propogateNumber :: [ProcessId] -> Double -> Process ()
propogateNumber ps r = do
    let msg = Number r
        (leader, followers) = selectLeader r ps
    sendAndWait msg followers
    sendAndWait msg [leader]
    return ()

remotable ['initNumberNode]

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

spawnAll :: [(Int, NodeId)] -> Process [ProcessId]
spawnAll peers = forM peers $ \(seed, nid) -> do
    say $ printf "spawning on %s" (show nid)
    spawn nid $ $(mkClosure 'initNumberNode) seed

master :: (RandomGen g) => Backend -> Int -> Int -> g -> [NodeId] -> Process ()
master _ _ _ _ [] = return ()
master _ _ _ _ [p] = return ()
master backend sendFor waitFor r peers = do

    let sendForSecs = sendFor * 1000 * 1000
        waitForSecs = waitFor * 1000 * 1000
        seeds = take (length peers) $ randoms r
        seeded = zip seeds (sort peers)

    ps <- spawnAll seeded
    refs <- mapM_ monitor ps

    let msg = Init ps
        (leader, followers) = selectLeader 0 ps

    say $ printf "master: leader: %s, followers: %s" (show leader) (show followers)
    sendAndWait msg followers
    sendAndWait msg [leader]

    say "master: init complete"
    liftIO $ threadDelay sendForSecs

    say "master: starting shutdown"
    resChan <- sendToAll DoneFromMaster ps
    (sendCancel, recvCancel) <- newChan

    spawnLocal $ do
        liftIO $ threadDelay waitForSecs
        say "master: canceling shutdown"
        ack sendCancel []

    oneResChan <- mergePortsBiased (recvCancel:resChan)
    rs <- waitForAll oneResChan ps

    terminateAllSlaves backend

    when (length rs /= length ps) $ error "did not recceive all results"
    when (any (/= head rs) rs) $ error "not all results are equal"

    say "master: successful shutdown"