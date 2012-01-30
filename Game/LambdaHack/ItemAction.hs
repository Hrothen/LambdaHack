-- | Item UI code with the 'Action' type and everything it depends on
-- that is not already in Action.hs and EffectAction.hs.
-- This file should not depend on Actions.hs.
-- TODO: Add an export list and document after it's rewritten according to #17.
module Game.LambdaHack.ItemAction where

import Control.Monad
import Control.Monad.State hiding (State, state)
import qualified Data.List as L
import qualified Data.IntMap as IM
import Data.Maybe
import qualified Data.IntSet as IS

import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Action
import Game.LambdaHack.Point
import Game.LambdaHack.Grammar
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Key as K
import Game.LambdaHack.Level
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Perception
import Game.LambdaHack.State
import Game.LambdaHack.EffectAction
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Content.ItemKind
import qualified Game.LambdaHack.Feature as F
import qualified Game.LambdaHack.Tile as Tile

-- | Display inventory
inventory :: Action a
inventory = do
  items <- gets getPlayerItem
  if L.null items
    then abortWith "Not carrying anything."
    else do
      displayItems "Carrying:" True items
      session getConfirm
      abortWith ""

-- | Let the player choose any item with a given group name.
-- Note that this does not guarantee the chosen item belongs to the group,
-- as the player can override the choice.
getGroupItem :: [Item]  -- ^ all objects in question
             -> Object  -- ^ name of the group
             -> [Char]  -- ^ accepted item symbols
             -> String  -- ^ prompt
             -> String  -- ^ how to refer to the collection of objects
             -> Action (Maybe Item)
getGroupItem is object syms prompt packName = do
  Kind.Ops{osymbol} <- contentf Kind.coitem
  let choice i = osymbol (jkind i) `elem` syms
      header = capitalize $ suffixS object
  getItem prompt choice header is packName

applyGroupItem :: ActorId  -- ^ actor applying the item (is on current level)
               -> Verb     -- ^ how the applying is called
               -> Item     -- ^ the item to be applied
               -> Action ()
applyGroupItem actor verb item = do
  cops  <- contentOps
  state <- get
  body  <- gets (getActor actor)
  per   <- currentPerception
  -- only one item consumed, even if several in inventory
  let consumed = item { jcount = 1 }
      msg = actorVerbItemExtra cops state body verb consumed ""
      loc = bloc body
  removeFromInventory actor consumed loc
  when (loc `IS.member` totalVisible per) $ msgAdd msg
  itemEffectAction 5 actor actor consumed
  advanceTime actor

playerApplyGroupItem :: Verb -> Object -> [Char] -> Action ()
playerApplyGroupItem verb object syms = do
  Kind.Ops{okind} <- contentf Kind.coitem
  is   <- gets getPlayerItem
  iOpt <- getGroupItem is object syms
            ("What to " ++ verb ++ "?") "in inventory"
  pl   <- gets splayer
  case iOpt of
    Just i  -> applyGroupItem pl (iverbApply $ okind $ jkind i) i
    Nothing -> neverMind True

projectGroupItem :: ActorId  -- ^ actor projecting the item (is on current lvl)
                 -> Point    -- ^ target location for the projecting
                 -> Verb     -- ^ how the projecting is called
                 -> Item     -- ^ the item to be projected
                 -> Action ()
projectGroupItem source loc verb item = do
  cops@Kind.COps{coactor, cotile} <- contentOps
  state <- get
  sm    <- gets (getActor source)
  per   <- currentPerception
  lvl   <- gets slevel
  let -- TODO: refine for, e.g., wands of digging that are aimed into walls.
      locWalkable = Tile.hasFeature cotile F.Walkable (lvl `at` loc)
      consumed = item { jcount = 1 }
      sloc = bloc sm
      subject =
        if sloc `IS.member` totalVisible per
        then sm
        else template (heroKindId coactor)
               Nothing (Just "somebody") 99 sloc
      msg = actorVerbItemExtra cops state subject verb consumed ""
  removeFromInventory source consumed sloc
  case locToActor loc state of
    Just ta -> do
      -- The msg describes the source part of the action.
      when (sloc `IS.member` totalVisible per || isAHero ta) $ msgAdd msg
      -- Msgs inside itemEffectAction describe the target part.
      b <- itemEffectAction 10 source ta consumed
      unless b $ modify (updateLevel (dropItemsAt [consumed] loc))
    Nothing | locWalkable -> do
      when (sloc `IS.member` totalVisible per) $ msgAdd msg
      modify (updateLevel (dropItemsAt [consumed] loc))
    _ -> abortWith "blocked"
  advanceTime source

