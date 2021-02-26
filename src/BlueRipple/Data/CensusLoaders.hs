{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -O0 #-}
module BlueRipple.Data.CensusLoaders where

import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.DataFrames as BR
import qualified BlueRipple.Data.KeyedTables as KT
import qualified BlueRipple.Data.CensusTables as BRC
import qualified BlueRipple.Data.Keyed as BRK
import qualified BlueRipple.Utilities.KnitUtils as BR

import qualified Control.Foldl as FL
import qualified Data.Csv as CSV
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vector as Vec
import qualified Data.Vector.Generic as GVec
import qualified Data.Serialize as S
import qualified Flat
import qualified Frames                        as F
import qualified Frames.Melt                        as F
import qualified Frames.TH as F
import qualified Frames.InCore                 as FI
import qualified Frames.Transform as FT
import qualified Frames.MapReduce as FMR
import qualified Frames.Folds as FF
import qualified Frames.Serialize as FS
import qualified Knit.Report as K

F.declareColumn "Count" ''Int


reKeyCensusTables :: (F.ElemOf [a', s'] s'
                     ,F.ElemOf [a, s] s
                     ,F.ElemOf [a', s', r'] r'
                     ,F.ElemOf [a', s', r'] s'
                     ,F.ElemOf [a, s, r] r
                     ,F.ElemOf [a, s, r] s
                     ,F.ElemOf [s', r'] r'
                     ,F.ElemOf [s, r] r
                     ,F.ElemOf [s', r', c'] c'
                     ,F.ElemOf [s', r', c'] r'
                     ,F.ElemOf [s, r, c] c
                     ,F.ElemOf [s, r, c] r
                     ,F.ElemOf [s', c'] c'
                     ,F.ElemOf [s, c] c
                     ,F.ElemOf [s', e'] e'
                     ,F.ElemOf [s, e] e
                     ,F.ElemOf [s', e', r'] r'
                     ,F.ElemOf [s', e', r'] e'
                     ,F.ElemOf [s, e, r] r
                     ,F.ElemOf [s, e, r] e
                     , V.KnownField a'
                     , V.KnownField s'
                     , V.KnownField r'
                     , BRK.FiniteSet (V.Snd a')
                     , BRK.FiniteSet (V.Snd s')
                     , BRK.FiniteSet (V.Snd r')
                     , Ord (V.Snd r')
                     , Ord (V.Snd s')
                     , Ord (V.Snd a')

                     )
                  => BRK.AggFRec Bool '[a'] '[a]
                  -> BRK.AggFRec Bool '[s'] '[s]
                  -> BRK.AggFRec Bool '[e'] '[e]
                  -> BRK.AggFRec Bool '[r'] '[r]
                  -> BRK.AggFRec Bool '[c'] '[c]
                  -> CensusTablesByCD a s e r c
                  -> CensusTablesByCD a' s' e' r' c'
reKeyCensusTables rkA rkS rkE rkR rkC ct =
  let aggF_AS = rkA `BRK.aggFProductRec` rkS
      aggF_ASR = aggF_AS `BRK.aggFProductRec` rkR
      aggF_SRC = rkS `BRK.aggFProductRec` rkR `BRK.aggFProductRec` rkC
      aggF_SC = rkS `BRK.aggFProductRec` rkC
      aggF_SE = rkS `BRK.aggFProductRec` rkE
      aggF_SER = rkS `BRK.aggFProductRec` rkE `BRK.aggFProductRec` rkR
  in CensusTablesByCD
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_ASR) $ ageSexRace ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_AS) $ hispanicAgeSex ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_AS) $ whiteNonHispanicAgeSex ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_SRC) $ sexRaceCitizenship ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_SC) $ hispanicSexCitizenship ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_SC) $ whiteNonHispanicSexCitizenship ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_SER) $ sexEducationRace ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_SE) $ hispanicSexEducation ct)
     (FL.fold (rekeyFrameF @BRC.CDPrefixR aggF_SE) $ whiteNonHispanicSexEducation ct)

censusDataDir :: Text
censusDataDir = "../bigData/Census"

