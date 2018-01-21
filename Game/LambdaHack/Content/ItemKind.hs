{-# LANGUAGE DeriveGeneric #-}
-- | The type of kinds of weapons, treasure, organs, blasts, etc.
module Game.LambdaHack.Content.ItemKind
  ( ItemKind(..), makeData
  , Effect(..), TimerDice
  , Aspect(..), ThrowMod(..)
  , Feature(..), EqpSlot(..)
  , AspectRecord(..), KindMean(..)
  , ItemSpeedup, emptyItemSpeedup, getKindMean, speedupItem
  , emptyAspectRecord, castAspect, aspectsRandom, meanAspect
  , boostItemKindList, forApplyEffect, forIdEffect
  , toDmg, tmpNoLonger, tmpLess, toVelocity, toLinger
  , timerNone, isTimerNone, foldTimer
  , toOrganGameTurn, toOrganActorTurn, toOrganNone
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , ceilingMeanDice, addMeanAspect, validateSingle, validateAll
  , boostItemKind, validateDups, validateDamage, hardwiredItemGroups
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.DeepSeq
import qualified Control.Monad.Trans.State.Strict as St
import           Data.Binary
import qualified Data.EnumMap.Strict as EM
import           Data.Hashable (Hashable)
import qualified Data.Text as T
import qualified Data.Vector as V
import           GHC.Generics (Generic)
import qualified NLP.Miniutter.English as MU
import qualified System.Random as R

import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.ContentData
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Common.Flavour
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.Random

-- | Item properties that are fixed for a given kind of items.
data ItemKind = ItemKind
  { isymbol  :: Char                -- ^ map symbol
  , iname    :: Text                -- ^ generic name
  , ifreq    :: Freqs ItemKind      -- ^ frequency within groups
  , iflavour :: [Flavour]           -- ^ possible flavours
  , icount   :: Dice.Dice           -- ^ created in that quantity
  , irarity  :: Rarity              -- ^ rarity on given depths
  , iverbHit :: MU.Part             -- ^ the verb&noun for applying and hit
  , iweight  :: Int                 -- ^ weight in grams
  , idamage  :: [(Int, Dice.Dice)]  -- ^ frequency of basic impact damage
  , iaspects :: [Aspect]            -- ^ keep the aspect continuously
  , ieffects :: [Effect]            -- ^ cause the effect when triggered
  , ifeature :: [Feature]           -- ^ public properties
  , idesc    :: Text                -- ^ description
  , ikit     :: [(GroupName ItemKind, CStore)]
                                    -- ^ accompanying organs and items
  }
  deriving (Show, Generic)  -- No Eq and Ord to make extending logically sound

-- | Effects of items. Can be invoked by the item wielder to affect
-- another actor or the wielder himself. Many occurences in the same item
-- are possible.
data Effect =
    ELabel Text        -- ^ secret (learned as effect) name of the item
  | EqpSlot EqpSlot    -- ^ AI and UI flag that leaks item properties
  | Burn Dice.Dice     -- ^ burn with this damage
  | Explode (GroupName ItemKind)
      -- ^ explode producing this group of blasts
  | RefillHP Int       -- ^ modify HP of the actor by this amount
  | RefillCalm Int     -- ^ modify Calm of the actor by this amount
  | Dominate           -- ^ change actor's allegiance
  | Impress            -- ^ make actor susceptible to domination
  | Summon (GroupName ItemKind) Dice.Dice
      -- ^ summon the given number of actors of this group
  | Ascend Bool           -- ^ ascend to another level of the dungeon
  | Escape                -- ^ escape from the dungeon
  | Paralyze Dice.Dice    -- ^ paralyze for this many game clips
  | InsertMove Dice.Dice  -- ^ give free time to actor of this many actor turns
  | Teleport Dice.Dice    -- ^ teleport actor across rougly this distance
  | CreateItem CStore (GroupName ItemKind) TimerDice
      -- ^ create an item of the group and insert into the store with the given
      --   random timer
  | DropItem Int Int CStore (GroupName ItemKind)
      -- ^ make the actor drop items of the given group from the given store;
      -- the first integer says how many item kinds to drop, the second,
      -- how many copie of each kind to drop
  | PolyItem
      -- ^ find a suitable (i.e., numerous enough) item, starting from
      -- the floor, and polymorph it randomly
  | Identify
      -- ^ find a suitable (i.e., not identified) item, starting from
      -- the floor, and identify it
  | Detect Int            -- ^ detect all on the map in the given radius
  | DetectActor Int       -- ^ detect actors on the map in the given radius
  | DetectItem Int        -- ^ detect items on the map in the given radius
  | DetectExit Int        -- ^ detect exits on the map in the given radius
  | DetectHidden Int      -- ^ detect hidden tiles on the map in the radius
  | SendFlying ThrowMod   -- ^ send an actor flying (push or pull, depending)
  | PushActor ThrowMod    -- ^ push an actor
  | PullActor ThrowMod    -- ^ pull an actor
  | DropBestWeapon        -- ^ make the actor drop its best weapon
  | ActivateInv Char
      -- ^ activate all items with this symbol in inventory; space character
      -- means all symbols
  | ApplyPerfume          -- ^ remove all smell on the level
  | OneOf [Effect]        -- ^ trigger one of the effects with equal probability
  | OnSmash Effect
      -- ^ trigger the effect when item smashed (not when applied nor meleed)
  | Recharging Effect  -- ^ this effect inactive until timeout passes
  | Temporary Text
      -- ^ the item is temporary, vanishes at even void Periodic activation,
      --   unless Durable and not Fragile, and shows message with
      --   this verb at last copy activation or at each activation
      --   unless Durable and Fragile
  | Unique              -- ^ at most one copy can ever be generated
  | Periodic
      -- ^ in equipment, triggered as often as @Timeout@ permits
  | Composite [Effect]  -- ^ only fire next effect if previous fully activated
  deriving (Show, Eq, Generic)

-- | Specification of how to randomly roll a timer at item creation
-- to obtain a fixed timer for the item's lifetime.
data TimerDice =
    TimerNone
  | TimerGameTurn Dice.Dice
  | TimerActorTurn Dice.Dice
  deriving (Eq, Generic)

instance Show TimerDice where
  show TimerNone = "0"
  show (TimerGameTurn nDm) =
    show nDm ++ " " ++ if nDm == 1 then "turn" else "turns"
  show (TimerActorTurn nDm) =
    show nDm ++ " " ++ if nDm == 1 then "move" else "moves"

-- | Aspects of items. Those that are named @Add*@ are additive
-- (starting at 0) for all items wielded by an actor and they affect the actor.
data Aspect =
    Timeout Dice.Dice         -- ^ some effects disabled until item recharges;
                              --   expressed in game turns
  | AddHurtMelee Dice.Dice    -- ^ percentage damage bonus in melee
  | AddArmorMelee Dice.Dice   -- ^ percentage armor bonus against melee
  | AddArmorRanged Dice.Dice  -- ^ percentage armor bonus against ranged
  | AddMaxHP Dice.Dice        -- ^ maximal hp
  | AddMaxCalm Dice.Dice      -- ^ maximal calm
  | AddSpeed Dice.Dice        -- ^ speed in m/10s (not when pushed or pulled)
  | AddSight Dice.Dice        -- ^ FOV radius, where 1 means a single tile FOV
  | AddSmell Dice.Dice        -- ^ smell radius
  | AddShine Dice.Dice        -- ^ shine radius
  | AddNocto Dice.Dice        -- ^ noctovision radius
  | AddAggression Dice.Dice   -- ^ aggression, e.g., when closing in for melee
  | AddAbility Ability.Ability Dice.Dice  -- ^ bonus to an ability
  deriving (Show, Eq, Ord, Generic)

-- | Parameters modifying a throw of a projectile or flight of pushed actor.
-- Not additive and don't start at 0.
data ThrowMod = ThrowMod
  { throwVelocity :: Int  -- ^ fly with this percentage of base throw speed
  , throwLinger   :: Int  -- ^ fly for this percentage of 2 turns
  }
  deriving (Show, Eq, Ord, Generic)

-- | Features of item. Publicly visible. Affect only the item in question,
-- not the actor, and so not additive in any sense.
data Feature =
    Fragile            -- ^ drop and break at target tile, even if no hit
  | Lobable            -- ^ drop at target tile, even if no hit
  | Durable            -- ^ don't break even when hitting or applying
  | ToThrow ThrowMod   -- ^ parameters modifying a throw
  | Identified         -- ^ the item starts identified
  | Applicable         -- ^ AI and UI flag: consider applying
  | Equipable          -- ^ AI and UI flag: consider equipping (independent of
                       --   'EqpSlot', e.g., in case of mixed blessings)
  | Meleeable          -- ^ AI and UI flag: consider meleeing with
  | Precious           -- ^ AI and UI flag: don't risk identifying by use;
                       --   also, can't throw or apply if not calm enough
  | Tactic Tactic      -- ^ overrides actor's tactic
  | Blast              -- ^ the items is an explosion blast particle
  deriving (Show, Eq, Ord, Generic)

-- | AI and UI hints about the role of the item.
data EqpSlot =
    EqpSlotMiscBonus
  | EqpSlotAddHurtMelee
  | EqpSlotAddArmorMelee
  | EqpSlotAddArmorRanged
  | EqpSlotAddMaxHP
  | EqpSlotAddSpeed
  | EqpSlotAddSight
  | EqpSlotLightSource
  | EqpSlotWeapon
  | EqpSlotMiscAbility
  | EqpSlotAbMove
  | EqpSlotAbMelee
  | EqpSlotAbDisplace
  | EqpSlotAbAlter
  | EqpSlotAbProject
  | EqpSlotAbApply
  -- Do not use in content:
  | EqpSlotAddMaxCalm
  | EqpSlotAddSmell
  | EqpSlotAddNocto
  | EqpSlotAddAggression
  | EqpSlotAbWait
  | EqpSlotAbMoveItem
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

-- | Record of sums of aspect values of an item, container, actor, etc.
data AspectRecord = AspectRecord
  { aTimeout     :: Int
  , aHurtMelee   :: Int
  , aArmorMelee  :: Int
  , aArmorRanged :: Int
  , aMaxHP       :: Int
  , aMaxCalm     :: Int
  , aSpeed       :: Int
  , aSight       :: Int
  , aSmell       :: Int
  , aShine       :: Int
  , aNocto       :: Int
  , aAggression  :: Int
  , aSkills      :: Ability.Skills
  }
  deriving (Show, Eq, Ord, Generic)

-- | Partial information about an item, deduced from its item kind.
-- These are assigned to each 'ItemKind'. The @kmConst@ flag says whether
-- the item's aspects are constant rather than random or dependent
-- on item creation dungeon level.
data KindMean = KindMean
  { kmConst :: Bool  -- ^ whether the item doesn't need second identification
  , kmMean  :: AspectRecord  -- ^ mean value of item's possible aspects
  }
  deriving (Show, Eq, Ord, Generic)

-- Significant portions of this map are unused and so intentially kept
-- unevaluated.
newtype ItemSpeedup = ItemSpeedup (V.Vector KindMean)
  deriving (Show, Eq, Generic)

emptyItemSpeedup :: ItemSpeedup
emptyItemSpeedup = ItemSpeedup V.empty

getKindMean :: ContentId ItemKind -> ItemSpeedup -> KindMean
getKindMean kindId (ItemSpeedup is) = is V.! fromEnum kindId

speedupItem :: ContentData ItemKind -> ItemSpeedup
speedupItem coitem =
  let f !kind =
        let kmMean = meanAspect kind
            kmConst = not $ aspectsRandom kind
        in KindMean{..}
  in ItemSpeedup $! omapVector f coitem

emptyAspectRecord :: AspectRecord
emptyAspectRecord = AspectRecord
  { aTimeout     = 0
  , aHurtMelee   = 0
  , aArmorMelee  = 0
  , aArmorRanged = 0
  , aMaxHP       = 0
  , aMaxCalm     = 0
  , aSpeed       = 0
  , aSight       = 0
  , aSmell       = 0
  , aShine       = 0
  , aNocto       = 0
  , aAggression  = 0
  , aSkills      = Ability.zeroSkills
  }

castAspect :: AbsDepth -> AbsDepth -> AspectRecord -> Aspect
           -> Rnd AspectRecord
castAspect !ldepth !totalDepth !ar !asp =
  case asp of
    Timeout d -> do
      n <- castDice ldepth totalDepth d
      return $! assert (aTimeout ar == 0) $ ar {aTimeout = n}
    AddHurtMelee d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aHurtMelee = n + aHurtMelee ar}
    AddArmorMelee d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aArmorMelee = n + aArmorMelee ar}
    AddArmorRanged d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aArmorRanged = n + aArmorRanged ar}
    AddMaxHP d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aMaxHP = n + aMaxHP ar}
    AddMaxCalm d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aMaxCalm = n + aMaxCalm ar}
    AddSpeed d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aSpeed = n + aSpeed ar}
    AddSight d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aSight = n + aSight ar}
    AddSmell d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aSmell = n + aSmell ar}
    AddShine d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aShine = n + aShine ar}
    AddNocto d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aNocto = n + aNocto ar}
    AddAggression d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aAggression = n + aAggression ar}
    AddAbility ab d -> do
      n <- castDice ldepth totalDepth d
      return $! ar {aSkills = Ability.addSkills (EM.singleton ab n)
                                                (aSkills ar)}

