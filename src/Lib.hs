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

import System.Environment (getArgs)
import Control.Monad (forM, forM_, when)

import Text.Printf (printf)
import Data.ByteString.Char8 (pack)

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
        num :: Int
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

isLeader :: Int -> [ProcessId] -> ProcessId -> Bool
isLeader n ps p = p == (ps !! n)

getLeader :: Int -> [ProcessId] -> (ProcessId, [ProcessId])
getLeader n ps = let (h, t) = splitAt n ps
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

initNumberNode :: Process () 
initNumberNode = do
    ReplyMsg (Init ps) okChan <- expect
    mypid <- getSelfPid
    let leader = isLeader 0 ps mypid
    say $ printf "process %s received init, I am leader (%s)" (show mypid) (show leader)
    sendChan okChan mypid
    when leader (propogateNumber ps 0)
    numberNode (Shutdown Nothing Nothing) ps

numberNode :: ShutdownState -> [ProcessId] -> Process ()
numberNode shutdown ps = do
    mypid <- getSelfPid
    ReplyMsg msg okChan <- expect
    say $ printf "process %s received message %s" (show mypid) (show msg)
    case msg of
        (Number n) -> do 
            let leader = isLeader n ps mypid
            say $ printf "received number (%d) I am leader (%s)" n (show leader)
            sendChan okChan mypid
            if leader
            then case masterChan shutdown of
                Nothing -> do
                    propogateNumber ps n
                    numberNode shutdown ps
                (Just s) -> do
                    sendChan s mypid
                    say $ printf "leader %s is starting shutdown" (show mypid)
                    sendAndWait DoneFromLeader ps
                    say $ printf "leader %s is done" (show mypid)
            else numberNode shutdown ps
        DoneFromMaster -> do
            say $ printf "process %s received done from master" (show mypid)
            nodeShutdown (setMasterChan shutdown okChan) ps
        DoneFromLeader -> do
            say $ printf "process %s received done from leader" (show mypid)
            nodeShutdown (setLeaderChan shutdown okChan) ps

nodeShutdown :: ShutdownState -> [ProcessId] -> Process ()
nodeShutdown shutdown ps = do
    mypid <- getSelfPid
    case shutdown of
        (Shutdown (Just m) (Just l)) -> do
            say $ printf "process %s shutting down" (show mypid)
            sendChan l mypid
            sendChan m mypid
        _ -> numberNode shutdown ps

propogateNumber :: [ProcessId] -> Int -> Process ()
propogateNumber ps n = do
    mypid <- getSelfPid
    say $ printf "leader %s sending new message" (show mypid)
    let newNumber = (n + 1) `mod` (length ps)
        msg = Number newNumber
        (leader, followers) = getLeader newNumber ps
        followersWithoutMe = filter (/= mypid) followers
    say $ printf "leader: %s, followers: %s, followersWithoutMe: %s" (show leader) (show followers) (show followersWithoutMe)
    sendAndWait msg followersWithoutMe
    sendAndWait msg [leader]

remotable ['initNumberNode]

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

spawnAll :: [NodeId] -> Process [ProcessId]
spawnAll peers = forM peers $ \nid -> do
    say $ printf "spawning on %s" (show nid)
    spawn nid $(mkStaticClosure 'initNumberNode)

master :: Backend -> Int -> Int -> Int -> [NodeId] -> Process () 
master backend sendFor waitFor seed peers = do
    ps <- spawnAll peers

    refs <- mapM_ monitor ps

    let msg = Init ps
        (leader, followers) = getLeader 0 ps
    say $ printf "leader: %s, followers: %s" (show leader) (show followers)
    sendAndWait msg followers
    sendAndWait msg [leader]

    liftIO $ threadDelay 1000000

    say "master is starting shutdown"
    sendAndWait DoneFromMaster ps

    say "successful shutdown"
    terminateAllSlaves backend


