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
            HUnit.testCase "empty" $ HUnit.assertEqual "" (0, 0.0) (Exercise.result [])
            , HUnit.testCase "three items" $ HUnit.assertEqual "" (3, 1*0.3 + 2*0.5 + 3*1.2) (Exercise.result [1.2, 0.5, 0.3])
        ]
        , T.testGroup "select leader" [
            HUnit.testCase "2" $ HUnit.assertEqual "" (1, [2]) (Exercise.selectLeader 0 [1,2])
            , HUnit.testCase "1" $ HUnit.assertEqual "" (1, []) (Exercise.selectLeader 0 [1])
            , HUnit.testCase "4" $ HUnit.assertEqual "" (1, [2,3,4]) (Exercise.selectLeader 0 [1,2,3,4])
            , HUnit.testCase "4 with number 0.33" $ HUnit.assertEqual "" (2, [1,3,4]) (Exercise.selectLeader 0.33 [1,2,3,4])
            , HUnit.testCase "4 with number 0.99" $ HUnit.assertEqual "" (4, [1,2,3]) (Exercise.selectLeader 0.99 [1,2,3,4])
        ]
        , T.testGroup "full program" [
            -- HUnit.testCase "1 node" $ run ["127.0.0.1:4444:0"]
            HUnit.testCase "3 nodes" $ run "4443" (replicate 3 "127.0.0.1:4443:0")
            , HUnit.testCase "2 nodes" $ run "4442" (replicate 2 "127.0.0.1:4442:0")

        ]
    ]

run :: String -> [String] -> IO ()
run port addrs = do
    backend <- initializeBackend "127.0.0.1" port (Exercise.remoteTable initRemoteTable)
    let r = mkStdGen 0
        nodes = map (NodeId . EndPointAddress . pack) addrs
    startMaster backend (\_ -> Exercise.master backend 1 1 r nodes)