-- If @False@, aspects of this kind are most probably fixed, not random
-- nor dependent on dungeon level where the item is created.
aspectsRandom :: ItemKind -> Bool
aspectsRandom kind =
  let rollM depth = foldlM' (castAspect (AbsDepth depth) (AbsDepth 10))
                            emptyAspectRecord (iaspects kind)
      gen = R.mkStdGen 0
      (ar0, gen0) = St.runState (rollM 0) gen
      (ar1, gen1) = St.runState (rollM 10) gen0
  in show gen /= show gen0 || show gen /= show gen1 || ar0 /= ar1

meanAspect :: ItemKind -> AspectRecord
meanAspect kind = foldl' addMeanAspect emptyAspectRecord (iaspects kind)

addMeanAspect :: AspectRecord -> Aspect -> AspectRecord
addMeanAspect !ar !asp =
  case asp of
    Timeout d ->
      let n = ceilingMeanDice d
      in assert (aTimeout ar == 0) $ ar {aTimeout = n}
    AddHurtMelee d ->
      let n = ceilingMeanDice d
      in ar {aHurtMelee = n + aHurtMelee ar}
    AddArmorMelee d ->
      let n = ceilingMeanDice d
      in ar {aArmorMelee = n + aArmorMelee ar}
    AddArmorRanged d ->
      let n = ceilingMeanDice d
      in ar {aArmorRanged = n + aArmorRanged ar}
    AddMaxHP d ->
      let n = ceilingMeanDice d
      in ar {aMaxHP = n + aMaxHP ar}
    AddMaxCalm d ->
      let n = ceilingMeanDice d
      in ar {aMaxCalm = n + aMaxCalm ar}
    AddSpeed d ->
      let n = ceilingMeanDice d
      in ar {aSpeed = n + aSpeed ar}
    AddSight d ->
      let n = ceilingMeanDice d
      in ar {aSight = n + aSight ar}
    AddSmell d ->
      let n = ceilingMeanDice d
      in ar {aSmell = n + aSmell ar}
    AddShine d ->
      let n = ceilingMeanDice d
      in ar {aShine = n + aShine ar}
    AddNocto d ->
      let n = ceilingMeanDice d
      in ar {aNocto = n + aNocto ar}
    AddAggression d ->
      let n = ceilingMeanDice d
      in ar {aAggression = n + aAggression ar}
    AddAbility ab d ->
      let n = ceilingMeanDice d
      in ar {aSkills = Ability.addSkills (EM.singleton ab n)
                                         (aSkills ar)}