playerProjectGroupItem :: Verb -> Object -> [Char] -> Action ()
playerProjectGroupItem verb object syms = do
  ms     <- gets (lmonsters . slevel)
  lxsize <- gets (lxsize . slevel)
  ploc   <- gets (bloc . getPlayerBody)
  if L.any (adjacent lxsize ploc) (L.map bloc $ IM.elems ms)
    then abortWith "You can't aim in melee."
    else playerProjectGI verb object syms

playerProjectGI :: Verb -> Object -> [Char] -> Action ()
playerProjectGI verb object syms = do
  state <- get
  pl    <- gets splayer
  ploc  <- gets (bloc . getPlayerBody)
  per   <- currentPerception
  let retarget msg = do
        msgAdd msg
        updatePlayerBody (\ p -> p { btarget = TCursor })
        let upd cursor = cursor {clocation=ploc}
        modify (updateCursor upd)
        targetMonster TgtAuto
  -- TODO: draw digital line and see if obstacles prevent firing
  -- TODO: don't tell the player if the tiles he can't see are reachable,
  -- but let him throw there and let them land closer, if not reachable
  -- TODO: similarly let him throw at walls and land in front (digital line)
  case targetToLoc (totalVisible per) state of
    Just loc | actorReachesLoc pl loc per (Just pl) -> do
      Kind.Ops{okind} <- contentf Kind.coitem
      is   <- gets getPlayerItem
      iOpt <- getGroupItem is object syms
                ("What to " ++ verb ++ "?") "in inventory"
      targeting <- gets (ctargeting . scursor)
      when (targeting == TgtAuto) $ endTargeting True
      case iOpt of
        Just i -> projectGroupItem pl loc (iverbProject $ okind $ jkind i) i
        Nothing -> neverMind True
    Just _  -> retarget "Last target unreachable."
    Nothing -> retarget "Last target invalid."

-- TODO: also target a monster by moving the cursor, if in target monster mode.
-- TODO: sort monsters by distance to the player.

-- | Start the monster targeting mode. Cycle between monster targets.
targetMonster :: TgtMode -> Action ()
targetMonster tgtMode = do
  pl        <- gets splayer
  ms        <- gets (lmonsters . slevel)
  per       <- currentPerception
  target    <- gets (btarget . getPlayerBody)
  targeting <- gets (ctargeting . scursor)
  let i = case target of
            TEnemy (AMonster n) _ | targeting /= TgtOff -> n  -- next monster
            TEnemy (AMonster n) _ -> n - 1  -- try to retarget old monster
            _ -> -1  -- try to target first monster (e.g., number 0)
      dms = case pl of
              AMonster n -> IM.delete n ms  -- don't target yourself
              AHero _ -> ms
      (lt, gt) = IM.split i dms
      gtlt     = IM.assocs gt ++ IM.assocs lt
      seen (_, m) =
        let mloc = bloc m
        in mloc `IS.member` totalVisible per         -- visible by any
           && actorReachesLoc pl mloc per (Just pl)  -- reachable by player
      lf = L.filter seen gtlt
      tgt = case lf of
              [] -> target  -- no monsters in sight, stick to last target
              (na, nm) : _ -> TEnemy (AMonster na) (bloc nm)  -- pick the next
  updatePlayerBody (\ p -> p { btarget = tgt })
  setCursor tgtMode

-- | Start the floor targeting mode or reset the cursor location to the player.
targetFloor :: TgtMode -> Action ()
targetFloor tgtMode = do
  ploc      <- gets (bloc . getPlayerBody)
  target    <- gets (btarget . getPlayerBody)
  targeting <- gets (ctargeting . scursor)
  let tgt = case target of
        _ | targeting /= TgtOff -> TLoc ploc  -- double key press: reset cursor
        TEnemy _ _ -> TCursor  -- forget enemy target, keep the cursor
        t -> t  -- keep the target from previous targeting session
  updatePlayerBody (\ p -> p { btarget = tgt })
  setCursor tgtMode

-- | Set, activate and display cursor information.
setCursor :: TgtMode -> Action ()
setCursor tgtMode = assert (tgtMode /= TgtOff) $ do
  state  <- get
  per    <- currentPerception
  ploc   <- gets (bloc . getPlayerBody)
  clocLn <- gets slid
  let upd cursor =
        let clocation = fromMaybe ploc (targetToLoc (totalVisible per) state)
        in cursor { ctargeting = tgtMode, clocation, clocLn }
  modify (updateCursor upd)
  doLook

