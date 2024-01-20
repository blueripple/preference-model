{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE StrictData #-}

module Main
  (main)
where

import qualified BlueRipple.Model.TSP_Religion.Model as RM
import qualified BlueRipple.Model.Election2.DataPrep as DP
import qualified BlueRipple.Model.Election2.ModelCommon as MC
--import BlueRipple.Model.Election2.ModelCommon (ModelConfig)
--import qualified BlueRipple.Model.Election2.ModelCommon2 as MC2
import qualified BlueRipple.Model.Election2.ModelRunner as MR
import qualified BlueRipple.Model.Demographic.DataPrep as DDP
import qualified BlueRipple.Model.Demographic.EnrichCensus as DMC
import qualified BlueRipple.Model.Demographic.TableProducts as DTP
import qualified BlueRipple.Data.Loaders as BRL

import qualified BlueRipple.Configuration as BR
import qualified BlueRipple.Utilities.KnitUtils as BRK
import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.GeographicTypes as GT
import qualified BlueRipple.Data.ElectionTypes as ET
import qualified BlueRipple.Data.ModelingTypes as MT
import qualified BlueRipple.Data.CCES as CCES
import qualified BlueRipple.Data.ACS_PUMS as ACS
import qualified BlueRipple.Data.DataFrames as BR
import qualified BlueRipple.Data.CensusLoaders as BRC
import qualified BlueRipple.Data.CensusTables as BRC
import qualified BlueRipple.Utilities.FramesUtils as BRF
import qualified BlueRipple.Utilities.KnitUtils as BR

import qualified Knit.Report as K
import qualified Knit.Effect.AtomicCache as KC
import qualified Text.Pandoc.Error as Pandoc
import qualified System.Console.CmdArgs as CmdArgs
import qualified Colonnade as C


import qualified Stan.ModelBuilder as SMB
import qualified Stan.ModelRunner as SMR
import qualified Stan.ModelBuilder.TypedExpressions.Types as TE
import qualified Stan.ModelBuilder.TypedExpressions.Statements as TE
import qualified Stan.Parameters as SP
import qualified Stan.ModelConfig as SC
import qualified Stan.RScriptBuilder as SR
import qualified Stan.ModelBuilder.BuildingBlocks as SBB
import qualified Stan.ModelBuilder.BuildingBlocks.GroupAlpha as SG
import qualified Stan.ModelBuilder.DesignMatrix as DM
import qualified CmdStan as CS

import qualified Frames as F
import qualified Frames.Melt as F
import qualified Frames.MapReduce as FMR
import qualified Frames.Transform as FT
import qualified Frames.SimpleJoins as FJ
import qualified Frames.Constraints as FC
import qualified Frames.Streamly.TH as FS
import qualified Frames.Streamly.InCore as FI
import qualified Frames.Streamly.CSV as FCSV
--import qualified Frames.Streamly.Transform as FST

import Frames.Streamly.Streaming.Streamly (StreamlyStream, Stream)
import qualified Frames.Serialize as FS

import qualified Control.Foldl as FL
import qualified Control.Foldl.Statistics as FLS
import Control.Lens (view, (^.))

import qualified Flat
import qualified Data.IntMap.Strict as IM
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vinyl.Functor as V

import qualified Text.Printf as PF
import qualified Text.Read as TR

FS.declareColumn "WhiteVAP" ''Int
FS.declareColumn "WhiteEv" ''Int
FS.declareColumn "TSPStateId" ''Text
FS.declareColumn "Chamber" ''Text

templateVars ∷ Map String String
templateVars =
  M.fromList
    [ ("lang", "English")
    , ("site-title", "Blue Ripple Politics")
    , ("home-url", "https://www.blueripplepolitics.org")
    --  , ("author"   , T.unpack yamlAuthor)
    ]

pandocTemplate ∷ K.TemplatePath
pandocTemplate = K.FullySpecifiedTemplatePath "pandoc-templates/blueripple_basic.html"

dmr ::  DM.DesignMatrixRow (F.Record DP.LPredictorsR)
dmr = MC.tDesignMatrixRow_d

survey :: MC.TurnoutSurvey (F.Record DP.CESByCDR)
survey = MC.CESSurvey

aggregation :: MC.SurveyAggregation TE.ECVec
aggregation = MC.WeightedAggregation MC.ContinuousBinomial

alphaModel :: MC.Alphas
alphaModel = MC.St_A_S_E_R_StA  --MC.St_A_S_E_R_AE_AR_ER_StR

type SLDKeyR = '[GT.StateAbbreviation] V.++ BRC.LDLocationR
type ModeledR = SLDKeyR V.++ '[MR.ModelCI]

main :: IO ()
main = do
  cmdLine ← CmdArgs.cmdArgsRun BR.commandLine
  pandocWriterConfig ←
    K.mkPandocWriterConfig
    pandocTemplate
    templateVars
    (BRK.brWriterOptionsF . K.mindocOptionsF)
  let cacheDir = ".flat-kh-cache"
      knitConfig ∷ K.KnitConfig BRK.SerializerC BRK.CacheData Text =
        (K.defaultKnitConfig $ Just cacheDir)
          { K.outerLogPrefix = Just "2023-TSP"
          , K.logIf = BR.knitLogSeverity $ BR.logLevel cmdLine -- K.logDiagnostic
          , K.pandocWriterConfig = pandocWriterConfig
          , K.serializeDict = BRK.flatSerializeDict
          , K.persistCache = KC.persistStrictByteString (\t → toString (cacheDir <> "/" <> t))
          }
  resE ← K.knitHtmls knitConfig $ do
    K.logLE K.Info $ "Command Line: " <> show cmdLine
    let postInfo = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished Nothing)
        psName = "GivenWWH"
        psType = RM.PSGiven "E" psName ((`elem` [DT.R5_WhiteNonHispanic, DT.R5_Hispanic]) . view DT.race5C)
        cacheStructure cy = MR.CacheStructure (Right $ "model/evangelical/stan/CES" <> show (CCES.cesYear cy)) (Right "model/evangelical")
                            psName () ()
        modelConfig am = RM.ModelConfig aggregation am (contramap F.rcast dmr)
        modeledToCSVFrame = F.toFrame . fmap (\(k, v) -> k F.<+> FT.recordSingleton @MR.ModelCI v) . M.toList . MC.unPSMap . fst
    modeledACSBySLDPSData_C <- modeledACSBySLD cmdLine