ceilingMeanDice :: Dice.Dice -> Int
ceilingMeanDice d = ceiling $ Dice.meanDice d

instance NFData ItemKind

instance NFData Effect

instance NFData TimerDice

instance NFData Aspect

instance NFData ThrowMod

instance NFData Feature

instance NFData EqpSlot

instance NFData AspectRecord

instance Hashable Effect

instance Hashable TimerDice

instance Hashable Aspect

instance Hashable ThrowMod

instance Hashable Feature

instance Hashable EqpSlot

instance Hashable AspectRecord

instance Binary Effect

instance Binary TimerDice

instance Binary Aspect

instance Binary ThrowMod

instance Binary Feature

instance Binary EqpSlot

instance Binary AspectRecord

boostItemKindList :: R.StdGen -> [ItemKind] -> [ItemKind]
boostItemKindList _ [] = []
boostItemKindList initialGen l =
  let (r, _) = R.randomR (0, length l - 1) initialGen
  in case splitAt r l of
    (pre, i : post) -> pre ++ boostItemKind i : post
    _               -> error $  "" `showFailure` l

boostItemKind :: ItemKind -> ItemKind
boostItemKind i =
  let mainlineLabel (label, _) = label `elem` ["useful", "treasure"]
  in if any mainlineLabel (ifreq i)
     then i { ifreq = ("useful", 10000)
                         : filter (not . mainlineLabel) (ifreq i)
            , ieffects = delete Unique $ ieffects i
            }
     else i

