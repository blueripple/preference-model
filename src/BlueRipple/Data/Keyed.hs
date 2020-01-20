{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DefaultSignatures   #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE TupleSections       #-}
module BlueRipple.Data.Keyed where

import qualified Control.Foldl                 as FL
import qualified Data.Array                    as A
import qualified Data.List                     as L
import qualified Data.List.NonEmpty            as NE
import qualified Data.Map                      as M
import qualified Data.Text                     as T
import qualified Data.Serialize                as S
import qualified Data.Set                      as Set
import qualified Frames                        as F
import qualified Frames.Melt                   as F
import qualified Frames.InCore                 as FI
import qualified Frames.Folds                  as FF
import qualified Frames.MapReduce              as FMR
import qualified Data.Vector                   as Vec
import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.TypeLevel          as V


{-
Lets talk about aggregation!
Suppose we have:
keys, a of type A
keys, b of type B
data, d of type D
An arrow, gA : A -> D, mapping keys in a to data, think the data in a row indexed by A
An arrow,  aggBA : B -> Z[A], where Z[A] is the module of finite formal linear combinations of a in A with coeficients in Z.
We note that Z[A] is a Ring, using elementwise addition and multiplication.
An arrow, fold: Z[D] -> D, "folding" formal linear combinations of d in D (with coefficients in Z) into a d in D
There is a covariant functor, FZ : Set -> Category of modules, FZ (X) = Z[X] and FZ (g : X -> Y) = Z[X] -> Z[Y]
Then we can construct gB : B -> D, gB (b) = fold . FZ (gA) . aggBA b

a "Filter", Q,  is just a subset of A.  And we can represent it by an element, filter(Q) of Z[A]
such that any a in Q has a 1 and any a not in Q has coefficient 0. Also, any element of Z[A] with
coefficients in {0,1} represents some filter.  That is, there is an isomorphism between filters 
and elements of Z[A] with coefficients in {0,1}

We can compose filters two ways:
1) Their union, the set of all things in either.  This corresponds to the elementwise sum of Z[A], WITH the
rule that all non-zero coefficients are capped at 1.  This is *not* Z_2, where 1+1 = 0.  This also allows
us to say something about which sums of filters preserve some notion of getting each ting only once.  That
is, which are partitions of a subset of K.

2) Their intersection, the set of all things in both.  This is just the elementwise product.
-}
-- finite formal sum of @a@ with integer coefficients
-- i.e., an element of Z[A], the set of Z-modules over the set a
-- With weights in {0,1}, this is a query, a way of describing
-- a subset of A
data KeyWeights a where
  KeyWeights :: [(Int, a)] -> KeyWeights a

instance Show a => Show (KeyWeights a) where
  show (KeyWeights kw) = "KeyWeights: " ++ show kw

instance Functor KeyWeights where
  fmap f (KeyWeights kw) = KeyWeights $ fmap (\(w,a) -> (w, f a)) kw

instance Applicative KeyWeights where
  pure a = KeyWeights [(1,a)]
  (KeyWeights kwFab) <*> (KeyWeights kwa) = KeyWeights $ do
    (fw, f) <- kwFab
    (aw, a) <- kwa
    return (fw * aw, f a)

instance Monad KeyWeights where
  (KeyWeights kwa) >>= f =
    let distribute n (KeyWeights kwb) = fmap (\(m, b) -> (n * m, b)) kwb
        g (n, a) = distribute n (f a)
    in KeyWeights $  concat $ fmap g kwa

-- We need this to define a multiplicative
-- identity in Z[A]
class Ord a => FiniteSet a where
  elements :: Set.Set a
  default elements :: (Enum a, Bounded a) => Set.Set a
  elements = Set.fromList [minBound..]

instance (FiniteSet a, FiniteSet b) => FiniteSet (a,b) where
  elements = Set.fromList $ do
    a <- Set.toList elements
    b <- Set.toList elements
    return (a, b)

kwOne :: FiniteSet a => KeyWeights a
kwOne = KeyWeights $ fmap (1, ) $ Set.toList $ elements

kwZero :: KeyWeights a
kwZero = KeyWeights $ []

simplify :: Eq a => KeyWeights a -> KeyWeights a
simplify (KeyWeights kw)
  = let
      grouped = NE.groupWith snd kw
      sum :: NE.NonEmpty (Int, a) -> (Int, a)
      sum ws =
        let a = snd (NE.head ws) in (FL.fold (FL.premap fst FL.sum) ws, a)
    in
      KeyWeights $ fmap sum grouped