--    districtPSData <- K.ignoreCacheTime modeledACSBySLDPSData_C
    let dBDInnerF :: FL.Fold (F.Record '[DT.Race5C, DT.PopCount]) (F.Record [DT.PopCount, WhiteVAP])
        dBDInnerF =
          let pop = view DT.popCount
              race = view DT.race5C
              isWhite = (== DT.R5_WhiteNonHispanic) . race
              popF = FL.premap pop FL.sum
              whiteF = FL.prefilter isWhite popF
          in (\p w -> p F.&: w F.&: V.RNil) <$> popF <*> whiteF
        dataByDistrictF = FMR.concatFold
                          $ FMR.mapReduceFold
                          FMR.noUnpack
                          (FMR.assignKeysAndData @SLDKeyR @[DT.Race5C, DT.PopCount])
                          (FMR.foldAndAddKey dBDInnerF)
    dataByDistrict <-  fmap (FL.fold dataByDistrictF . DP.unPSData) $ K.ignoreCacheTime modeledACSBySLDPSData_C

    let addDistrictData :: K.KnitEffects r
                        =>  F.FrameRec (SLDKeyR V.++ '[MR.ModelCI])
                        -> K.Sem r (F.FrameRec (SLDKeyR V.++ [MR.ModelCI, DT.PopCount, WhiteVAP, WhiteEv]))
        addDistrictData x =  do
          let (joined, missing) = FJ.leftJoinWithMissing @SLDKeyR x dataByDistrict
          when (not $ null missing) $ K.logLE K.Error $ "Missing keys in result/district data join=" <> show missing
          let addEv r = r F.<+> FT.recordSingleton @WhiteEv (round $ MT.ciMid (r ^. MR.modelCI) * realToFrac (r ^. DT.popCount))
          pure $ fmap addEv joined
--    modeledEvangelical_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) cmdLine psType (modelConfig MC.St_A_S_E_R) modeledACSBySLDPSData_C
--    modeledEvangelical_AR_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) cmdLine psType (modelConfig MC.St_A_S_E_R_AR) modeledACSBySLDPSData_C
--    modeledEvangelical_StA_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) cmdLine psType (modelConfig MC.St_A_S_E_R_StA) modeledACSBySLDPSData_C
    modeledEvangelical22_StR_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2022 (cacheStructure CCES.CES2022) cmdLine psType (modelConfig MC.St_A_S_E_R_StR) modeledACSBySLDPSData_C
