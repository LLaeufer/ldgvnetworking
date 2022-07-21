{-# LANGUAGE OverloadedStrings #-}
module Config where

import qualified Debug.Trace as D
import PrettySyntax (Pretty, pshow)
import Control.Monad.IO.Class

selected :: String -> Bool
selected ident = ident `elem` ["valueEquiv", "subtype"]

data DebugLevel = DebugNone | DebugAll
  deriving (Eq, Ord, Show)

debugLevel :: DebugLevel
--debugLevel = DebugAll
debugLevel = DebugNone

trace :: String -> a -> a
trace s a | debugLevel > DebugNone = D.trace s a
          | otherwise = a

traceOnly :: String -> String -> a -> a
traceOnly ident s a
  | selected ident = D.trace (ident ++ ": " ++ s) a
  | otherwise = a

traceOnlyM :: Applicative f => String -> String -> f ()
traceOnlyM ident s
  | selected ident = D.traceM (ident ++ ": " ++ s)
  | otherwise = pure ()

traceM :: Applicative f => String -> f ()
traceM s | debugLevel > DebugNone = D.traceM s
         | otherwise = pure ()

traceShowM :: (Show a, Applicative f) => a -> f ()
traceShowM = traceM . show

traceIO :: MonadIO m => String -> m ()
traceIO s | debugLevel > DebugNone = liftIO $ D.traceIO s
          | otherwise = pure ()

traceSuccess :: (Pretty a, Applicative f) => a -> f ()
traceSuccess a
  | debugLevel > DebugNone = traceM $ "Success: " ++ pshow a
  | otherwise = traceM "Success"