-- | Whether the effect has a chance of exhibiting any potentially
-- noticeable behaviour.
forApplyEffect :: Effect -> Bool
forApplyEffect eff = case eff of
  ELabel{} -> False
  EqpSlot{} -> False
  OnSmash{} -> False
  Temporary{} -> False
  Unique -> False
  Periodic -> False
  Composite effs -> any forApplyEffect effs
  _ -> True

forIdEffect :: Effect -> Bool
forIdEffect eff = case eff of
  ELabel{} -> False
  EqpSlot{} -> False
  OnSmash{} -> False
  Explode{} -> False  -- tentative; needed for rings to auto-identify
  Unique -> False
  Periodic -> False
  Composite (eff1 : _) -> forIdEffect eff1  -- the rest may never fire
  _ -> True

toDmg :: Dice.Dice -> [(Int, Dice.Dice)]
toDmg dmg = [(1, dmg)]

tmpNoLonger :: Text -> Effect
tmpNoLonger name = Temporary $ "be no longer" <+> name

tmpLess :: Text -> Effect
tmpLess name = Temporary $ "become less" <+> name

toVelocity :: Int -> Feature
toVelocity n = ToThrow $ ThrowMod n 100

toLinger :: Int -> Feature
toLinger n = ToThrow $ ThrowMod 100 n

