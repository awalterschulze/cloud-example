{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib
    ( remoteTable
    , master
    ) where

import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import Data.Binary
import Data.List (sort)

import System.Environment (getArgs)
import Control.Monad (forM, forM_, when)

import Text.Printf (printf)
import Data.ByteString.Char8 (pack)

import System.Random (RandomGen, random, mkStdGen, StdGen, randoms)
import Control.Distributed.Process
import Control.Concurrent (threadDelay)
import qualified Network.Transport as NT
import Control.Distributed.Process.Closure

import Control.Distributed.Process.Backend.SimpleLocalnet

type ReplyChan = SendPort ProcessId

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

nodes :: [NodeId]
nodes = map (NodeId . NT.EndPointAddress . pack) ["127.0.0.1:4445:0", "127.0.0.1:4446:0"]

-- toIndex converts the randomly generated number double [0,1) to an index in the list.
toIndex :: [a] -> Double -> Int
toIndex ps d = truncate $ d * fromIntegral (length ps)

-- isLeader checks whether the random number is accosiated with the given item in the list.
isLeader :: (Eq a) => Double -> [a] -> a -> Bool
isLeader n ps p = p == ps !! toIndex ps n

-- selectLeader returns the leader by removing it from the list and returning both the leader and the rest of the list.
selectLeader :: (Eq a) => Double -> [a] -> (a, [a])
selectLeader n ps = 
    let index = toIndex ps n
        (h, t) = splitAt index ps
    in (head t, h ++ tail t)

sendToAll :: Content -> [ProcessId] -> Process [ReceivePort ProcessId]
sendToAll msg ps = forM ps $ \pid -> do
    (sendport,recvport) <- newChan
    send pid (ReplyMsg msg sendport)
    return recvport

waitForAll :: ReceivePort ProcessId -> [ProcessId] -> Process () 
waitForAll _ [] = return ()
waitForAll port ps = do
    pid <- receiveChan port
    waitForAll port (filter (/= pid) ps)

sendAndWait :: Content -> [ProcessId] -> Process ()
sendAndWait msg ps = do
    say $ printf "sending %s to all %s" (show msg) (show ps)
    ports <- sendToAll msg ps
    oneport <- mergePortsBiased ports
    waitForAll oneport ps

-- rand randomly generates a random number that won't reselect the current node as the leader.
rand :: [ProcessId] -> ProcessId -> StdGen -> (Double, StdGen)
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
    sendChan okChan p
    if leader
        then do 
            let (r, g') = rand ps p g
            propogateNumber ps r
            numberNode g' (Shutdown Nothing Nothing) ps
        else numberNode g (Shutdown Nothing Nothing) ps
    

numberNode :: StdGen -> ShutdownState -> [ProcessId] -> Process ()
numberNode g shutdown ps = do
    p <- getSelfPid
    ReplyMsg msg okChan <- expect
    say $ printf "message received: %s <- %s" (show p) (show msg)
    case msg of
        (Number r) -> do 
            let leader = isLeader r ps p
            say $ printf "%s, leader = %s" (show p) (show leader)
            sendChan okChan p
            if leader
            then case masterChan shutdown of
                Nothing -> do
                    let (r, g') = rand ps p g
                    propogateNumber ps r
                    numberNode g' shutdown ps
                (Just s) -> do
                    sendChan s p
                    say $ printf "leader %s is starting shutdown" (show p)
                    sendAndWait DoneFromLeader ps
                    say $ printf "leader %s is done" (show p)
            else numberNode g shutdown ps
        DoneFromMaster -> nodeShutdown g (setMasterChan shutdown okChan) ps
        DoneFromLeader -> nodeShutdown g (setLeaderChan shutdown okChan) ps

nodeShutdown :: StdGen -> ShutdownState -> [ProcessId] -> Process ()
nodeShutdown g shutdown ps = do
    mypid <- getSelfPid
    case shutdown of
        (Shutdown (Just m) (Just l)) -> do
            say $ printf "shutting down: %s" (show mypid)
            sendChan l mypid
            sendChan m mypid
        _ -> numberNode g shutdown ps

propogateNumber :: [ProcessId] -> Double -> Process ()
propogateNumber ps r = do
    mypid <- getSelfPid
    let msg = Number r
        (leader, followers) = selectLeader r ps
        followersWithoutMe = filter (/= mypid) followers
    say $ printf "sending message: %s -(%s)> %s" (show leader) (show msg) (show followersWithoutMe)
    sendAndWait msg followersWithoutMe
    sendAndWait msg [leader]

remotable ['initNumberNode]

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

spawnAll :: [(Int, NodeId)] -> Process [ProcessId]
spawnAll peers = forM peers $ \(seed, nid) -> do
    say $ printf "spawning on %s" (show nid)
    spawn nid $ $(mkClosure 'initNumberNode) seed

master :: Backend -> Int -> Int -> StdGen -> [NodeId] -> Process () 
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
    sendAndWait DoneFromMaster ps

    say "master: successful shutdown"
    terminateAllSlaves backend