--    modeledEvangelical20_StR_C <- RM.runEvangelicalModel @SLDKeyR CCES.CES2020 (cacheStructure CCES.CES2020) cmdLine psType (modelConfig MC.St_A_S_E_R_StR) modeledACSBySLDPSData_C
    let compareOn f x y = compare (f x) (f y)
        compareRows x y = compareOn (view GT.stateAbbreviation) x y
                          <> compareOn (view GT.districtTypeC) x y
                          <> GT.districtNameCompare (x ^. GT.districtName) (y ^. GT.districtName)
        csvSort = F.toFrame . sortBy compareRows . FL.fold FL.list
--    modeledEvangelical <-
--    K.ignoreCacheTime modeledEvangelical_C >>= writeModeled "modeledEvangelical_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
--    K.ignoreCacheTime modeledEvangelical_AR_C >>= writeModeled "modeledEvangelical_AR_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
--    K.ignoreCacheTime modeledEvangelical_StA_C >>= writeModeled "modeledEvangelical_StA_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
    K.ignoreCacheTime modeledEvangelical22_StR_C
      >>= fmap (fmap addTSPId) . addDistrictData . csvSort . fmap F.rcast . modeledToCSVFrame
      >>= writeModeled "modeledEvangelical22_StR_GivenWWH" . fmap F.rcast
--    K.ignoreCacheTime modeledEvangelical20_StR_C >>= writeModeled "modeledEvangelical20_StR_GivenWWH" . csvSort . fmap F.rcast . modeledToCSVFrame
--    let modeledEvangelicalFrame = modeledToCSVFrame modeledEvangelical
--    writeModeled "modeledEvangelical_StA_GivenWWH" $ fmap F.rcast modeledEvangelicalFrame
--    K.logLE K.Info $ show $ MC.unPSMap $ fst $ modeledEvangelical

  case resE of
    Right namedDocs →
      K.writeAllPandocResultsWithInfoAsHtml "" namedDocs
    Left err → putTextLn $ "Pandoc Error: " <> Pandoc.renderError err

lowerHouseNameMap :: Map Text (Text, Text)
lowerHouseNameMap = M.fromList [("CA", ("Assembly", "A"))
                               ,("NJ", ("Assembly", "A"))
                               ,("NV", ("Assembly", "A"))
                               ,("NY", ("Assembly", "A"))
                               ,("NY", ("Assembly", "A"))
                               ,("WI", ("Assembly", "A"))
                               ]

upperHouseNameMap :: Map Text (Text, Text)
upperHouseNameMap = mempty

