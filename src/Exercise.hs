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
import System.Random (random, mkStdGen, RandomGen, randoms)

import Control.Distributed.Process (
    ProcessId, SendPort, ReceivePort, Process, RemoteTable, NodeId
    , say, send, newChan, receiveChan, sendChan, mergePortsBiased, expect, getSelfPid, spawn, monitor, liftIO)
import Control.Concurrent (threadDelay)
import Control.Distributed.Process.Closure (mkClosure, remotable)
import Control.Distributed.Process.Backend.SimpleLocalnet (Backend, terminateAllSlaves)

type ReplyChan = SendPort (ProcessId, [Double])

data Msg = ReplyMsg {
        content :: Content
        , reply :: ReplyChan
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
    masterChan :: Maybe ReplyChan
    , leaderChan :: Maybe ReplyChan
}

setMasterChan :: ShutdownState -> ReplyChan -> ShutdownState
setMasterChan (Shutdown _ l) m = Shutdown (Just m) l

setLeaderChan :: ShutdownState -> ReplyChan -> ShutdownState
setLeaderChan (Shutdown m _) l = Shutdown m (Just l)

-- | toIndex converts the randomly generated number double [0,1) to an index in the list.
toIndex :: [a] -> Double -> Int
toIndex ps d = truncate $ d * fromIntegral (length ps)

-- | isLeader checks whether the random number is accosiated with the given item in the list.
isLeader :: (Eq a) => Double -> [a] -> a -> Bool
isLeader n ps p = p == ps !! toIndex ps n

-- | selectLeader returns the leader by removing it from the list and returning both the leader and the rest of the list.
selectLeader :: (Eq a) => Double -> [a] -> (a, [a])
selectLeader r ps = 
    let index = toIndex ps r
        (h, t) = splitAt index ps
    in (head t, h ++ tail t)

sendToAll :: Content -> [ProcessId] -> Process [ReceivePort (ProcessId, [Double])]
sendToAll msg ps = forM ps $ \pid -> do
    (sendport,recvport) <- newChan
    send pid (ReplyMsg msg sendport)
    return recvport

waitForAll :: ReceivePort (ProcessId, [Double]) -> [ProcessId] -> Process [[Double]] 
waitForAll _ [] = return []
waitForAll port ps = do
    (pid, rs) <- receiveChan port
    rss <- waitForAll port (filter (/= pid) ps)
    return (rs:rss)

sendAndWait :: Content -> [ProcessId] -> Process [[Double]]
sendAndWait msg ps = do
    say $ printf "sending %s to all %s" (show msg) (show ps)
    ports <- sendToAll msg ps
    oneport <- mergePortsBiased ports
    waitForAll oneport ps

-- | rand randomly generates a random number that won't reselect the current node as the leader.
rand :: (RandomGen g) => [ProcessId] -> ProcessId -> g -> (Double, g)
rand ps p g = 
    let (r, g') = random g
        index = toIndex ps r
    in if p == (ps !! index)
        then rand ps p g'
        else (r, g')

initNumberNode :: Int -> Process () 
initNumberNode seed = do
    ReplyMsg msg@(Init ps) okChan <- expect
    p <- getSelfPid
    let leader = isLeader 0 ps p
        g = mkStdGen seed
    say $ printf "message received: %s <- %s, leader=%s" (show p) (show msg) (show leader)
    sendChan okChan (p, [])
    if leader
        then do 
            let (r, g') = rand ps p g
            propogateNumber ps r
            numberNode [r] g' (Shutdown Nothing Nothing) ps
        else numberNode [] g (Shutdown Nothing Nothing) ps

numberNode :: (RandomGen g) => [Double] -> g -> ShutdownState -> [ProcessId] -> Process ()
numberNode rs g shutdown ps = do
    p <- getSelfPid
    ReplyMsg msg okChan <- expect
    say $ printf "message received: %s <- %s" (show p) (show msg)
    case msg of
        (Number r) -> do 
            let leader = isLeader r ps p
            say $ printf "%s, leader = %s" (show p) (show leader)
            sendChan okChan (p, [])
            if leader
            then case masterChan shutdown of
                Nothing -> do
                    let (r', g') = rand ps p g
                    propogateNumber ps r'
                    numberNode (r':r:rs) g' shutdown ps
                (Just s) -> do
                    say $ printf "leader %s is starting shutdown" (show p)
                    sendAndWait DoneFromLeader (filter (/= p) ps)
                    say $ printf "result: %s" (show $ result (r:rs))
                    say $ printf "shutting down: %s" (show p)
                    sendChan s (p, (r:rs))
            else numberNode (r:rs) g shutdown ps
        DoneFromMaster -> nodeShutdown rs g (setMasterChan shutdown okChan) ps
        DoneFromLeader -> nodeShutdown rs g (setLeaderChan shutdown okChan) ps

-- | result calculates the tuple to be printed out given the reversed list of messages.
result :: [Double] -> (Int, Double)
result = foldr (\d (size, sum) -> (size+1, sum + d * fromIntegral (size+1))) (0,0.0)

nodeShutdown :: (RandomGen g) => [Double] -> g -> ShutdownState -> [ProcessId] -> Process ()
nodeShutdown rs g shutdown ps = do
    mypid <- getSelfPid
    case shutdown of
        (Shutdown (Just m) (Just l)) -> do
            say $ printf "result: %s" (show $ result rs)
            say $ printf "shutting down: %s" (show mypid)
            sendChan l (mypid, [])
            sendChan m (mypid, rs)
        _ -> numberNode rs g shutdown ps

propogateNumber :: [ProcessId] -> Double -> Process ()
propogateNumber ps r = do
    mypid <- getSelfPid
    let msg = Number r
        (leader, followers) = selectLeader r ps
        followersWithoutMe = filter (/= mypid) followers
    say $ printf "sending message: %s -(%s)> %s" (show leader) (show msg) (show followersWithoutMe)
    sendAndWait msg followersWithoutMe
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
master backend sendFor waitFor r peers = do

    let sendForSeconds = sendFor * 1000 * 1000
        waitForSecodds = waitFor * 1000 * 1000
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
    liftIO $ threadDelay sendForSeconds

    say "master: starting shutdown"
    rs <- sendAndWait DoneFromMaster ps

    say "master: successful shutdown"
    terminateAllSlaves backend

    when (length rs /= length ps) $ error "did not recceive all results"
    when (any (/= head rs) rs) $ error "not all results are equal"