data CensusTablesByCD a s e r c
  = CensusTablesByCD { ageSexRace :: F.FrameRec (CDRow [a, s, r])
                     , hispanicAgeSex :: F.FrameRec (CDRow [a, s])
                     , whiteNonHispanicAgeSex :: F.FrameRec (CDRow [a, s])
                     , sexRaceCitizenship :: F.FrameRec (CDRow [s, r, c])
                     , hispanicSexCitizenship :: F.FrameRec (CDRow [s, c])
                     , whiteNonHispanicSexCitizenship :: F.FrameRec (CDRow [s, c])
                     , sexEducationRace :: F.FrameRec (CDRow [s, e, r])
                     , hispanicSexEducation :: F.FrameRec (CDRow [s, e])
                     , whiteNonHispanicSexEducation :: F.FrameRec (CDRow [s, e])
                     } deriving (Generic)

instance Semigroup (CensusTablesByCD a s e r c) where
  (CensusTablesByCD a1 a2 a3 a4 a5 a6 a7 a8 a9) <> (CensusTablesByCD b1 b2 b3 b4 b5 b6 b7 b8 b9) =
    CensusTablesByCD (a1 <> b1) (a2 <> b2) (a3 <> b3) (a4 <> b4) (a5 <> b5) (a6 <> b6) (a7 <> b7) (a8 <> b8) (a9 <> b9)

instance (S.Serialize (V.Snd a)
         , S.Serialize (V.Snd s)
         , S.Serialize (V.Snd e)
         , S.Serialize (V.Snd r)
         , S.Serialize (V.Snd c)
         , V.KnownField a
         , V.KnownField s
         , V.KnownField e
         , V.KnownField r
         , V.KnownField c
         , GVec.Vector (FI.VectorFor (V.Snd a)) (V.Snd a)
         , GVec.Vector (FI.VectorFor (V.Snd s)) (V.Snd s)
         , GVec.Vector (FI.VectorFor (V.Snd e)) (V.Snd e)
         , GVec.Vector (FI.VectorFor (V.Snd r)) (V.Snd r)
         , GVec.Vector (FI.VectorFor (V.Snd c)) (V.Snd c)
         ) =>
         S.Serialize (CensusTablesByCD a s e r c) where
  put (CensusTablesByCD f1 f2 f3 f4 f5 f6 f7 f8 f9) =
    S.put (FS.SFrame f1, FS.SFrame f2, FS.SFrame f3, FS.SFrame f4, FS.SFrame f5, FS.SFrame f6, FS.SFrame f7, FS.SFrame f8, FS.SFrame f9)
  get = (\(sf1, sf2, sf3, sf4, sf5, sf6, sf7, sf8, sf9)
          -> CensusTablesByCD
             (FS.unSFrame sf1)
             (FS.unSFrame sf2)
             (FS.unSFrame sf3)
             (FS.unSFrame sf4)
             (FS.unSFrame sf5)
             (FS.unSFrame sf6)
             (FS.unSFrame sf7)
             (FS.unSFrame sf8)
             (FS.unSFrame sf9)
        )
        <$> S.get

