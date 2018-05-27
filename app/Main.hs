module Main where

import qualified Lib

import Options.Applicative
import Data.Semigroup ((<>))
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process
import Control.Concurrent (threadDelay)
import qualified Network.Transport as NT
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Backend.SimpleLocalnet
import System.Random (mkStdGen)

data Flags = Flags
    { sendFor    :: Int
    , waitFor    :: Int
    , seed       :: Int 
    , master     :: Bool
    , host       :: String
    , port       :: String
    }
  deriving (Show)

flags :: Parser Flags
flags = Flags
      <$> option auto
        ( long "send-for"
        <> help "denotes how many seconds does the system send messages"
        <> metavar "SECONDS")
      <*> option auto
        ( long "wait-for"
        <> help "denotes the length of the grace period in seconds"
        <> metavar "SECONDS")
      <*> option auto
        ( long "with-seed"
        <> help "How enthusiastically to greet"
        <> showDefault
        <> value 1
        <> metavar "INT")
      <*> switch
        ( long "master"
        <> help "Is this the master node or slave" )
      <*> strOption
        ( long "host"
        <> help "host address"
        <> showDefault
        <> value "127.0.0.1")
      <*> strOption
        ( long "port"
        <> help "host port"
        <> showDefault
        <> value "4444")

main :: IO ()
main = do 
  flags <- execParser (info (flags <**> helper) fullDesc)
  backend <- initializeBackend (host flags) (port flags) (Lib.remoteTable initRemoteTable)
  let r = mkStdGen (seed flags)
  print flags
  if master flags
    then startMaster backend (Lib.master backend (sendFor flags) (waitFor flags) r)
    else startSlave backend
