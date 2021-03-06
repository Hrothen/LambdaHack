{-# LANGUAGE RankNTypes #-}
-- | Running and disturbance.
--
-- The general rule is: whatever is behind you (and so ignored previously),
-- determines what you ignore moving forward. This is calcaulated
-- separately for the tiles to the left, to the right and in the middle
-- along the running direction. So, if you want to ignore something
-- start running when you stand on it (or to the right or left, respectively)
-- or by entering it (or passing to the right or left, respectively).
--
-- Some things are never ignored, such as: enemies seen, imporant messages
-- heard, solid tiles and actors in the way.
module Game.LambdaHack.Client.UI.RunM
  ( continueRun
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , continueRunDir, enterableDir, tryTurning, checkAndRun
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.EnumMap.Strict as EM

import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.Request
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.Msg
import           Game.LambdaHack.Client.UI.Overlay
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Types
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Core.Point
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.TileKind as TK

-- | Continue running in the given direction.
continueRun :: MonadClientUI m
            => LevelId -> RunParams
            -> m (Either Text RequestTimed)
continueRun arena paramOld = case paramOld of
  RunParams{ runMembers = []
           , runStopMsg = Just stopMsg } -> return $ Left stopMsg
  RunParams{ runMembers = []
           , runStopMsg = Nothing } ->
    return $ Left "selected actors no longer there"
  RunParams{ runLeader
           , runMembers = r : rs
           , runInitial
           , runStopMsg } -> do
    -- If runInitial and r == runLeader, it means the leader moves
    -- again, after all other members, in step 0,
    -- so we call continueRunDir with True to change direction once
    -- and then unset runInitial.
    let runInitialNew = runInitial && r /= runLeader
        paramIni = paramOld {runInitial = runInitialNew}
    onLevel <- getsState $ memActor r arena
    onLevelLeader <- getsState $ memActor runLeader arena
    if | not onLevel -> do
         let paramNew = paramIni {runMembers = rs }
         continueRun arena paramNew
       | not onLevelLeader -> do
         let paramNew = paramIni {runLeader = r}
         continueRun arena paramNew
       | otherwise -> do
         mdirOrRunStopMsgCurrent <- continueRunDir paramOld
         let runStopMsgCurrent =
               either Just (const Nothing) mdirOrRunStopMsgCurrent
             runStopMsgNew = runStopMsg `mplus` runStopMsgCurrent
             -- We check @runStopMsgNew@, because even if the current actor
             -- runs OK, we want to stop soon if some others had to stop.
             runMembersNew = if isJust runStopMsgNew then rs else rs ++ [r]
             paramNew = paramIni { runMembers = runMembersNew
                                 , runStopMsg = runStopMsgNew }
         case mdirOrRunStopMsgCurrent of
           Left _ -> continueRun arena paramNew
                       -- run all others undisturbed; one time
           Right dir -> do
             updateClientLeader r
             modifySession $ \sess -> sess {srunning = Just paramNew}
             return $ Right $ ReqMove dir
         -- The potential invisible actor is hit. War is started without asking.

-- | This function implements the actual logic of running. It checks if we
-- have to stop running because something interesting cropped up,
-- it ajusts the direction given by the vector if we reached
-- a corridor's corner (we never change direction except in corridors)
-- and it increments the counter of traversed tiles.
--
-- Note that while goto-xhair commands ignore items on the way,
-- here we stop wnenever we touch an item. Running is more cautious
-- to compensate that the player cannot specify the end-point of running.
-- It's also more suited to open, already explored terrain. Goto-xhair
-- works better with unknown terrain, e.g., it stops whenever an item
-- is spotted, but then ignores the item, leaving it to the player
-- to mark the item position as a goal of the next goto.
continueRunDir :: MonadClientUI m
               => RunParams -> m (Either Text Vector)
continueRunDir params = case params of
  RunParams{ runMembers = [] } -> error $ "" `showFailure` params
  RunParams{ runLeader
           , runMembers = aid : _
           , runInitial } -> do
    report <- getsSession $ newReport . shistory
    let boringMsgs = map stringToAL
          [ "You hear a distant"
          , "You hear distant"
          , "You overhear"
          , "You move with difficulty."
          , "You move swiftly."
          , "walk over"
          , "reveals that the"
          , "Macro will be recorded"
          , "Macro activated"
          , "Voicing '" ]
        boring l = any (`isInfixOf` l) boringMsgs
        msgShown = isJust $ findInReport (not . boring) report
    if msgShown then return $ Left "message shown"
    else do
      cops@COps{cotile} <- getsState scops
      rbody <- getsState $ getActorBody runLeader
      let rposHere = bpos rbody
          rposLast = fromMaybe (error $ "" `showFailure` (runLeader, rbody))
                               (boldpos rbody)
          -- Match run-leader dir, because we want runners to keep formation.
          dir = rposHere `vectorToFrom` rposLast
      body <- getsState $ getActorBody aid
      let lid = blid body
      lvl <- getLevel lid
      let posHere = bpos body
          posThere = posHere `shift` dir
          bigActorThere = occupiedBigLvl posThere lvl
          projsThere = occupiedProjLvl posThere lvl
      let openableLast = Tile.isOpenable cotile (lvl `at` (posHere `shift` dir))
          check
            | bigActorThere = return $ Left "actor in the way"
            | projsThere = return $ Left "projectile in the way"
                -- don't displace actors, except with leader in step 0
            | enterableDir cops lvl posHere dir =
                if runInitial && aid /= runLeader
                then return $ Right dir  -- zeroth step always OK
                else checkAndRun aid dir
            | not (runInitial && aid == runLeader) = return $ Left "blocked"
                -- don't change direction, except in step 1 and by run-leader
            | openableLast = return $ Left "blocked by a closed door"
                -- the player may prefer to open the door
            | otherwise =
                -- Assume turning is permitted, because this is the start
                -- of the run, so the situation is mostly known to the player
                tryTurning aid
      check

enterableDir :: COps -> Level -> Point -> Vector -> Bool
enterableDir COps{coTileSpeedup} lvl spos dir =
  Tile.isWalkable coTileSpeedup $ lvl `at` (spos `shift` dir)

tryTurning :: MonadClientRead m
           => ActorId -> m (Either Text Vector)
tryTurning aid = do
  cops@COps{cotile} <- getsState scops
  body <- getsState $ getActorBody aid
  let lid = blid body
  lvl <- getLevel lid
  let posHere = bpos body
      posLast = fromMaybe (error $ "" `showFailure` (aid, body)) (boldpos body)
      dirLast = posHere `vectorToFrom` posLast
  let openableDir dir = Tile.isOpenable cotile (lvl `at` (posHere `shift` dir))
      dirEnterable dir = enterableDir cops lvl posHere dir || openableDir dir
      dirNearby dir1 dir2 = euclidDistSqVector dir1 dir2 `elem` [1, 2]
      dirSimilar dir = dirNearby dirLast dir && dirEnterable dir
      dirsSimilar = filter dirSimilar moves
  case dirsSimilar of
    [] -> return $ Left "dead end"
    d1 : ds | all (dirNearby d1) ds ->  -- only one or two directions possible
      case sortOn (euclidDistSqVector dirLast)
           $ filter (enterableDir cops lvl posHere) $ d1 : ds of
        [] ->
          return $ Left "blocked and all similar directions are closed doors"
        d : _ -> checkAndRun aid d
    _ -> return $ Left "blocked and many distant similar directions found"

-- The direction is different than the original, if called from @tryTurning@
-- and the same if from @continueRunDir@.
checkAndRun :: MonadClientRead m
            => ActorId -> Vector -> m (Either Text Vector)
checkAndRun aid dir = do
  COps{cotile} <- getsState scops
  body <- getsState $ getActorBody aid
  smarkSuspect <- getsClient smarkSuspect
  let lid = blid body
  lvl <- getLevel lid
  let posHere = bpos body
      posHasItems pos = EM.member pos $ lfloor lvl
      posThere = posHere `shift` dir
      bigActorThere = occupiedBigLvl posThere lvl
      projsThere = occupiedProjLvl posThere lvl
  let posLast = fromMaybe (error $ "" `showFailure` (aid, body)) (boldpos body)
      dirLast = posHere `vectorToFrom` posLast
      -- This is supposed to work on unit vectors --- diagonal, as well as,
      -- vertical and horizontal.
      anglePos :: Point -> Vector -> RadianAngle -> Point
      anglePos pos d angle = shift pos (rotate angle d)
      -- We assume the tiles have not changed since last running step.
      -- If they did, we don't care --- running should be stopped
      -- because of the change of nearby tiles then.
      -- We don't take into account the two tiles at the rear of last
      -- surroundings, because the actor may have come from there
      -- (via a diagonal move) and if so, he may be interested in such tiles.
      -- If he arrived directly from the right or left, he is responsible
      -- for starting the run further away, if he does not want to ignore
      -- such tiles as the ones he came from.
      tileLast = lvl `at` posLast
      tileHere = lvl `at` posHere
      tileThere = lvl `at` posThere
      leftPsLast = map (anglePos posHere dirLast) [pi/2, 3*pi/4]
                   ++ map (anglePos posHere dir) [pi/2, 3*pi/4]
      rightPsLast = map (anglePos posHere dirLast) [-pi/2, -3*pi/4]
                    ++ map (anglePos posHere dir) [-pi/2, -3*pi/4]
      leftForwardPosHere = anglePos posHere dir (pi/4)
      rightForwardPosHere = anglePos posHere dir (-pi/4)
      leftTilesLast = map (lvl `at`) leftPsLast
      rightTilesLast = map (lvl `at`) rightPsLast
      leftForwardTileHere = lvl `at` leftForwardPosHere
      rightForwardTileHere = lvl `at` rightForwardPosHere
      featAt = TK.actionFeatures (smarkSuspect > 0) . okind cotile
      terrainChangeMiddle =
        featAt tileThere `notElem` map featAt [tileLast, tileHere]
      terrainChangeLeft = featAt leftForwardTileHere
                          `notElem` map featAt leftTilesLast
      terrainChangeRight = featAt rightForwardTileHere
                           `notElem` map featAt rightTilesLast
      itemChangeLeft = posHasItems leftForwardPosHere
                       `notElem` map posHasItems leftPsLast
      itemChangeRight = posHasItems rightForwardPosHere
                        `notElem` map posHasItems rightPsLast
      check
        | bigActorThere = return $ Left "actor in the way"
        | projsThere = return $ Left "projectile in the way"
            -- Actor in possibly another direction tnan original.
            -- (e.g., called from @tryTurning@).
        | terrainChangeLeft = return $ Left "terrain change on the left"
        | terrainChangeRight = return $ Left "terrain change on the right"
        | itemChangeLeft = return $ Left "item change on the left"
        | itemChangeRight = return $ Left "item change on the right"
        | terrainChangeMiddle = return $ Left "terrain change in the middle"
        | otherwise = return $ Right dir
  check