instance (Flat.Flat (V.Snd a)
         , Flat.Flat (V.Snd s)
         , Flat.Flat (V.Snd e)
         , Flat.Flat (V.Snd r)
         , Flat.Flat (V.Snd c)
         , V.KnownField a
         , V.KnownField s
         , V.KnownField e
         , V.KnownField r
         , V.KnownField c
         , GVec.Vector (FI.VectorFor (V.Snd a)) (V.Snd a)
         , GVec.Vector (FI.VectorFor (V.Snd s)) (V.Snd s)
         , GVec.Vector (FI.VectorFor (V.Snd e)) (V.Snd e)
         , GVec.Vector (FI.VectorFor (V.Snd r)) (V.Snd r)
         , GVec.Vector (FI.VectorFor (V.Snd c)) (V.Snd c)
         ) =>
  Flat.Flat (CensusTablesByCD a s e r c) where
  size (CensusTablesByCD f1 f2 f3 f4 f5 f6 f7 f8 f9) n =
    Flat.size ((FS.SFrame f1, FS.SFrame f2, FS.SFrame f3), (FS.SFrame f4, FS.SFrame f5, FS.SFrame f6), (FS.SFrame f7, FS.SFrame f8, FS.SFrame f9)) n
  encode (CensusTablesByCD f1 f2 f3 f4 f5 f6 f7 f8 f9) =
    Flat.encode ((FS.SFrame f1, FS.SFrame f2, FS.SFrame f3), (FS.SFrame f4, FS.SFrame f5, FS.SFrame f6), (FS.SFrame f7, FS.SFrame f8, FS.SFrame f9))
  decode = (\((sf1, sf2, sf3), (sf4, sf5, sf6), (sf7, sf8, sf9))
             -> CensusTablesByCD
                (FS.unSFrame sf1)
                (FS.unSFrame sf2)
                (FS.unSFrame sf3)
                (FS.unSFrame sf4)
                (FS.unSFrame sf5)
                (FS.unSFrame sf6)
                (FS.unSFrame sf7)
                (FS.unSFrame sf8)
                (FS.unSFrame sf9)
           )
           <$> Flat.decode

type CDRow rs = '[BR.Year] V.++ BRC.CDPrefixR V.++ rs V.++ '[Count]

type LoadedCensusTablesByCD = CensusTablesByCD BRC.Age14C DT.SexC BRC.Education4C DT.RaceAlone4C BRC.CitizenshipC

censusTablesByDistrict  :: (K.KnitEffects r
                              , BR.CacheEffects r)
                           => K.Sem r (K.ActionWithCacheTime r LoadedCensusTablesByCD)
