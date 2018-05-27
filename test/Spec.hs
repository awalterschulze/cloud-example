module Main where

import qualified Test.Tasty as T
import qualified Test.Tasty.HUnit as HUnit
import qualified Exercise

import System.Random (mkStdGen)
import Data.ByteString.Char8 (pack)

import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process (NodeId(..))
import Network.Transport (EndPointAddress(..))
import Control.Distributed.Process.Backend.SimpleLocalnet (initializeBackend, startMaster, startSlave)

main :: IO ()
main = T.defaultMain $ T.testGroup "Example" [
        T.testGroup "result" [
            HUnit.testCase "result" $ HUnit.assertEqual "empty" (0, 0.0) (Exercise.result [])
            , HUnit.testCase "result" $ HUnit.assertEqual "empty" (3, 1*0.3 + 2*0.5 + 3*1.2) (Exercise.result [1.2, 0.5, 0.3])
        ]
        , T.testGroup "3 nodes" [
            HUnit.testCase "run" $ run (replicate 3 "127.0.0.1:4444:0")
        ]
    ]

run :: [String] -> IO ()
run addrs = do
    backend <- initializeBackend "127.0.0.1" "4444" (Exercise.remoteTable initRemoteTable)
    let r = mkStdGen 0
        nodes = map (NodeId . EndPointAddress . pack) addrs
    startMaster backend (\_ -> Exercise.master backend 1 1 r nodes)
