{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib
    ( main
    ) where

import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import Data.Binary

import System.Environment (getArgs)
import Control.Monad (forM, forM_, when)

import Text.Printf (printf)
import Data.ByteString.Char8 (pack)

import Control.Distributed.Process
import qualified Network.Transport as NT
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node (initRemoteTable)
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
    deriving (Show, Typeable, Generic)

instance Binary Content
instance Binary Msg

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

numberNode :: Process () 
numberNode = do
    ReplyMsg (Init ps) doneChan <- expect
    mypid <- getSelfPid
    let leader = isLeader 0 ps mypid
    say $ printf "init I am leader (%s)" (show leader)
    sendChan doneChan mypid
    when leader $ do
        say "leader sending new message"
        let newNumber = 1 `mod` length ps
            msg = Number newNumber
            (leader, followers) = getLeader newNumber ps
            followersWithoutMe = filter (/= mypid) followers
        say $ printf "leader: %s, followers: %s, followersWithoutMe" (show leader) (show followers) (show followersWithoutMe)
        sendAndWait msg followersWithoutMe
        sendAndWait msg [leader]

remotable ['numberNode]

spawnAll :: [NodeId] -> Process [ProcessId]
spawnAll peers = forM peers $ \nid -> do
    say $ printf "spawning on %s" (show nid)
    spawn nid $(mkStaticClosure 'numberNode)

master :: Backend -> [NodeId] -> Process () 
master backend peers = do
    ps <- spawnAll peers

    refs <- mapM_ monitor ps

    let msg = Init ps
        (leader, followers) = getLeader 0 ps
    say $ printf "leader: %s, followers: %s" (show leader) (show followers)
    sendAndWait msg followers
    sendAndWait msg [leader]

    say "All pongs successfully received"
    terminateAllSlaves backend

main :: IO ()
main = do
  args <- getArgs

  let defaultArgs = case args of
        [] -> ["master", "127.0.0.1", "4444"]
        ["master"] -> ["master", "127.0.0.1", "4444"]
        ["slave", port] -> ["slave", "127.0.0.1", port]

  case defaultArgs of
    ["master", host, port] -> do
      backend <- initializeBackend host port (__remoteTable initRemoteTable)
      startMaster backend (master backend)
    ["slave", host, port] -> do
      backend <- initializeBackend host port (__remoteTable initRemoteTable)
      startSlave backend
