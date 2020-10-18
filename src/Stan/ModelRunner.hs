{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
module Stan.ModelRunner
  (
    module Stan.ModelRunner
  , module CmdStan
--  , module CmdStan.Types
  ) where

import qualified CmdStan as CS
import qualified CmdStan.Types as CS
import qualified Stan.ModelConfig as SC
import qualified Stan.ModelBuilder as SB
import qualified Stan.RScriptBuilder as SR


import           CmdStan (StancConfig(..)
                         , makeDefaultStancConfig
                         , StanExeConfig(..)
                         , StanSummary
                         )

import qualified Knit.Report as K
import qualified Knit.Effect.Logger            as K
import qualified Knit.Effect.Serialize            as K
import qualified BlueRipple.Utilities.KnitUtils as BR

import           Control.Monad (when)
import qualified Data.Aeson.Encoding as A
import qualified Data.ByteString.Lazy as BL
import qualified Polysemy as P
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified System.Environment as Env
import qualified System.Directory as Dir


makeDefaultModelRunnerConfig :: K.KnitEffects r
                             => T.Text
                             -> T.Text
                             -> Maybe (SB.GeneratedQuantities, SB.StanModel) -- ^ Assume model file exists when Nothing.  Otherwise generate from this and use.
                             -> Maybe T.Text
                             -> Maybe T.Text 
                             -> Int
                             -> Maybe Int
                             -> Maybe Int
                             -> Maybe CS.StancConfig
                             -> K.Sem r SC.ModelRunnerConfig
makeDefaultModelRunnerConfig modelDirT modelNameT modelM datFileM outputFilePrefixM numChains numWarmupM numSamplesM stancConfigM = do
  let modelDirS = T.unpack modelDirT
      outputFilePrefix = maybe modelNameT id outputFilePrefixM
  case modelM of
    Nothing -> return ()
    Just (gq, m) -> do
      modelState <- K.liftKnit $ SB.renameAndWriteIfNotSame gq m modelDirT modelNameT
      case modelState of
        SB.New -> K.logLE K.Info $ "Given model was new."
        SB.Same -> K.logLE K.Info $ "Given model was the same as existing model file."
        SB.Updated newName -> K.logLE K.Info $ "Given model was different from exisiting.  Old one was moved to \"" <>  newName <> "\"."        
  let datFileS = maybe (SC.defaultDatFile modelNameT) T.unpack datFileM
  stanMakeConfig' <- K.liftKnit $ CS.makeDefaultMakeConfig (T.unpack $ SC.addDirT modelDirT modelNameT)
  let stanMakeConfig = stanMakeConfig' { CS.stancFlags = stancConfigM }
      stanExeConfigF chainIndex = (CS.makeDefaultSample (T.unpack modelNameT) chainIndex)
                                  { CS.inputData = Just (SC.addDirFP (modelDirS ++ "/data") $ datFileS)
                                  , CS.output = Just (SC.addDirFP (modelDirS ++ "/output") $ SC.outputFile outputFilePrefix chainIndex) 
                                  , CS.numSamples = numSamplesM
                                  , CS.numWarmup = numWarmupM
                                  }
  let stanOutputFiles = fmap (\n -> SC.outputFile outputFilePrefix n) [1..numChains]
  stanSummaryConfig <- K.liftKnit
                       $ CS.useCmdStanDirForStansummary (CS.makeDefaultSummaryConfig $ fmap (SC.addDirFP (modelDirS ++ "/output")) stanOutputFiles)
  return $ SC.ModelRunnerConfig
    stanMakeConfig
    stanExeConfigF
    stanSummaryConfig
    modelDirT
    modelNameT
    (T.pack datFileS)
    outputFilePrefix
    numChains
    True

modelCacheTime :: (K.KnitEffects r,  K.CacheEffectsD r) => SC.ModelRunnerConfig -> K.Sem r (K.ActionWithCacheTime r ())
modelCacheTime config = BR.fileDependency (T.unpack $ SC.addDirT (SC.mrcModelDir config) $ SB.modelFile $ SC.mrcModel config)

data RScripts = None | ShinyStan | Loo | Both deriving (Show, Eq, Ord)

writeRScripts :: RScripts -> SC.ModelRunnerConfig -> IO ()
writeRScripts rScripts config = do
  dirBase <- T.pack <$> Dir.getCurrentDirectory
  let modelDir = SC.mrcModelDir config
      scriptPrefix = SC.mrcOutputPrefix config
      writeShiny = SR.shinyStanScript config dirBase >>= T.writeFile (T.unpack $ modelDir <> "/R/" <> scriptPrefix <> "_shinystan.R") 
      writeLoo = SR.looScript config dirBase scriptPrefix 10 >>= T.writeFile (T.unpack $ modelDir <> "/R/" <> scriptPrefix <> ".R") 
  case rScripts of
    None -> return ()
    ShinyStan -> writeShiny
    Loo -> writeLoo
    Both -> writeShiny >> writeLoo

runModel :: (K.KnitEffects r,  K.CacheEffectsD r, K.DefaultSerializer b)
         => SC.ModelRunnerConfig
         -> RScripts
         -> SC.DataWrangler a b
         -> SC.ResultAction r a b c
         -> K.ActionWithCacheTime r a
         -> K.Sem r c
runModel config rScriptsToWrite dataWrangler makeResult cachedA = do
  let modelNameS = T.unpack $ SC.mrcModel config
      modelDirS = T.unpack $ SC.mrcModelDir config

  curModel_C <- BR.fileDependency (SC.addDirFP modelDirS $ T.unpack $ SB.modelFile $ SC.mrcModel config)    
  let outputFiles = fmap (\n -> SC.outputFile (SC.mrcOutputPrefix config) n) [1..(SC.mrcNumChains config)]
  checkClangEnv
  checkDir (SC.mrcModelDir config) >>= K.knitMaybe "Model directory is missing!" 
  createDirIfNecessary (SC.mrcModelDir config <> "/data") -- json inputs
  createDirIfNecessary (SC.mrcModelDir config <> "/output") -- csv model run output
  createDirIfNecessary (SC.mrcModelDir config <> "/R") -- scripts to load fit into R for shinyStan or loo.


  let indexCacheKey :: T.Text = "stan/index/" <> (SC.mrcOutputPrefix config) <> ".bin"
      jsonFP = SC.addDirFP (modelDirS ++ "/data") $ T.unpack $ SC.mrcDatFile config
  curJSON_C <- BR.fileDependency jsonFP      
  let indexJsonDeps = const <$> cachedA <*> curJSON_C  
  indices_C <- K.retrieveOrMake @K.DefaultSerializer @K.DefaultCacheData indexCacheKey indexJsonDeps $ \a -> do
    let (indices, makeJsonE) = dataWrangler a
    BR.updateIf curJSON_C cachedA $ \a -> do
      K.logLE K.Info $ "Indices/JSON data in \"" <> (T.pack jsonFP) <> "\" is missing or out of date.  Rebuilding..."
      jsonEncoding <- K.knitEither $ makeJsonE a 
      K.liftKnit . BL.writeFile jsonFP $ A.encodingToLazyByteString jsonEncoding
      K.logLE K.Info "Finished rebuilding JSON."
    return indices
  stanOutput_C <-  do
    curStanOutputs_C <- fmap BR.oldestUnit $ traverse (BR.fileDependency . SC.addDirFP (modelDirS ++ "/output")) outputFiles
    let runStanDeps = (,) <$> indices_C <*> curModel_C -- indices_C carries input data update time
        runOneChain chainIndex = do 
          let exeConfig = (SC.mrcStanExeConfigF config) chainIndex          
          K.logLE K.Info $ "Running " <> T.pack modelNameS <> " for chain " <> (T.pack $ show chainIndex)
          K.logLE K.Diagnostic $ "Command: " <> T.pack (CS.toStanExeCmdLine exeConfig)
          K.liftKnit $ CS.stan (SC.addDirFP modelDirS modelNameS) exeConfig
          K.logLE K.Info $ "Finished chain " <> (T.pack $ show chainIndex)
    res_C <- BR.updateIf (fmap Just curStanOutputs_C) runStanDeps $ \_ ->  do
      K.logLE K.Info "Stan outputs older than input data or model.  Rebuilding Stan exe and running."
      K.logLE K.Info $ "Make CommandLine: " <> (T.pack $ CS.makeConfigToCmdLine (SC.mrcStanMakeConfig config))
      K.liftKnit $ CS.make (SC.mrcStanMakeConfig config)
      maybe Nothing (const $ Just ()) . sequence <$> (K.sequenceConcurrently $ fmap runOneChain [1..(SC.mrcNumChains config)])
    K.ignoreCacheTime res_C >>= K.knitMaybe "There was an error running an MCMC chain."
    K.logLE K.Info "writing R scripts"
    K.liftKnit $ writeRScripts rScriptsToWrite config
    return res_C
  let resultDeps = (\a b c -> (a, b)) <$> cachedA <*> indices_C <*> stanOutput_C
  case makeResult of
    SC.UseSummary f -> do 
      K.logLE K.Diagnostic $ "Summary command: "
        <> (T.pack $ (CS.cmdStanDir . SC.mrcStanMakeConfig $ config) ++ "/bin/stansummary")
        <> " "
        <> T.intercalate " " (fmap T.pack (CS.stansummaryConfigToCmdLine (SC.mrcStanSummaryConfig config)))
      summary <- K.liftKnit $ CS.stansummary (SC.mrcStanSummaryConfig config)
      when (SC.mrcLogSummary config) $ K.logLE K.Info $ "Stan Summary:\n" <> (T.pack $ CS.unparsed summary)
      f summary resultDeps
    SC.SkipSummary f -> f resultDeps
    SC.DoNothing -> return ()

checkClangEnv ::  (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r) => K.Sem r ()
checkClangEnv = K.wrapPrefix "checkClangEnv" $ do
  clangBinDirM <- K.liftKnit $ Env.lookupEnv "CLANG_BINDIR"
  case clangBinDirM of
    Nothing -> K.logLE K.Info "CLANG_BINDIR not set. Using existing path for clang."
    Just clangBinDir -> do
      curPath <- K.liftKnit $ Env.getEnv "PATH"
      K.logLE K.Info $ "Current path: " <> (T.pack $ show curPath) <> ".  Adding " <> (T.pack $ show clangBinDir) <> " for llvm clang."
      K.liftKnit $ Env.setEnv "PATH" (clangBinDir ++ ":" ++ curPath)    
                           
createDirIfNecessary
  :: (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r)
  => T.Text
  -> K.Sem r ()
createDirIfNecessary dir = K.wrapPrefix "createDirIfNecessary" $ do
  K.logLE K.Diagnostic $ "Checking if cache path (\"" <> dir <> "\") exists."
  existsB <- P.embed $ (Dir.doesDirectoryExist (T.unpack dir))
  case existsB of
    True -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" exists."
      return ()
    False -> do
      K.logLE K.Info
        $  "Cache directory (\""
        <> dir
        <> "\") not found. Atttempting to create."
      P.embed
        $ Dir.createDirectoryIfMissing True (T.unpack dir)
{-# INLINEABLE createDirIfNecessary #-}

checkDir
  :: (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r)
  => T.Text
  -> P.Sem r (Maybe ())
checkDir dir =  K.wrapPrefix "checkDir" $ do
  K.logLE K.Diagnostic $ "Checking if cache path (\"" <> dir <> "\") exists."
  existsB <- P.embed $ (Dir.doesDirectoryExist (T.unpack dir))
  case existsB of
    True -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" exists."
      return $ Just ()
    False -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" is missing."
      return Nothing