-- | End targeting mode, accepting the current location or not.
endTargeting :: Bool -> Action ()
endTargeting accept = do
  returnLn <- gets (creturnLn . scursor)
  target   <- gets (btarget . getPlayerBody)
  cloc     <- gets (clocation . scursor)
  -- return to the original level of the player
  modify (\ state -> state {slid = returnLn})
  modify (updateCursor (\ c -> c { ctargeting = TgtOff }))
  let isEnemy = case target of TEnemy _ _ -> True ; _ -> False
  unless isEnemy $
    if accept
       then updatePlayerBody (\ p -> p { btarget = TLoc cloc })
       else updatePlayerBody (\ p -> p { btarget = TCursor })
  endTargetingMsg

endTargetingMsg :: Action ()
endTargetingMsg = do
  cops   <- contentf Kind.coactor
  pbody  <- gets getPlayerBody
  state  <- get
  lxsize <- gets (lxsize . slevel)
  let verb = "target"
      targetMsg = case btarget pbody of
                    TEnemy a _ll ->
                      if memActor a state
                      then objectActor cops $ getActor a state
                      else "a fear of the past"
                    TLoc loc -> "location " ++ showPoint lxsize loc
                    TCursor  -> "current cursor position continuously"
  msgAdd $ actorVerbExtra cops pbody verb targetMsg

-- | Cancel something, e.g., targeting mode, resetting the cursor
-- to the position of the player. Chosen target is not invalidated.
cancelCurrent :: Action ()
cancelCurrent = do
  targeting <- gets (ctargeting . scursor)
  if targeting /= TgtOff
    then endTargeting False
    else abortWith "Press Q to quit."

-- | Accept something, e.g., targeting mode, keeping cursor where it was.
-- Or perform the default action, if nothing needs accepting.
acceptCurrent :: Action () -> Action ()
acceptCurrent h = do
  targeting <- gets (ctargeting . scursor)
  if targeting /= TgtOff
    then endTargeting True
    else h  -- nothing to accept right now

-- | Drop a single item.
dropItem :: Action ()
dropItem = do
  -- TODO: allow dropping a given number of identical items.
  cops  <- contentOps
  pl    <- gets splayer
  state <- get
  pbody <- gets getPlayerBody
  ploc  <- gets (bloc . getPlayerBody)
  items <- gets getPlayerItem
  iOpt  <- getAnyItem "What to drop?" items "inventory"
  case iOpt of
    Just stack -> do
      let i = stack { jcount = 1 }
      removeOnlyFromInventory pl i (bloc pbody)
      msgAdd (actorVerbItemExtra cops state pbody "drop" i "")
      modify (updateLevel (dropItemsAt [i] ploc))
    Nothing -> neverMind True
  playerAdvanceTime

-- TODO: this is a hack for dropItem, because removeFromInventory
-- makes it impossible to drop items if the floor not empty.
removeOnlyFromInventory :: ActorId -> Item -> Point -> Action ()
removeOnlyFromInventory actor i _loc =
  modify (updateAnyActorItem actor (removeItemByLetter i))

-- | Remove given item from an actor's inventory or floor.
-- TODO: this is subtly wrong: if identical items are on the floor and in
-- inventory, the floor one will be chosen, regardless of player intention.
-- TODO: right now it ugly hacks (with the ploc) around removing items
-- of dead heros/monsters. The subtle incorrectness helps here a lot,
-- because items of dead heroes land on the floor, so we use them up
-- in inventory, but remove them after use from the floor.
removeFromInventory :: ActorId -> Item -> Point -> Action ()
removeFromInventory actor i loc = do
  b <- removeFromLoc i loc
  unless b $
    modify (updateAnyActorItem actor (removeItemByLetter i))

-- | Remove given item from the given location. Tell if successful.
removeFromLoc :: Item -> Point -> Action Bool
removeFromLoc i loc = do
  lvl <- gets slevel
  if not $ L.any (equalItemIdentity i) (lvl `atI` loc)
    then return False
    else
      modify (updateLevel (updateIMap adj)) >>
      return True
     where
      rib Nothing = assert `failure` (i, loc)
      rib (Just (is, irs)) =
        case (removeItemByIdentity i is, irs) of
          ([], []) -> Nothing
          iss -> Just iss
      adj = IM.alter rib loc