censusTablesByDistrict = do
  let fileByYear = [ (BRC.TY2012, censusDataDir <> "/cd113Raw.csv")
                   , (BRC.TY2014, censusDataDir <> "/cd114Raw.csv")
                   , (BRC.TY2016, censusDataDir <> "/cd115Raw.csv")
                   , (BRC.TY2018, censusDataDir <> "/cd116Raw.csv")
                   ]
      tableDescriptions ty = KT.allTableDescriptions BRC.sexByAge (BRC.sexByAgePrefix ty)
                             <> KT.tableDescriptions BRC.sexByAge [BRC.hispanicSexByAgePrefix ty]
                             <> KT.tableDescriptions BRC.sexByAge [BRC.whiteNonHispanicSexByAgePrefix ty]
                             <> KT.allTableDescriptions BRC.sexByCitizenship (BRC.sexByCitizenshipPrefix ty)
                             <> KT.tableDescriptions BRC.sexByCitizenship [BRC.hispanicSexByCitizenshipPrefix ty]
                             <> KT.tableDescriptions BRC.sexByCitizenship [BRC.whiteNonHispanicSexByCitizenshipPrefix ty]
                             <> KT.allTableDescriptions BRC.sexByEducation (BRC.sexByEducationPrefix ty)
                             <> KT.tableDescriptions BRC.sexByEducation [BRC.hispanicSexByEducationPrefix ty]
                             <> KT.tableDescriptions BRC.sexByEducation [BRC.whiteNonHispanicSexByEducationPrefix ty]
      makeFrame ty tableDF prefix keyRec vTableRows = do
        vTRs <- K.knitEither $ traverse (\tr -> KT.typeOneTable tableDF tr (prefix ty)) vTableRows
        return $ frameFromTableRows BRC.unCDPrefix keyRec (BRC.tableYear ty) vTRs
      makeConsolidatedFrame ty tableDF prefixF keyRec vTableRows = do
        vTRs <- K.knitEither $ traverse (KT.consolidateTables tableDF (prefixF ty)) vTableRows
        return $ frameFromTableRows BRC.unCDPrefix keyRec (BRC.tableYear ty) vTRs
      doOneYear (ty, f) = do
        (_, vTableRows) <- K.knitEither =<< (K.liftKnit $ KT.decodeCSVTablesFromFile @BRC.CDPrefix (tableDescriptions ty) $ toString f)
        K.logLE K.Diagnostic $ "Loaded and parsed \"" <> f <> "\" for " <> show (BRC.tableYear ty) <> "."
        K.logLE K.Diagnostic $ "Building Race/Ethnicity by Sex by Age Tables..."
        fRaceBySexByAge <- makeConsolidatedFrame ty BRC.sexByAge BRC.sexByAgePrefix raceBySexByAgeKeyRec vTableRows
        fHispanicSexByAge <- makeFrame ty BRC.sexByAge BRC.hispanicSexByAgePrefix sexByAgeKeyRec vTableRows
        fWhiteNonHispanicSexByAge <- makeFrame ty BRC.sexByAge BRC.whiteNonHispanicSexByAgePrefix sexByAgeKeyRec vTableRows
        K.logLE K.Diagnostic $ "Building Race/Ethnicity by Sex by Citizenship Tables..."
        fRaceBySexByCitizenship <- makeConsolidatedFrame ty BRC.sexByCitizenship BRC.sexByCitizenshipPrefix raceBySexByCitizenshipKeyRec vTableRows
        fHispanicSexByCitizenship <- makeFrame ty BRC.sexByCitizenship BRC.hispanicSexByCitizenshipPrefix sexByCitizenshipKeyRec vTableRows
        fWhiteNonHispanicSexByCitizenship <- makeFrame ty BRC.sexByCitizenship BRC.whiteNonHispanicSexByCitizenshipPrefix sexByCitizenshipKeyRec vTableRows
        K.logLE K.Diagnostic $ "Building Race/Ethnicity by Sex by Education Tables..."
        fRaceBySexByEducation <- makeConsolidatedFrame ty BRC.sexByEducation BRC.sexByEducationPrefix raceBySexByEducationKeyRec vTableRows
        fHispanicSexByEducation <- makeFrame ty BRC.sexByEducation BRC.hispanicSexByEducationPrefix sexByEducationKeyRec vTableRows
        fWhiteNonHispanicSexByEducation <- makeFrame ty BRC.sexByEducation BRC.whiteNonHispanicSexByEducationPrefix sexByEducationKeyRec vTableRows
        return $ CensusTablesByCD
          fRaceBySexByAge
          fHispanicSexByAge
          fWhiteNonHispanicSexByAge
          fRaceBySexByCitizenship
          fHispanicSexByCitizenship
          fWhiteNonHispanicSexByCitizenship
          fRaceBySexByEducation
          fHispanicSexByEducation
          fWhiteNonHispanicSexByEducation
  dataDeps <- traverse (K.fileDependency . toString . snd) fileByYear
  let dataDep = fromMaybe (pure ()) $ fmap sconcat $ nonEmpty dataDeps
  K.retrieveOrMake @BR.SerializerC @BR.CacheData @Text "data/Census/tables.bin" dataDep $ const $ do
    tables <- traverse doOneYear fileByYear
    neTables <- K.knitMaybe "Empty list of tables in result of censusTablesByDistrict" $ nonEmpty tables
    return $ sconcat neTables

