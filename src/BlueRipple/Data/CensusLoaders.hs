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

censusDataDir :: Text
censusDataDir = "../bigData/Census"

data CensusTablesByCD = CensusTablesByCD { ageSexRace :: F.FrameRec (CDRow [BRC.Age14C, DT.SexC, DT.RaceAlone4C])
                                         , hispanicAgeSex :: F.FrameRec (CDRow [BRC.Age14C, DT.SexC])
                                         , sexRaceCitizenShip :: F.FrameRec (CDRow [DT.SexC, DT.RaceAlone4C, BRC.CitizenshipC])
                                         , hispanicSexCitizenship :: F.FrameRec (CDRow [DT.SexC, BRC.CitizenshipC])
                                         , sexEducationRace :: F.FrameRec (CDRow [DT.SexC,  BRC.Education4C, DT.RaceAlone4C])
                                         , hispanicSexEducation :: F.FrameRec (CDRow [DT.SexC,  BRC.Education4C])
                                         }

instance Semigroup CensusTablesByCD where
  (CensusTablesByCD a1 a2 a3 a4 a5 a6) <> (CensusTablesByCD b1 b2 b3 b4 b5 b6) =
    CensusTablesByCD (a1 <> b1) (a2 <> b2) (a3 <> b3) (a4 <> b4) (a5 <> b5) (a6 <> b6)

instance S.Serialize CensusTablesByCD where
  put (CensusTablesByCD f1 f2 f3 f4 f5 f6) = S.put (FS.SFrame f1, FS.SFrame f2, FS.SFrame f3, FS.SFrame f4, FS.SFrame f5, FS.SFrame f6)
  get = (\(sf1, sf2, sf3, sf4, sf5, sf6)
          -> CensusTablesByCD
             (FS.unSFrame sf1)
             (FS.unSFrame sf2)
             (FS.unSFrame sf3)
             (FS.unSFrame sf4)
             (FS.unSFrame sf5)
             (FS.unSFrame sf6)
        )
        <$> S.get

instance Flat.Flat CensusTablesByCD where
  size (CensusTablesByCD f1 f2 f3 f4 f5 f6) n = Flat.size (FS.SFrame f1, FS.SFrame f2, FS.SFrame f3, FS.SFrame f4, FS.SFrame f5, FS.SFrame f6) n
  encode (CensusTablesByCD f1 f2 f3 f4 f5 f6) = Flat.encode (FS.SFrame f1, FS.SFrame f2, FS.SFrame f3, FS.SFrame f4, FS.SFrame f5, FS.SFrame f6)
  decode = (\(sf1, sf2, sf3, sf4, sf5, sf6)
             -> CensusTablesByCD
                (FS.unSFrame sf1)
                (FS.unSFrame sf2)
                (FS.unSFrame sf3)
                (FS.unSFrame sf4)
                (FS.unSFrame sf5)
                (FS.unSFrame sf6)
           )
           <$> Flat.decode


type CDRow rs = '[BR.Year] V.++ BRC.CDPrefixR V.++ rs V.++ '[Count]

censusTablesByDistrict  :: (K.KnitEffects r
                              , BR.CacheEffects r)
                           => K.Sem r (K.ActionWithCacheTime r CensusTablesByCD)
censusTablesByDistrict = do
  let fileByYear = [(2016, censusDataDir <> "/cd115Raw.csv"), (2018, censusDataDir <> "/cd116Raw.csv")]
      tableDescriptions = KT.allTableDescriptions BRC.sexByAge BRC.sexByAgePrefix
                          <> KT.tableDescriptions BRC.sexByAge BRC.hispanicSexByAgePrefix
                          <> KT.allTableDescriptions BRC.sexByCitizenship BRC.sexByCitizenshipPrefix
                          <> KT.tableDescriptions BRC.sexByCitizenship BRC.hispanicSexByCitizenshipPrefix
                          <> KT.allTableDescriptions BRC.sexByEducation BRC.sexByEducationPrefix
                          <> KT.tableDescriptions BRC.sexByEducation BRC.hispanicSexByEducationPrefix
      makeFrame year tableDF prefix keyRec vTableRows = do
        vTRs <- K.knitEither $ traverse (\tr -> KT.typeOneTable tableDF tr prefix) vTableRows
        return $ frameFromTableRows BRC.unCDPrefix keyRec year vTRs
      makeConsolidatedFrame year tableDF prefixF keyRec vTableRows = do
        vTRs <- K.knitEither $ traverse (KT.consolidateTables tableDF prefixF) vTableRows
        return $ frameFromTableRows BRC.unCDPrefix keyRec year vTRs
      doOneYear (year, f) = do
        (_, vTableRows) <- K.knitEither =<< (K.liftKnit $ KT.decodeCSVTablesFromFile @BRC.CDPrefix tableDescriptions $ toString f)
        K.logLE K.Diagnostic $ "Loaded and parsed \"" <> f <> "\" for " <> show year <> "."
        K.logLE K.Diagnostic $ "Building Race/Ethnicity by Sex by Age Tables..."
        fRaceBySexByAge <- makeConsolidatedFrame year BRC.sexByAge BRC.sexByAgePrefix raceBySexByAgeKeyRec vTableRows
        fHispanicSexByAge <- makeFrame year BRC.sexByAge BRC.hispanicSexByAgePrefix sexByAgeKeyRec vTableRows
        K.logLE K.Diagnostic $ "Building Race/Ethnicity by Sex by Citizenship Tables..."
        fRaceBySexByCitizenship <- makeConsolidatedFrame year BRC.sexByCitizenship BRC.sexByCitizenshipPrefix raceBySexByCitizenshipKeyRec vTableRows
        fHispanicSexByCitizenship <- makeFrame year BRC.sexByCitizenship BRC.hispanicSexByCitizenshipPrefix sexByCitizenshipKeyRec vTableRows
        K.logLE K.Diagnostic $ "Building Race/Ethnicity by Sex by Education Tables..."
        fRaceBySexByEducation <- makeConsolidatedFrame year BRC.sexByEducation BRC.sexByEducationPrefix raceBySexByEducationKeyRec vTableRows
        fHispanicSexByEducation <- makeFrame year BRC.sexByEducation BRC.hispanicSexByEducationPrefix sexByEducationKeyRec vTableRows
        return $ CensusTablesByCD
          fRaceBySexByAge
          fHispanicSexByAge
          fRaceBySexByCitizenship
          fHispanicSexByCitizenship
          fRaceBySexByEducation
          fHispanicSexByEducation
  dataDep <- traverse (K.fileDependency . toString . snd) fileByYear
  K.retrieveOrMake "data/Census/tables.bin" dataDep $ const $ fmap mconcat $ traverse doOneYear fileByYear

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