actorPickupItem :: ActorId -> Action ()
actorPickupItem actor = do
  cops@Kind.COps{coitem} <- contentOps
  state <- get
  pl    <- gets splayer
  per   <- currentPerception
  lvl   <- gets slevel
  body  <- gets (getActor actor)
  bitems <- gets (getActorItem actor)
  let loc       = bloc body
      perceived = loc `IS.member` totalVisible per
      isPlayer  = actor == pl
  -- check if something is here to pick up
  case lvl `atI` loc of
    []   -> abortIfWith isPlayer "nothing here"
    i:is -> -- pick up first item; TODO: let player select item; not for monsters
      case assignLetter (jletter i) (bletter body) bitems of
        Just l -> do
          let (ni, nitems) = joinItem (i { jletter = Just l }) bitems
          -- msg depends on who picks up and if a hero can perceive it
          if isPlayer
            then msgAdd (letterLabel (jletter ni)
                             ++ objectItem coitem state ni)
            else when perceived $
                   msgAdd $
                   actorVerbExtraItemExtra cops state body "pick" "up" i ""
          removeFromLoc i loc
            >>= assert `trueM` (i, is, loc, "item is stuck")
          -- add item to actor's inventory:
          updateAnyActor actor $ \ m ->
            m { bletter = maxLetter l (bletter body) }
          modify (updateAnyActorItem actor (const nitems))
        Nothing -> abortIfWith isPlayer "cannot carry any more"
  advanceTime actor

pickupItem :: Action ()
pickupItem = do
  pl <- gets splayer
  actorPickupItem pl

-- TODO: I think that player handlers should be wrappers
-- around more general actor handlers, but
-- the actor handlers should be performing
-- specific actions, i.e., already specify the item to be
-- picked up. It doesn't make sense to invoke dialogues
-- for arbitrary actors, and most likely the
-- decision for a monster is based on perceiving
-- a particular item to be present, so it's already
-- known. In actor handlers we should make sure
-- that messages are printed to the player only if the
-- hero can perceive the action.
-- Perhaps this means half of this code should be split and moved
-- to ItemState, to be independent of any IO code from Action/Display. Actually, not, since the message display depends on Display. Unless we return a string to be displayed.

-- TODO: you can drop an item already the floor, which works correctly,
-- but is weird and useless.

-- | Let the player choose any item from a list of items.
getAnyItem :: String  -- ^ prompt
           -> [Item]  -- ^ all items in question
           -> String  -- ^ how to refer to the collection of items
           -> Action (Maybe Item)
getAnyItem prompt = getItem prompt (const True) "Objects"

-- | Let the player choose a single, preferably suitable,
-- item from a list of items.
getItem :: String               -- ^ prompt message
        -> (Item -> Bool)       -- ^ which items to consider suitable
        -> String               -- ^ how to describe suitable items
        -> [Item]               -- ^ all items in question
        -> String               -- ^ how to refer to the collection of items
        -> Action (Maybe Item)
getItem prompt p ptext is0 isn = do
  lvl  <- gets slevel
  body <- gets getPlayerBody
  let loc = bloc body
      tis = lvl `atI` loc
      floorMsg = if L.null tis then "" else " -,"
      is = L.filter p is0
      choice = if L.null is
               then "[*," ++ floorMsg ++ " ESC]"
               else let r = letterRange $ mapMaybe jletter is
                    in  "[" ++ r ++ ", ?, *," ++ floorMsg ++ " RET, ESC]"
      ask = do
        when (L.null is0 && L.null tis) $
          abortWith "Not carrying anything."
        msgReset (prompt ++ " " ++ choice)
        displayAll
        session nextCommand >>= perform
      perform command = do
        msgClear
        case command of
          K.Char '?' -> do
            -- filter for supposedly suitable items
            b <- displayItems (ptext ++ " " ++ isn) True is
            if b then session (getOptionalConfirm (const ask) perform)
                 else ask
          K.Char '*' -> do
            -- show all items
            b <- displayItems ("Objects " ++ isn) True is0
            if b then session (getOptionalConfirm (const ask) perform)
                 else ask
          K.Char '-' ->
            case tis of
              []   -> return Nothing
              i:_rs -> -- use first item; TODO: let player select item
                      return $ Just i
          K.Char l   ->
            return (L.find (maybe False (== l) . jletter) is0)
          K.Return   ->  -- TODO: it should be the first displayed (except $)
            return (case is of [] -> Nothing ; i : _ -> Just i)
          _          -> return Nothing
  ask