timerNone :: TimerDice
timerNone = TimerNone

isTimerNone :: TimerDice -> Bool
isTimerNone tim = tim == TimerNone

foldTimer :: a -> (Dice.Dice -> a) -> (Dice.Dice -> a) -> TimerDice -> a
foldTimer a fgame factor tim = case tim of
  TimerNone -> a
  TimerGameTurn nDm -> fgame nDm
  TimerActorTurn nDm -> factor nDm

toOrganGameTurn :: GroupName ItemKind -> Dice.Dice -> Effect
toOrganGameTurn grp nDm =
  assert (Dice.minDice nDm > 0
          `blame` "dice at organ creation should always roll above zero"
          `swith` (grp, nDm))
  $ CreateItem COrgan grp (TimerGameTurn nDm)

toOrganActorTurn :: GroupName ItemKind -> Dice.Dice -> Effect
toOrganActorTurn grp nDm =
  assert (Dice.minDice nDm > 0
          `blame` "dice at organ creation should always roll above zero"
          `swith` (grp, nDm))
  $ CreateItem COrgan grp (TimerActorTurn nDm)

toOrganNone :: GroupName ItemKind -> Effect
toOrganNone grp = CreateItem COrgan grp TimerNone

-- | Catch invalid item kind definitions.
validateSingle :: ItemKind -> [Text]
validateSingle ik@ItemKind{..} =
  [ "iname longer than 23" | T.length iname > 23 ]
  ++ [ "icount < 0" | Dice.minDice icount < 0 ]
  ++ validateRarity irarity
  ++ validateDamage idamage
  -- Reject duplicate Timeout, because it's not additive.
  ++ (let timeoutAspect :: Aspect -> Bool
          timeoutAspect Timeout{} = True
          timeoutAspect _ = False
          ts = filter timeoutAspect iaspects
      in ["more than one Timeout specification" | length ts > 1])
  ++ (let f :: Effect -> Bool
          f ELabel{} = True
          f _ = False
      in validateTopSingle ieffects "ELabel" f)
  ++ (let f :: Effect -> Bool
          f EqpSlot{} = True
          f _ = False
          ts = filter f ieffects
      in validateTopSingle ieffects "EqpSlot" f
         ++ [ "EqpSlot specified but not Equipable nor Meleeable"
            | length ts > 0 && Equipable `notElem` ifeature
                            && Meleeable `notElem` ifeature ])
  ++ ["Redundant Equipable or Meleeable" | Equipable `elem` ifeature
                                           && Meleeable `elem` ifeature]
  ++ (let f :: Effect -> Bool
          f OnSmash{} = True
          f _ = False
      in validateNotNested ieffects "OnSmash" f)  -- duplicates permitted
  ++ (let f :: Effect -> Bool
          f Recharging{} = True
          f _ = False
      in validateNotNested ieffects "Recharging" f)  -- duplicates permitted
  ++ (let f :: Effect -> Bool
          f Temporary{} = True
          f _ = False
      in validateOnlyOne ieffects "Temporary" f)  -- may be duplicated if nested
  ++ (let f :: Effect -> Bool
          f Unique = True
          f _ = False
      in validateTopSingle ieffects "Unique" f)
  ++ (let f :: Effect -> Bool
          f Periodic = True
          f _ = False
      in validateTopSingle ieffects "Periodic" f)
  ++ (let f :: Feature -> Bool
          f ToThrow{} = True
          f _ = False
          ts = filter f ifeature
      in ["more than one ToThrow specification" | length ts > 1])
  ++ (let f :: Feature -> Bool
          f Tactic{} = True
          f _ = False
          ts = filter f ifeature
      in ["more than one Tactic specification" | length ts > 1])
  ++ concatMap (validateDups ik)
       [ Fragile, Lobable, Durable, Identified, Applicable
       , Equipable, Meleeable, Precious, Blast ]