addTSPId :: FC.ElemsOf rs [GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName] => F.Record rs -> F.Record (rs V.++ '[TSPStateId, Chamber])
addTSPId r = let (tspId, chamber) = tspIds r in r F.<+> (FT.recordSingleton @TSPStateId tspId) F.<+> (FT.recordSingleton @Chamber chamber)

tspIds :: FC.ElemsOf rs [GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName] => F.Record rs -> (Text, Text)
tspIds r =
  let sa = r ^. GT.stateAbbreviation
      dt = r ^. GT.districtTypeC
      (prefix, chamber) = case dt of
        GT.StateLower -> fromMaybe ("H", "House") $ M.lookup sa lowerHouseNameMap
        GT.StateUpper -> fromMaybe ("S", "Senate") $ M.lookup sa upperHouseNameMap
      n = r ^. GT.districtName
      nameFix = fromMaybe (const $ zeroPadName 3) $ M.lookup sa nameFixMap
  in (sa <> " " <> prefix <> "D-" <> nameFix dt n, sa <> " " <> chamber)

zeroPadName :: Int -> Text -> Text
zeroPadName n t = let l = T.length t in (if l < n then T.replicate (n - l) "0" else "") <> t

writeModeled :: (K.KnitEffects r)
             => Text -> F.FrameRec [TSPStateId, GT.StateAbbreviation, Chamber, MR.ModelCI, DT.PopCount, WhiteVAP, WhiteEv] -> K.Sem r ()
writeModeled csvName modeledEv = do
  let wText = FCSV.formatTextAsIs
      printNum n m = PF.printf ("%" <> show n <> "." <> show m <> "g")
      wPrintf :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wPrintf n m = FCSV.liftFieldFormatter $ toText @String . printNum n m
--      wPrint :: (V.KnownField t, V.Snd t ~ Double) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
--      wPrintf n m = FCSV.liftFieldFormatter $ toText @String . printNum n m
      wCI :: (V.KnownField t, V.Snd t ~ MT.ConfidenceInterval) => Int -> Int -> V.Lift (->) V.ElField (V.Const Text) t
      wCI n m = FCSV.liftFieldFormatter
                $ toText @String .
                \ci -> printNum n m (100 * MT.ciLower ci) <> ","
                       <> printNum n m (100 * MT.ciMid ci) <> ","
                       <> printNum n m (100 * MT.ciUpper ci)
      formatModeled = FCSV.formatTextAsIs
                       V.:& FCSV.formatTextAsIs
                       V.:& FCSV.formatTextAsIs
                       V.:& wCI 2 1
                       V.:& FCSV.formatWithShow
                       V.:& FCSV.formatWithShow
                       V.:& FCSV.formatWithShow
                       V.:& V.RNil
      newHeaderMap = M.fromList [("StateAbbreviation", "state_code")
                                , ("TSPStateId", "state_district_id")
                                , ("Chamber", "chamber_name")
                                , ("DistrictTypeC","District Type")
                                ,("DistrictName","District Name")
                                ,("ModelCI","5%,50%,95%")
                                ,("PopCount", "CVAP")
                                ,("WhiteEv", "White Evangelicals")
                                ,("WhiteVAP", "White Voters")
                                ]
  K.liftKnit @IO $ FCSV.writeLines (toString $ "../forTSP/" <> csvName <> ".csv") $ FCSV.streamSV' @_ @(StreamlyStream Stream) newHeaderMap formatModeled "," $ FCSV.foldableToStream modeledEv

nameFixMap :: Map Text (GT.DistrictType -> Text -> Text)
nameFixMap = M.fromList [("NH", nhNameFix), ("VT", vtNameFix), ("MA", maNameFix)]

nhNameFix :: GT.DistrictType -> Text -> Text
nhNameFix GT.StateLower x =
  let xPrefix = T.take 2 x
      xNumText = zeroPadName 2 (T.drop 2 x)
      regions = ["BELKNAP", "CARROL", "CHESHIRE", "COOS", "GRAFTON", "HILLSBOROUGH", "MERRIMACK", "ROCKINGHAM", "STRAFFORD", "SULLIVAN"]
      regionMap = M.fromList $ zip (fmap (T.take 2) regions) regions
      fullRegion p = fromMaybe p $ M.lookup p regionMap
  in fullRegion xPrefix  <> " " <> xNumText
nhNameFix _ x = x

vtNameFix :: GT.DistrictType -> Text -> Text
vtNameFix _ n =
  let simpleRegions = ["ADDISON", "RUTLAND", "BENNINGTON", "CHITTENDEN", "CALEDONIA", "ESSEX", "WASHINGTON", "FRANKLIN", "ORLEANS", "LAMOILLE", "ORANGE"]
      regionMap = (M.fromList $ zip (fmap (T.take 3) simpleRegions) simpleRegions)
                  <> M.fromList [("0GI","GRAND ISLE"), ("GI", "GRAND ISLE"), ("WDH", "WINDHAM"), ("ESX", "ESSEX"), ("WDR", "WINDSOR"), ("WSR", "WINDSOR")]
                  <> M.fromList [("N", "North"), ("C", "CENTRAL"), ("SE", "SOUTHEAST")]
      fixOne x = fromMaybe x $ M.lookup x regionMap
      fix = T.intercalate "-" . fmap fixOne . T.splitOn "-"
  in fix n

maNameFix :: GT.DistrictType -> Text -> Text
maNameFix GT.StateUpper n =
  let maSenateNameMap = [("D1", "Berkshire, Hampshire, Franklin And Hampden")
                        ,("D2", "Second Hampden And Hampshire")
                        ,("D3", "Hampden")
                        ,("D4", "First Hampden And Hampshire")
                        ,("D5", "Hampshire, Franklin And Worcester")
                        ,("D6", "Worcester, Hampden, Hampshire And MiddleSex")
                        ,("D7", "Worcester And Norfolk")
                        ]
maNameFix _ x = x

modeledACSBySLD :: (K.KnitEffects r, BRK.CacheEffects r) => BR.CommandLine -> K.Sem r (K.ActionWithCacheTime r (DP.PSData SLDKeyR))
modeledACSBySLD cmdLine = do
  (jointFromMarginalPredictorCSR_ASR_C, _) <- DDP.cachedACSa5ByPUMA  ACS.acs1Yr2012_21 2021 -- most recent available
                                                 >>= DMC.predictorModel3 @'[DT.CitizenC] @'[DT.Age5C] @DMC.SRCA @DMC.SR
                                                 (Right "CSR_ASR_ByPUMA")
                                                 (Right "model/demographic/csr_asr_PUMA")
                                                 False -- use model not just mean
                                                 cmdLine Nothing Nothing . fmap (fmap F.rcast)
  (jointFromMarginalPredictorCASR_ASE_C, _) <- DDP.cachedACSa5ByPUMA ACS.acs1Yr2012_21 2021 -- most recent available
                                                  >>= DMC.predictorModel3 @[DT.CitizenC, DT.Race5C] @'[DT.Education4C] @DMC.ASCRE @DMC.AS
                                                  (Right "CASR_SER_ByPUMA")
                                                  (Right "model/demographic/casr_ase_PUMA")
                                                  False -- use model, not just mean
                                                  cmdLine Nothing Nothing . fmap (fmap F.rcast)
  (acsCASERBySLD, _products) <- BRC.censusTablesForSLDs 2024 BRC.TY2021
                                >>= DMC.predictedCensusCASER' (DTP.viaNearestOnSimplex) (Right "model/election2/sldDemographics")
                                jointFromMarginalPredictorCSR_ASR_C
                                jointFromMarginalPredictorCASR_ASE_C
  BRK.retrieveOrMakeD "model/election2/data/sldPSData.bin" acsCASERBySLD
    $ \x -> DP.PSData . fmap F.rcast <$> (BRL.addStateAbbrUsingFIPS $ F.filterFrame ((== DT.Citizen) . view DT.citizenC) x)
