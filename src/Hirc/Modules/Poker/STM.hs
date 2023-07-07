{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}

module Hirc.Modules.Poker.STM where

import Control.Concurrent.STM
  ( STM,
    TVar,
    catchSTM,
    modifyTVar,
    readTVar,
    retry,
    throwSTM,
    writeTVar,
  )
import Control.Concurrent.STM qualified as STM
import Control.Monad (unless, when)
import Control.Monad.Random (RandomGen (split))
import Control.Monad.Reader (ReaderT, runReaderT)
import Control.Monad.Reader qualified as R
import Control.Monad.Trans (lift, liftIO)
import Data.Either (fromLeft)
import Data.List qualified as L
import Data.Map (Map)
import Data.Map qualified as M
import Data.Maybe (catMaybes, fromJust, isJust, isNothing, mapMaybe)
import Hirc
import Hirc.Modules.Poker.Bank (Bank, Money)
import Hirc.Modules.Poker.Exception
import Hirc.Modules.Poker.Game hiding (updatePlayer)
import Hirc.Modules.Poker.Game qualified as G
import Hirc.Modules.Poker.Module
import Hirc.Modules.Poker.Player

--------------------------------------------------------------------------------
-- Main type definition
--

type PokerSTM = ReaderT (TVar PokerState, NickName, UserName, Maybe ChannelName) STM

--------------------------------------------------------------------------------
-- Lifted STM operations

orElse :: PokerSTM a -> PokerSTM a -> PokerSTM a
orElse a b = do
  r <- R.ask
  lift $ STM.orElse (runReaderT a r) (runReaderT b r)

checkP :: Bool -> PokerSTM ()
checkP = lift . STM.check

--------------------------------------------------------------------------------
-- STM Exception handling
--

throwP :: PokerException -> PokerSTM a
throwP = lift . throwSTM

catchP :: PokerSTM a -> (PokerException -> PokerSTM a) -> PokerSTM a
catchP m h = do
  r <- R.ask
  lift $ runReaderT m r `catchSTM` \e -> runReaderT (h e) r

handleP :: (PokerException -> PokerSTM a) -> PokerSTM a -> PokerSTM a
handleP = flip catchP

--------------------------------------------------------------------------------
-- Bank
--

askBank :: PokerSTM Bank
askBank = bank <$> askPokerState

updateBank :: (Bank -> Bank) -> PokerSTM ()
updateBank f = updatePokerState $ \pokerState ->
  pokerState
    { bank = f (bank pokerState)
    }

putBank :: Bank -> PokerSTM ()
putBank b = updatePokerState $ \ps -> ps {bank = b}

--------------------------------------------------------------------------------
-- Poker state
--

askNick :: PokerSTM NickName
askNick = do
  (_, n, _, _) <- R.ask
  return n

askUser :: PokerSTM UserName
askUser = do
  (_, _, u, _) <- R.ask
  return u

askChan :: PokerSTM (Maybe ChannelName)
askChan = do
  (_, _, _, mc) <- R.ask
  return mc

requireChan :: PokerSTM ChannelName
requireChan = do
  mc <- askChan
  maybe (lift retry) return mc

askPokerState :: PokerSTM PokerState
askPokerState = do
  (tvar, _, _, _) <- R.ask
  lift $ readTVar tvar

putPokerState :: PokerState -> PokerSTM ()
putPokerState ps = do
  (tvar, _, _, _) <- R.ask
  lift $ writeTVar tvar ps

updatePokerState :: (PokerState -> PokerState) -> PokerSTM ()
updatePokerState f = do
  (tvar, _, _, _) <- R.ask
  lift $ modifyTVar tvar f

--------------------------------------------------------------------------------
-- Game state
--

askGameState :: PokerSTM GameState
askGameState = do
  ps <- askPokerState
  ch <- requireChan
  case M.lookup ch (games ps) of
    Just s -> return s
    Nothing -> do
      let (g1, g2) = split $ stdGen ps
          s = Left $ newGame g1
      putPokerState
        ps
          { games = M.insert ch s (games ps),
            stdGen = g2
          }
      return s