(^==^) :: Eq a => KeyWeights a -> KeyWeights a -> Bool
kw1 ^==^ kw2 =
  let (KeyWeights kw1') = simplify kw1
      (KeyWeights kw2') = simplify kw2
  in  kw1' == kw2'

kwSwap :: (a, b) -> (b, a)
kwSwap (x, y) = (y, x)

kwToMap :: Ord a => KeyWeights a -> M.Map a Int
kwToMap (KeyWeights kw) = M.fromListWith (+) $ fmap kwSwap kw

(^+^) :: Ord a => KeyWeights a -> KeyWeights a -> KeyWeights a
kw1 ^+^ kw2 = KeyWeights . fmap kwSwap . M.toList $ M.unionWith (+)
                                                                (kwToMap kw1)
                                                                (kwToMap kw2)

kwInvert :: KeyWeights a -> KeyWeights a
kwInvert (KeyWeights kw) = KeyWeights $ fmap (\(n, a) -> (negate n, a)) kw

(^*^) :: Ord a => KeyWeights a -> KeyWeights a -> KeyWeights a
kw1 ^*^ kw2 = KeyWeights $ fmap kwSwap . M.toList $ M.intersectionWith
  (*)
  (kwToMap kw1)
  (kwToMap kw2)


-- with these defintions, KeyWeights is a commutative ring (KeyWeights a, :+:, :*:)
-- multiplication corresponds to intersection, getting only things retrieved by both keys
-- addition corresponds to getting everything retrieved by either key.
keyHas :: Ord a => [a] -> KeyWeights a
keyHas as = KeyWeights $ fmap (1, ) as

diff :: Ord a => a -> a -> KeyWeights a
diff a1 a2 = keyHas [a1] ^+^ (kwInvert $ keyHas [a2])

diffSum :: Ord a => a -> [a] -> KeyWeights a
diffSum a as = keyHas [a] ^+^ (kwInvert $ keyHas as)

composeKeyWeights :: KeyWeights a -> KeyWeights b -> KeyWeights (a, b)
composeKeyWeights (KeyWeights kwa) (KeyWeights kwb) = KeyWeights $ do
  (n, a) <- kwa
  (m, b) <- kwb
  return (n * m, (a, b))

type Aggregation b a = b -> KeyWeights a

-- There is a functor
-- FZ : FiniteSet -> Ring, 
-- Where FZ is the Free Abelian Group functor which also
-- equips the finitely-generated Abelian group
-- with the natural elementwise on generators multiplication:
-- (n a_1 + m a_2) * (k a_1 + l * a_3) = (n*k) a_1
-- Since there is a forgetful functor U : Ring -> Set,
-- FZ . U is a monad, with unit
-- eta : Set -> Set, mapping A to the singleton sum, and multiplicatio
-- mu: Z[Z[A]] -> Z[A], flattening the sums.

-- Given an aggregation (a : B -> Z[A])
-- we are especially interested in aggregations
-- where mu (FZ a) : Z[B] -> Z[A] is a Ring homomorphism.
-- It preserves 0, 1 and commutes with the ring operations
-- preserving 0: No addition of data
-- preserving 1: All data goes someplace and only once
-- commuting with ^+^:  
composeAggregations
  :: (FiniteSet a, FiniteSet x)
  => Aggregation b a
  -> Aggregation y x
  -> Aggregation (b, y) (a, x)
composeAggregations aggBA aggYX (b, y) =
  (composeKeyWeights (aggBA b) kwOne) ^*^ (composeKeyWeights kwOne (aggYX y))


preservesOne :: (FiniteSet a, FiniteSet b) => Aggregation b a -> Bool
preservesOne agg = (kwOne >>= agg) ^==^ kwOne

preservesZero :: (FiniteSet a, FiniteSet b) => Aggregation b a -> Bool
preservesZero agg = (kwZero >>= agg) ^==^ kwZero



{-
aggFold
  :: forall k k' d
   . Aggregation k' k
  -> FL.Fold (d, Int) d
  -> [k']
  -> FL.FoldM (Either T.Text) (k, d) [(k', d)]
aggFold agg alg newKeys = FMR.postMapM go (FL.generalize FL.map)
 where
  go :: M.Map k d -> Either T.Text [(k', d)]
  go m = traverse (doOne m) newKeys
  doOne :: M.Map k d -> k' -> (k', d)
  doOne = traverse (`M.lookup` m) $ agg k'
-}


  {-
data AggExpr a where
  AggSingle :: a -> AggExpr a
  AggSum :: [AggExpr a] -> AggExpr a
  AggDiff :: AggExpr a -> AggExpr a -> AggExpr a
  deriving (Functor, Show)

aggregate :: Num b => (a -> b) -> AggExpr a -> b
aggregate f (AggSingle a ) = f a
aggregate f (AggSum    as) = FL.fold (FL.premap (aggregate f) FL.sum) as
aggregate f (AggDiff a a') = aggregate f a - aggregate f a'

aggregateM :: (Monad m, Num b) => (a -> m b) -> AggExpr a -> m b
aggregateM f (AggSingle a) = f a
aggregateM f (AggSum as) =
  FL.foldM (FL.premapM (aggregateM f) (FL.generalize FL.sum)) as
aggregateM f (AggDiff a a') = (-) <$> aggregateM f a <*> aggregateM f a'

composeAggExpr :: AggExpr a -> AggExpr b -> AggExpr (a, b)
composeAggExpr (AggSingle a) (AggSingle b) = AggSingle (a, b)
composeAggExpr (AggSum as) aeb = AggSum $ fmap (`composeAggExpr` aeb) as
composeAggExpr (AggDiff a a') aeb =
  AggDiff (composeAggExpr a aeb) (composeAggExpr a' aeb)
composeAggExpr aea (AggSum bs) = AggSum $ fmap (composeAggExpr aea) bs
composeAggExpr aea (AggDiff b b') =
  AggDiff (composeAggExpr aea b) (composeAggExpr aea b')

aggAge4ToSimple :: SimpleAge -> AggExpr Age4
aggAge4ToSimple x = AggSum $ fmap AggSingle $ simpleAgeFrom4 x

aggAge5ToSimple :: SimpleAge -> AggExpr Age5
aggAge5ToSimple x = AggSum $ fmap AggSingle $ simpleAgeFrom5 x

aggACSToCollegeGrad :: CollegeGrad -> AggExpr Education
aggACSToCollegeGrad x = AggSum $ fmap AggSingle $ acsLevels x

aggTurnoutToCollegeGrad :: CollegeGrad -> AggExpr Education
aggTurnoutToCollegeGrad x = AggSum $ fmap AggSingle $ turnoutLevels x

aggSexToAll :: () -> AggExpr Sex
aggSexToAll _ = AggSum $ fmap AggSingle [Female, Male]

aggTurnoutRaceToSimple :: SimpleRace -> AggExpr TurnoutRace
aggTurnoutRaceToSimple NonWhite =
  AggSum $ fmap AggSingle [Turnout_Black, Turnout_Asian, Turnout_Hispanic]
aggTurnoutRaceToSimple White = AggSingle Turnout_White

aggACSRaceToSimple :: SimpleRace -> AggExpr ACSRace
aggACSRaceToSimple NonWhite =
  AggDiff (AggSingle ACS_All) (AggSingle ACS_WhiteNonHispanic)
aggACSRaceToSimple White = AggSingle ACS_WhiteNonHispanic

aggAE_ACS :: (SimpleAge, CollegeGrad) -> AggExpr (Age4, Education)
aggAE_ACS (sa, cg) =
  composeAggExpr (aggAge4ToSimple sa) (aggACSToCollegeGrad cg)

aggAR_ACS :: (SimpleAge, SimpleRace) -> AggExpr (Age5, ACSRace)
aggAR_ACS (sa, sr) =
  composeAggExpr (aggAge5ToSimple sa) (aggACSRaceToSimple sr)

aggAE_Turnout :: (SimpleAge, CollegeGrad) -> AggExpr (Age5, Education)
aggAE_Turnout (sa, cg) =
  composeAggExpr (aggAge5ToSimple sa) (aggTurnoutToCollegeGrad cg)

aggAR_Turnout :: (SimpleAge, SimpleRace) -> AggExpr (Age5, TurnoutRace)
aggAR_Turnout (sa, sr) =
  composeAggExpr (aggAge5ToSimple sa) (aggTurnoutRaceToSimple sr)

aggFold
  :: forall k k' v
   . (Show k, Show k', Show v, Num v, Ord k)
  => [(k', AggExpr k)]
  -> FL.FoldM (Either T.Text) (k, v) [(k', v)]
aggFold keyedAE = FMR.postMapM go (FL.generalize FL.map)
 where
  getOne :: M.Map k v -> (k', AggExpr k) -> Either T.Text (k', v)
  getOne m (k', ae) =
    fmap (k', )
      $ maybe
          (  Left
          $  "lookup failed in aggFold: aggExpr="
          <> (T.pack $ show ae)
          <> "; m="
          <> (T.pack $ show m)
          )
          Right
      $ aggregateM (`M.lookup` m) ae
  go :: M.Map k v -> Either T.Text [(k', v)]
  go m = traverse (getOne m) keyedAE

aggFoldWeighted
  :: forall k k' v w
   . (Show k, Show k', Show v, Num v, Num w, Ord k)
  => [(k', AggExpr k)]
  -> FL.FoldM (Either T.Text) (k, (w, v)) [(k', v)]
aggFoldWeighted keyedAE = FMR.postMapM go (FL.generalize FL.map)
 where
  getOne :: M.Map k v -> (k', AggExpr k) -> Either T.Text (k', v)
  getOne m (k', ae) =
    fmap (k', )
      $ maybe
          (  Left
          $  "lookup failed in aggFold: aggExpr="
          <> (T.pack $ show ae)
          <> "; m="
          <> (T.pack $ show m)
          )
          Right
      $ aggregateM (`M.lookup` m) ae
  go :: M.Map k v -> Either T.Text [(k', v)]
  go m = traverse (getOne m) keyedAE  

aggFoldRecords :: [(F.Record k', AggExp (V.Snd k'))] -> FL.FoldM (F.Record (k V.++ v) 
-}
