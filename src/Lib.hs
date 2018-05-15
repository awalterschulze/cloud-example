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

data Msg = Ping ProcessId
    | Pong ProcessId
    deriving (Typeable, Generic) -- instance Binary Msg

instance Binary Msg

pingServer :: Process () 
pingServer = do
    Ping from <- expect
    say $ printf "ping received from %s" (show from)
    mypid <- getSelfPid
    send from (Pong mypid)

remotable ['pingServer]

master :: Backend -> [NodeId] -> Process () 
master backend peers = do
    ps <- forM peers $ \nid -> do
        say $ printf "spawning on %s" (show nid)
        spawn nid $(mkStaticClosure 'pingServer)

    mypid <- getSelfPid

    forM_ ps $ \pid -> do
        say $ printf "pinging %s" (show pid)
        send pid (Ping mypid)

    waitForPongs ps

    say "All pongs successfully received"
    terminateAllSlaves backend

waitForPongs :: [ProcessId] -> Process ()
waitForPongs [] = return ()
waitForPongs ps = do
    m <- expect 
    case m of
        Pong p -> waitForPongs (filter (/= p) ps)
        _ -> say "MASTER received ping" >> terminate

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