putGameState :: GameState -> PokerSTM ()
putGameState s = do
  chan <- requireChan
  updatePokerState $ \ps ->
    ps
      { games = M.insert chan s (games ps)
      }

askMaybeGameState :: PokerSTM (Maybe GameState)
askMaybeGameState = do
  ps <- askPokerState
  ch <- requireChan
  return $ M.lookup ch (games ps)

askMaybeGame :: PokerSTM (Maybe Game)
askMaybeGame = do
  ms <- askMaybeGameState
  return $ case ms of
    Just (Left g) -> Just g
    _ -> Nothing

askMaybeGameResult :: PokerSTM (Maybe GameResult)
askMaybeGameResult = do
  ms <- askMaybeGameState
  return $ case ms of
    Just (Right r) -> Just r
    _ -> Nothing

askGame :: PokerSTM Game
askGame = maybe (lift retry) return =<< askMaybeGame

putGame :: Game -> PokerSTM ()
putGame = putGameState . Left

-- | Update game if exists, or create a new game for current channel if none
-- have been started before.
updateGame :: (Game -> GameUpdate) -> PokerSTM ()
updateGame f = do
  s <- askGameState
  case either f GameEnded s of
    GameUpdated g' -> putGame g'
    GameEnded res -> putGameState $ Right res
    GameUpdateFailed e -> lift $ throwSTM e

askGameResult :: PokerSTM GameResult
askGameResult = maybe (lift retry) return =<< askMaybeGameResult

putGameResult :: GameResult -> PokerSTM ()
putGameResult = putGameState . Right

resetGame :: PokerSTM ()
resetGame = do
  ps <- askPokerState
  let (g1, g2) = split $ stdGen ps
  putPokerState ps {stdGen = g2}
  putGameState $ Left $ newGame g1

--------------------------------------------------------------------------------
-- Players
--

askPlayer :: PokerSTM Player
askPlayer = do
  u <- askUser
  g <- askGame
  maybe (lift retry) return $ findPlayer u g

updatePlayer :: UserName -> (Player -> Player) -> PokerSTM ()
updatePlayer u f = do
  g <- askGame
  unless (isJust $ findPlayer u g) $
    lift retry
  putGame $ G.updatePlayer u f g

putPlayer :: Player -> PokerSTM ()
putPlayer p = updatePlayer (playerUsername p) (const p)

userInGame :: PokerSTM Bool
userInGame = (True <$ askPlayer) `orElse` return False

askPlayers :: PokerSTM [Player]
askPlayers = (\g -> mapMaybe (`G.findPlayer` g) $ players g) <$> askGame

askCurrentPosition :: PokerSTM Position
askCurrentPosition = currentPosition <$> askGame

askCurrentPlayer :: PokerSTM Player
askCurrentPlayer = G.currentPlayer <$> askGame

isCurrentPlayer :: PokerSTM Bool
isCurrentPlayer = do
  p <- askPlayer
  cp <- askCurrentPlayer
  return $ p == cp

askCurrentPot :: PokerSTM Money
askCurrentPot = maximum . map playerPot <$> askPlayers

askLastRaise :: PokerSTM (Maybe ((Position, UserName), Money))
askLastRaise = lastRaise <$> askGame

askToCall :: Player -> PokerSTM Money
askToCall pl = do
  pot <- askCurrentPot
  return $ pot - playerPot pl

askCurrentOrder :: PokerSTM [Player]
askCurrentOrder = toOrder <$> askGame
  where
    toOrder g@Game {currentPosition, players} =
      let (a, b) = L.splitAt currentPosition players
       in mapMaybe (`G.findPlayer` g) (b ++ a)

askFirstPosition :: PokerSTM Player
askFirstPosition = (\g -> fromJust . (`G.findPlayer` g) . (!! 0) $ players g) <$> askGame