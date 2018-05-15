{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib
    ( main
    ) where

import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import Data.Binary

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

master :: Process () 
master = do
    node <- getSelfNode
    say $ printf "spawning on %s" (show node)
    pid <- spawn node $(mkStaticClosure 'pingServer)
    mypid <- getSelfPid
    say $ printf "sending ping to %s" (show pid)
    send pid (Ping mypid)
    Pong _ <- expect
    say "pong."
    terminate

main :: IO ()
main = do {
    backend <- initializeBackend "127.0.0.1" "10501" (__remoteTable initRemoteTable);
    startMaster backend (\_ -> master);
}