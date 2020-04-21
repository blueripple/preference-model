{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE QuasiQuotes               #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TupleSections             #-}
{-# OPTIONS_GHC  -fplugin=Polysemy.Plugin  #-}

module BlueRipple.Model.Turnout_MRP where

import qualified Control.Foldl                 as FL
import qualified Data.Map                      as M
import           Data.Maybe                     ( isJust
                                                , catMaybes
                                                , fromMaybe
                                                )

import qualified Data.Text                     as T
import qualified Frames                        as F
import qualified Frames.Melt                   as F
import qualified Frames.InCore                 as FI
import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.TypeLevel          as V

import qualified Frames.Transform              as FT
import qualified Frames.MapReduce              as FMR
import qualified Frames.Serialize              as FS

import qualified Knit.Report                   as K

import qualified Numeric.GLM.Bootstrap         as GLM

import qualified BlueRipple.Data.DataFrames    as BR
import qualified BlueRipple.Data.DemographicTypes
                                               as BR
import qualified BlueRipple.Data.ElectionTypes as ET
import qualified BlueRipple.Model.MRP     as BR
--import           MRP.CCES
--import           MRP.DeltaVPV                   ( DemVPV )

import qualified BlueRipple.Data.Keyed         as BR


mrpTurnout
  :: forall cc rs r
   . ( K.KnitEffects r
     , K.Member GLM.RandomFu r
     , ( (((cc V.++ '[BR.Year]) V.++ '[ET.ElectoralWeightSource]) V.++ '[ET.ElectoralWeightOf])
           V.++
           '[ET.ElectoralWeight]
       )
         ~
         (cc V.++ '[BR.Year, ET.ElectoralWeightSource, ET.ElectoralWeightOf, ET.ElectoralWeight])
     , FS.RecSerialize (cc V.++ '[BR.Year, ET.ElectoralWeightSource, ET.ElectoralWeightOf, ET.ElectoralWeight])
     , FI.RecVec (cc V.++ '[BR.Year, ET.ElectoralWeightSource, ET.ElectoralWeightOf, ET.ElectoralWeight])
     , V.RMap (cc V.++ '[BR.Year, ET.ElectoralWeightSource, ET.ElectoralWeightOf, ET.ElectoralWeight])
     , cc F.⊆ (BR.LocationCols V.++ cc V.++ BR.CountCols)
     , cc F.⊆ (cc V.++ BR.CountCols)
     , (cc V.++ BR.CountCols) F.⊆ (BR.LocationCols V.++ cc V.++ BR.CountCols)
     , FI.RecVec (cc V.++ BR.CountCols)
     , F.ElemOf (cc V.++ BR.CountCols) BR.Count
     , F.ElemOf (cc V.++ BR.CountCols) BR.MeanWeight
     , F.ElemOf (cc V.++ BR.CountCols) BR.UnweightedSuccesses
     , F.ElemOf (cc V.++ BR.CountCols) BR.VarWeight
     , F.ElemOf (cc V.++ BR.CountCols) BR.WeightedSuccesses
     , BR.FiniteSet (F.Record cc)
     , Show (F.Record (cc V.++ BR.CountCols))
     , V.RMap (cc V.++ BR.CountCols)
     , V.ReifyConstraint Show F.ElField (cc V.++ BR.CountCols)
     , V.RecordToList (cc V.++ BR.CountCols) 
     , V.RMap cc
     , V.ReifyConstraint Show V.ElField cc
     , V.RecordToList cc
     , Ord (F.Record cc)
     , F.ElemOf rs BR.StateAbbreviation
     )
  => Maybe T.Text
  -> ET.ElectoralWeightSourceT
  -> ET.ElectoralWeightOfT
  -> F.FrameRec rs
  -> (Int -> FL.Fold (F.Record rs) (F.FrameRec ('[BR.StateAbbreviation] V.++ cc V.++ BR.CountCols)))
  -> [BR.SimpleEffect cc]
  -> M.Map (F.Record cc) (M.Map (BR.SimplePredictor cc) Double)
  -> K.Sem
       r
       ( F.FrameRec
           ( '[BR.StateAbbreviation]
               V.++
               cc
               V.++
               '[BR.Year,  ET.ElectoralWeightSource, ET.ElectoralWeightOf, ET.ElectoralWeight]
           )
       )
mrpTurnout cacheTmpDirM ewSource ewOf datFrame votersF predictor catPredMap = do
  let lhToRecs year (BR.LocationHolder lp lkM predMap) =
        let recToAdd :: Double -> F.Record [BR.Year, ET.ElectoralWeightSource, ET.ElectoralWeightOf, ET.ElectoralWeight]
            recToAdd w = year F.&: (ET.ewRec ewSource ewOf w)
            addCols w r = r `V.rappend` (recToAdd w)
            g x =
              let lk = fromMaybe (lp F.&: V.RNil) x
              in  fmap (\(ck, p) -> addCols p (lk `V.rappend` ck))
                  $ M.toList predMap
        in  g lkM
      lhsToFrame y = F.toFrame . concat . fmap (lhToRecs y)
  K.logLE K.Info "(Turnout) Doing MR..."
  let cacheIt cn fa = 
        case cacheTmpDirM of
          Nothing -> fa
          Just tmpDir -> K.retrieveOrMakeTransformed
                         (fmap FS.toS . FL.fold FL.list)
                         (F.toFrame . fmap FS.fromS)
                         ("mrp/tmp/" <> tmpDir <> "/" <> cn)
                         fa
      wYearActions = fmap
                     (\y -> cacheIt
                       ("turnout" <> T.pack (show y))
                       (   lhsToFrame y 
                         <$> (BR.predictionsByLocation (return datFrame)
                              (votersF y)
                              predictor
                              catPredMap
                             )
                       )
                     )
                     [2008, 2010, 2012, 2014, 2016, 2018]      
  allResultsM <- sequence <$> K.sequenceConcurrently wYearActions
  case allResultsM of
    Nothing -> K.knitError "Error in MR run (mrpPrefs)."
    Just allResults -> return $ mconcat allResults