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
import Control.Monad (forM, forM_)

import Text.Printf (printf)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet

data Msg = Ping (SendPort ProcessId)
    deriving (Typeable, Generic)

instance Binary Msg

pingServer :: Process () 
pingServer = do
    Ping chan <- expect
    say $ printf "ping received from %s" (show chan)
    mypid <- getSelfPid
    sendChan chan mypid

remotable ['pingServer]

master :: Backend -> [NodeId] -> Process () 
master backend peers = do
    ps <- forM peers $ \nid -> do
        say $ printf "spawning on %s" (show nid)
        spawn nid $(mkStaticClosure 'pingServer)

    mapM_ monitor ps

    ports <- forM ps $ \pid -> do
        say $ printf "pinging %s" (show pid)
        (sendport,recvport) <- newChan
        send pid (Ping sendport)
        return recvport

    oneport <- mergePortsBiased ports
    waitForPongs oneport ps

    say "All pongs successfully received"
    terminateAllSlaves backend

waitForPongs :: ReceivePort ProcessId -> [ProcessId] -> Process () 
waitForPongs _ [] = return ()
waitForPongs port ps = do
    pid <- receiveChan port
    waitForPongs port (filter (/= pid) ps)

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
