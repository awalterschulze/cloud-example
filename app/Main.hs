module Main where

import qualified Exercise

import Options.Applicative
import Data.Semigroup ((<>))

import System.Random (mkStdGen)
import Data.ByteString.Char8 (pack)

import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process (NodeId(..))
import Network.Transport (EndPointAddress(..))
import Control.Distributed.Process.Backend.SimpleLocalnet (initializeBackend, startMaster, startSlave)

data Flags = Flags
    { sendFor    :: Int
    , waitFor    :: Int
    , seed       :: Int 
    , master     :: Bool
    , host       :: String
    , port       :: String
    , discover   :: Bool
    }
  deriving (Show)

flags :: Parser Flags
flags = Flags
  <$> option auto
    ( long "send-for" <> help "denotes how many seconds does the system send messages" <> showDefault <> value 1 <> metavar "SECONDS")
  <*> option auto
    ( long "wait-for" <> help "denotes the length of the grace period in seconds" <> showDefault <> value 10 <> metavar "SECONDS")
  <*> option auto
    ( long "with-seed" <> help "How enthusiastically to greet" <> showDefault <> value 1 <> metavar "INT")
  <*> switch
    ( long "master" <> help "Is this the master node or slave" )
  <*> strOption
    ( long "host" <> help "host address" <> showDefault <> value "127.0.0.1")
  <*> strOption
    ( long "port" <> help "host port" <> showDefault <> value "4444")
  <*> switch
    ( long "discover" <> help "discover nodes rather than hard coding them" )

-- | hardcodedAddrs can be modified to reflect the slaves that have been started up
hardcodedAddrs :: [String]
hardcodedAddrs = ["127.0.0.1:4445:0", "127.0.0.1:4446:0", "127.0.0.1:4447:0"]

main :: IO ()
main = do 
  flags <- execParser (info (flags <**> helper) fullDesc)
  backend <- initializeBackend (host flags) (port flags) (Exercise.remoteTable initRemoteTable)
  print flags
  if master flags
    then startMaster backend (\discoveredNodes -> 
          Exercise.master backend
          (sendFor flags)
          (waitFor flags)
          (mkStdGen (seed flags)) 
          (if discover flags then discoveredNodes else map (NodeId . EndPointAddress . pack) hardcodedAddrs))
    else startSlave backend