-- We only check there are no duplicates at top level. If it may be nested,
-- it may presumably be duplicated inside the nesting as well.
validateOnlyOne :: [Effect] -> Text -> (Effect -> Bool) -> [Text]
validateOnlyOne effs t f =
  let  ts = filter f effs
  in ["more than one" <+> t <+> "specification" | length ts > 1]

-- We check it's not nested one nor more levels.
validateNotNested :: [Effect] -> Text -> (Effect -> Bool) -> [Text]
validateNotNested effs t f =
  let g (OneOf l) = any f l || any g l
      g (OnSmash effect) = f effect || g effect
      g (Recharging effect) = f effect || g effect
      g (Composite l) = any f l || any g l
      g _ = False
      ts = filter g effs
  in [ "effect" <+> t <+> "should be specified at top level, not nested"
     | length ts > 0 ]

-- If it's not nested and not duplicated at top level, it's not duplicated
-- anywhere.
validateTopSingle :: [Effect] -> Text -> (Effect -> Bool) -> [Text]
validateTopSingle effs t f =
  validateOnlyOne effs t f ++ validateNotNested effs t f

validateDups :: ItemKind -> Feature -> [Text]
validateDups ItemKind{..} feat =
  let ts = filter (== feat) ifeature
  in ["more than one" <+> tshow feat <+> "specification" | length ts > 1]

validateDamage :: [(Int, Dice.Dice)] -> [Text]
validateDamage = concatMap validateDice
 where
  validateDice (_, dice) = [ "potentially negative dice:" <+> tshow dice
                           | Dice.minDice dice < 0]

-- | Validate all item kinds.
validateAll :: [ItemKind] -> ContentData ItemKind -> [Text]
validateAll content coitem =
  let missingGroups = [ cgroup
                      | k <- content
                      , (cgroup, _) <- ikit k
                      , not $ omemberGroup coitem cgroup ]
      hardwiredAbsent = filter (not . omemberGroup coitem) hardwiredItemGroups
  in [ "no ikit groups in content:" <+> tshow missingGroups
     | not $ null missingGroups ]
     ++ [ "hardwired groups not in content:" <+> tshow hardwiredAbsent
        | not $ null hardwiredAbsent ]

hardwiredItemGroups :: [GroupName ItemKind]
hardwiredItemGroups =
  -- From Preferences.hs:
  [ "temporary condition", "treasure", "useful", "any scroll", "any vial"
  , "potion", "flask" ]
  -- Assorted:
  ++ ["bonus HP", "currency", "impressed", "mobile"]

makeData :: [ItemKind] -> ContentData ItemKind
makeData = makeContentData iname ifreq validateSingle validateAll
