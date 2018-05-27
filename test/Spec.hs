module Main where

import qualified Test.Tasty as T
import qualified Test.Tasty.HUnit as HUnit
import qualified Exercise

main :: IO ()
main = T.defaultMain $ T.testGroup "Example" [
        T.testGroup "result" [
            HUnit.testCase "result" $ HUnit.assertEqual "empty" (0, 0.0) (Exercise.result [])
            , HUnit.testCase "result" $ HUnit.assertEqual "empty" (3, 1*0.3 + 2*0.5 + 3*1.2) (Exercise.result [1.2, 0.5, 0.3])
        ]
    ]