sexByAgeKeyRec :: (DT.Sex, BRC.Age14) -> F.Record [BRC.Age14C, DT.SexC]
sexByAgeKeyRec (s, a) = a F.&: s F.&: V.RNil
{-# INLINE sexByAgeKeyRec #-}

raceBySexByAgeKeyRec :: (DT.RaceAlone4, (DT.Sex, BRC.Age14)) -> F.Record [BRC.Age14C, DT.SexC, DT.RaceAlone4C]
raceBySexByAgeKeyRec (r, (s, a)) = a F.&: s F.&: r F.&: V.RNil
{-# INLINE raceBySexByAgeKeyRec #-}

sexByCitizenshipKeyRec :: (DT.Sex, BRC.Citizenship) -> F.Record [DT.SexC, BRC.CitizenshipC]
sexByCitizenshipKeyRec (s, c) = s F.&: c F.&: V.RNil
{-# INLINE sexByCitizenshipKeyRec #-}

raceBySexByCitizenshipKeyRec :: (DT.RaceAlone4, (DT.Sex, BRC.Citizenship)) -> F.Record [DT.SexC, DT.RaceAlone4C, BRC.CitizenshipC]
raceBySexByCitizenshipKeyRec (r, (s, c)) = s F.&: r F.&: c F.&: V.RNil
{-# INLINE raceBySexByCitizenshipKeyRec #-}

sexByEducationKeyRec :: (DT.Sex, BRC.Education4) -> F.Record [DT.SexC, BRC.Education4C]
sexByEducationKeyRec (s, e) = s F.&: e F.&: V.RNil
{-# INLINE sexByEducationKeyRec #-}

raceBySexByEducationKeyRec :: (DT.RaceAlone4, (DT.Sex, BRC.Education4)) -> F.Record [DT.SexC, BRC.Education4C, DT.RaceAlone4C]
raceBySexByEducationKeyRec (r, (s, e)) = s F.&: e F.&: r F.&: V.RNil
{-# INLINE raceBySexByEducationKeyRec #-}


raceBySexByAgeToASR4 :: BRK.AggFRec Bool ([DT.SimpleAgeC, DT.SexC, DT.RaceAlone4C]) ([BRC.Age14C, DT.SexC, DT.RaceAlone4C])
raceBySexByAgeToASR4 =
  let aggAge :: BRK.AggFRec Bool '[DT.SimpleAgeC] '[BRC.Age14C]
      aggAge = BRK.toAggFRec $ BRK.AggF (\sa a14 -> a14 `elem` (DT.simpleAgeFrom5F sa >>= BRC.age14FromAge5F))
      aggSex :: BRK.AggFRec Bool '[DT.SexC] '[DT.SexC]
      aggSex = BRK.aggFId
      aggRace :: BRK.AggFRec Bool '[DT.RaceAlone4C] '[DT.RaceAlone4C]
      aggRace = BRK.aggFId
  in  aggAge `BRK.aggFProductRec` aggSex `BRK.aggFProductRec` aggRace

rekeyFrameF :: forall as bs cs.
               (Ord (F.Record as)
               , BRK.FiniteSet (F.Record cs)
               , as F.⊆ ('[BR.Year] V.++ as V.++ (bs V.++ '[Count]))
               , (bs V.++ '[Count]) F.⊆  ('[BR.Year] V.++ as V.++ (bs V.++ '[Count]))
               , bs F.⊆ (bs V.++ '[Count])
               , F.ElemOf (bs V.++ '[Count]) Count
               , FI.RecVec  ('[BR.Year] V.++ as V.++ (cs V.++ '[Count]))
               )
            => BRK.AggFRec Bool cs bs
           -> FL.Fold (F.Record ('[BR.Year] V.++ as V.++ (bs V.++ '[Count]))) (F.FrameRec ('[BR.Year] V.++ as V.++ (cs V.++ '[Count])))
rekeyFrameF f =
  let collapse :: BRK.CollapseRec Bool '[Count] '[Count]
      collapse = BRK.dataFoldCollapseBool $ FF.foldAllConstrained @Num FL.sum
  in  FMR.concatFold
      $ FMR.mapReduceFold
      FMR.noUnpack
      (FMR.assignKeysAndData @('[BR.Year] V.++ as) @(bs V.++ '[Count]))
      (FMR.makeRecsWithKey id
        $ FMR.ReduceFold
        $ const
        $ BRK.aggFoldAllRec f collapse
      )


frameFromTableRows :: forall a b as bs. (FI.RecVec (as V.++ (bs V.++ '[Count])))
                   => (a -> F.Record as)
                   -> (b -> F.Record bs)
                   -> Int
                   -> Vec.Vector (KT.TableRow a (Map b Int))
                   -> F.FrameRec ('[BR.Year] V.++ as V.++ (bs V.++ '[Count]))
frameFromTableRows prefixToRec keyToRec year tableRows =
  let mapToRows :: Map b Int -> [F.Record (bs V.++ '[Count])]
      mapToRows = fmap (\(b, n) -> keyToRec b V.<+> (FT.recordSingleton @Count n)) . Map.toList
      oneRow (KT.TableRow p m) = let x = year F.&: prefixToRec p in fmap (x `V.rappend`) $ mapToRows m
      allRows = fmap oneRow tableRows
  in F.toFrame $ concat $ Vec.toList allRows
