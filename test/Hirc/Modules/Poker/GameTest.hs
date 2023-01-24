module Hirc.Modules.Poker.GameTest (pokerGameSpec) where

import Control.Monad.IO.Class
import Test.Hspec
import Test.Hspec.Expectations
import System.Random

import Hirc
import Hirc.Modules.Poker.Game
import Control.Exception (throw)
import Data.Either (fromRight, fromLeft, isRight, isLeft)
import Hirc.Modules.Poker.Bank (Money)
import System.Random (StdGen)
import Data.Maybe (isJust)
import Hirc.Modules.Poker.Game (Game(communityCards))

newPlayer' n = newPlayer n n 10000

-- First 4 players
p1 = newPlayer' "p1"
p2 = newPlayer' "p2"
p3 = newPlayer' "p3"
p4 = newPlayer' "p4"

-- Continue playing
cont :: Show a => (Game a -> GameUpdate a) -> Game a -> Game a
cont f g = fromLeft (error $ "Unexpected end of game: " ++ show (f g)) (f g)

check' :: Show a => Game a -> Game a
check' = cont check

call' :: Show a => Game a -> Game a
call' = cont call

fold' :: Show a => Game a -> Game a
fold' = cont fold

raise' :: Show a => Money -> Game a -> Game a
raise' x = cont $ raise x

-- Default starting game
g0, g1, g2, g3, g4 :: Game StdGen

-- new game
g0 = joinPlayer p4
   $ joinPlayer p3
   $ joinPlayer p2
   $ joinPlayer p1
   $ newGame (mkStdGen 42)

-- game pre flop
g1 = payBlinds $ dealCards g0

-- flop game
g2 = check' $ call' $ call' $ call' g1

-- turn game
g3 = check' $ check' $ check' $ check' g2

-- river game
g4 = check' $ check' $ check' $ check' g3

g5 :: GameUpdate StdGen

-- end game result
g5 = check . check' . check' $ check' g4

pokerGameSpec :: Spec
pokerGameSpec = do

  describe "test game setups" $ do
    it "should have the right community cards" $ do
      communityCards g0 `shouldBe` PreFlop
      communityCards g1 `shouldBe` PreFlop
      communityCards g2 `shouldSatisfy` \(Flop _) -> True
      communityCards g3 `shouldSatisfy` \(Turn _) -> True
      communityCards g4 `shouldSatisfy` \(River _) -> True
      g5 `shouldSatisfy` isRight

  describe "join and part" $ do

    it "should reset player pots and hand" $ do
      let p = (newPlayer' "p5") { playerPot = 1000 }
          g = joinPlayer p g0
          l = last $ players g
      l `shouldNotBe` p
      playerUsername l `shouldBe` playerUsername p
      playerPot l `shouldBe` 0
      playerHand l `shouldBe` Nothing

    it "should remove the correct player only" $ do
      players (partPlayer p2 g0) `shouldBe` [p1, p3, p4]

  checkSpec
  foldSpec

checkSpec :: Spec
checkSpec = do
  return ()

foldSpec :: Spec
foldSpec = describe "fold" $ do
  it "should keep pot size constant" $ do
    totalPotSize (fold' g0) `shouldBe` totalPotSize g0
    totalPotSize (fold' g1) `shouldBe` totalPotSize g1
    totalPotSize (fold' g2) `shouldBe` totalPotSize g2

  it "should end the game if the last player folds" $ do
    (fold . fold' . fold' $ g1) `shouldSatisfy` isRight

  it "should update last raise position correctly" $ do

    -- setup raise on 3rd position
    let g = raise' 500 . check' $ check' g2
    currentPosition g `shouldBe` 3
    communityCards g `shouldSatisfy` \(Flop _) -> True

    -- raise was done in 3rd position (counting from 0)
    lastRaise g `shouldBe` Just (2,500)

    -- fold in last position
    let g'1 = fold' g
    currentPosition g'1 `shouldBe` 0
    lastRaise g'1 `shouldBe` Just (2,500)

    -- fold in first position
    let g'2 = fold' $ call' g
    currentPosition g'2 `shouldBe` 0
    lastRaise g'2 `shouldBe` Just (1,500)

    ---------------------------------------------------------
    -- perform fold in position of last raise (in next phase)
    --

    -- make all players call and go into turn
    let g'3 = call' . call' . call' $ g
    currentPosition g'3 `shouldBe` 2
    communityCards g'3 `shouldSatisfy` \(Turn _) -> True

    -- perform the fold
    let g'4 = fold' g'3
    currentPosition g'4 `shouldBe` 2
    lastRaise g'4 `shouldBe` Just (2,500)
    -- it should not switch phase yet
    communityCards g'4 `shouldSatisfy` \(Turn _) -> True

    -- -- make all remaining players check until next phase
    -- let g'5 = check' . check' . check' $ g'4
    -- currentPosition g'5 `shouldBe` 2
    -- communityCards g'5 `shouldSatisfy` \(River _) -> True