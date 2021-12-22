{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
module Stan.ModelConfig where

import qualified CmdStan as CS
import qualified CmdStan.Types as CS
import qualified Knit.Report as K
--import qualified Knit.Effect.Serialize as K
import qualified Data.Aeson.Encoding as A
import qualified Data.Map as M
import qualified Data.Text as T

data SamplesKey = ModelSamples | GQSamples Text deriving (Show, Ord, Eq)

type SamplesPrefixMap = Map SamplesKey Text

data RunnerInputNames = RunnerInputNames
  { rinModelDir :: Text
  , rinModel :: Text
  , rinGQ :: Maybe Text
  , rinData :: Text
  }  deriving (Show, Ord, Eq)

data StanMCParameters = StanMCParameters
  { smcNumChains :: Int
  , smcNumThreads :: Int
  , smcNumWarmupM :: Maybe Int
  , smcNumSamplesM :: Maybe Int
  , smcAdaptDeltaM :: Maybe Double
  , smcMaxTreeDepth :: Maybe Int
  } deriving (Show, Eq, Ord)

data ModelRunnerConfig = ModelRunnerConfig
  { mrcStanMakeConfig :: CS.MakeConfig
  , mrcStanExeConfig :: CS.StanExeConfig
  , mrcStanSummaryConfig :: CS.StansummaryConfig
  , mrcInputNames :: RunnerInputNames
  , mrcStanMCParameters :: StanMCParameters
  , mrcLogSummary :: Bool
  , mrcRunDiagnose :: Bool
  }

mrcModelDir :: ModelRunnerConfig -> Text
mrcModelDir = rinModelDir . mrcInputNames

samplesPrefixCacheKey :: RunnerInputNames -> Text
samplesPrefixCacheKey rin = rinModelDir rin <> "/" <> rinModel rin <> "/" <> rinData rin

modelFileName :: RunnerInputNames -> Text
modelFileName rin = rinModel rin <> ".stan"

addModelDirectory :: RunnerInputNames -> Text -> Text
addModelDirectory rin x = rinModelDir rin <> "/" <> x

modelDependency :: K.KnitEffects r => RunnerInputNames -> K.Sem r (K.ActionWithCacheTime r ())
modelDependency rin = K.fileDependency (toString modelFile)  where
  modelFile = addModelDirectory rin (modelFileName rin)

modelDataFileName :: RunnerInputNames -> Text
modelDataFileName rin = rinData rin <> ".json"

gqDataFileName :: RunnerInputNames -> Maybe Text
gqDataFileName rin = fmap (<> ".json") $ rinGQ rin

modelDataDependency :: K.KnitEffects r => RunnerInputNames -> K.Sem r (K.ActionWithCacheTime r ())
modelDataDependency rin = K.fileDependency $ (toString $ addModelDirectory rin $ ("data/" <> modelDataFileName rin))

gqDataDependency :: K.KnitEffects r => RunnerInputNames -> K.Sem r (Maybe (K.ActionWithCacheTime r ()))
gqDataDependency rin = case gqDataFileName rin of
  Nothing -> return Nothing
  Just gqName -> do
    dep <- K.fileDependency $ (toString $ addModelDirectory rin $ ("data/" <> gqName))
    return $ Just dep

dataDependency :: K.KnitEffects r => RunnerInputNames -> K.Sem r (K.ActionWithCacheTime r ())
dataDependency rin = do
  modelDataDep <- modelDataDependency rin
  gqDataDepM <- gqDataDependency rin
  case gqDataDepM of
    Nothing -> return modelDataDep
    Just gqDataDep -> return $ const <$> modelDataDep <*> gqDataDep

type KnitStan st cd r = (K.KnitEffects r, K.CacheEffects st cd Text r, st SamplesPrefixMap)

-- if the cached map is outdated, return an empty one
samplesPrefixCache :: forall st cd r. KnitStan st cd r
                   => RunnerInputNames
                   -> K.Sem r (K.ActionWithCacheTime r SamplesPrefixMap)
samplesPrefixCache rin = do
  modelDataDep <- modelDataDependency rin
  modelDep <- modelDependency rin
  let deps = const <$> modelDataDep <*> modelDep
  K.retrieveOrMake @st @cd (samplesPrefixCacheKey rin) deps $ const $ return mempty

modelGQName :: RunnerInputNames -> Text
modelGQName rin =
  rinModel rin
  <> "_" <> rinData rin
  <> maybe "" ("_" <>) (rinGQ rin)

-- This is not atomic so care should be used that only one thread uses it at a time.
-- I should fix this in knit-haskell where I could provide an atomic update.
samplesPrefix ::  forall st cd r. KnitStan st cd r
              => RunnerInputNames
              -> SamplesKey
              -> K.Sem r (K.ActionWithCacheTime r Text)
samplesPrefix rin key = do
  samplePrefixCache_C <- samplesPrefixCache @st @cd rin
  samplePrefixCache <- K.ignoreCacheTime samplePrefixCache_C
  p <- case M.lookup key samplePrefixCache of
    Nothing -> do -- missing so use prefix from current setup
      let prefix = modelGQName rin
      K.store @st @cd (samplesPrefixCacheKey rin) $ M.insert key prefix samplePrefixCache
      return prefix
    Just prefix -> return prefix -- exists, so use those files
  return $ p <$ samplePrefixCache_C

-- This is not atomic so care should be used that only one thread uses it at a time.
-- I should fix this in knit-haskell where I could provide an atomic update.
samplesFileNames ::  forall st cd r. KnitStan st cd r
                 => ModelRunnerConfig
                 -> SamplesKey
                 -> K.Sem r (K.ActionWithCacheTime r [Text])
samplesFileNames config key = do
  let rin = mrcInputNames config
      numChains = smcNumChains $ mrcStanMCParameters config
  prefix_C <- samplesPrefix @st @cd rin key
  prefix <- K.ignoreCacheTime prefix_C
  let files = addModelDirectory rin . (\n -> "output/" <> prefix <> "_" <> show n <> ".csv") <$> [1..numChains]
  return $ files <$ prefix_C

-- This is not atomic so care should be used that only one thread uses it at a time.
-- I should fix this in knit-haskell where I could provide an atomic update.
modelSamplesFileNames :: forall st cd r. KnitStan st cd r
                      => ModelRunnerConfig
                      -> K.Sem r (K.ActionWithCacheTime r [Text])
modelSamplesFileNames config = samplesFileNames @st @cd config ModelSamples

-- This is not atomic so care should be used that only one thread uses it at a time.
-- I should fix this in knit-haskell where I could provide an atomic update.
gqSamplesFileNames :: forall st cd r. KnitStan st cd r
                   => ModelRunnerConfig
                   -> K.Sem r (K.ActionWithCacheTime r [Text])
gqSamplesFileNames config = do
  case rinGQ (mrcInputNames config) of
    Nothing -> return $ pure []
    Just gqName -> samplesFileNames @st @cd config (GQSamples gqName)

setSigFigs :: Int -> ModelRunnerConfig -> ModelRunnerConfig
setSigFigs sf mrc = let sc = mrcStanSummaryConfig mrc in mrc { mrcStanSummaryConfig = sc { CS.sigFigs = Just sf } }

noLogOfSummary :: ModelRunnerConfig -> ModelRunnerConfig
noLogOfSummary sc = sc { mrcLogSummary = False }

noDiagnose :: ModelRunnerConfig -> ModelRunnerConfig
noDiagnose sc = sc { mrcRunDiagnose = False }

-- produce indexes and json producer from the data as well as a data-set to predict.
data DataIndexerType (b :: Type) where
  NoIndex :: DataIndexerType ()
  TransientIndex :: DataIndexerType b
  CacheableIndex :: (ModelRunnerConfig -> T.Text) -> DataIndexerType b

-- pattern matching on the first brings the constraint into scope
-- This allows us to choose to not have the constraint unless we need it.
data Cacheable st b where
  Cacheable :: st (Either Text b) => Cacheable st b
  UnCacheable :: Cacheable st b

data DataWrangler a b p where
  Wrangle :: DataIndexerType b
          -> (a -> (Either T.Text b, a -> Either T.Text A.Series))
          -> DataWrangler a b ()
  WrangleWithPredictions :: DataIndexerType b
                         -> (a -> (Either T.Text b, a -> Either T.Text A.Series))
                         -> (Either T.Text b -> p -> Either T.Text A.Series)
                         -> DataWrangler a b p

noPredictions :: DataWrangler a b p -> DataWrangler a b ()
noPredictions w@(Wrangle _ _) = w
noPredictions (WrangleWithPredictions x y _) = Wrangle x y


dataIndexerType :: DataWrangler a b p -> DataIndexerType b
dataIndexerType (Wrangle i _) = i
dataIndexerType (WrangleWithPredictions i _ _) = i

indexerAndEncoder :: DataWrangler a b p -> a -> (Either T.Text b, a -> Either T.Text A.Series)
indexerAndEncoder (Wrangle _ x) = x
indexerAndEncoder (WrangleWithPredictions _ x _) = x

-- produce a result of type b from the data and the model summary
-- NB: the cache time will give you newest of data, indices and stan output
--type ResultAction r a b c = CS.StanSummary -> K.ActionWithCacheTime r (a, b) -> K.Sem r c

data ResultAction r a b p c where
  UseSummary :: (CS.StanSummary -> p -> K.ActionWithCacheTime r (a, Either T.Text b) -> K.Sem r c) -> ResultAction r a b p c
  SkipSummary :: (p -> K.ActionWithCacheTime r (a, Either T.Text b) -> K.Sem r c) -> ResultAction r a b p c
  DoNothing :: ResultAction r a b c ()

emptyResult :: ResultAction r a b p ()
emptyResult = SkipSummary $ \_ _ -> return ()

addDirT :: T.Text -> T.Text -> T.Text
addDirT dir fp = dir <> "/" <> fp

addDirFP :: FilePath -> FilePath -> FilePath
addDirFP dir fp = dir ++ "/" ++ fp

defaultDataFileName :: T.Text -> T.Text
defaultDataFileName modelNameT = modelNameT <> ".json"

sampleFile :: T.Text -> Maybe Int -> FilePath
sampleFile outputFilePrefix chainIndexM = toString outputFilePrefix <> (maybe "" (("_" <>) . show) chainIndexM) <> ".csv"

--stanOutputFiles :: ModelRunnerConfig -> [T.Text]
--stanOutputFiles config = fmap (toText . outputFile (outputPrefix config)) $ Just <$> [1..(mrcNumChains config)]

summaryFileName :: ModelRunnerConfig -> T.Text
summaryFileName config = modelGQName (mrcInputNames config) <> ".json"

summaryFilePath :: ModelRunnerConfig -> T.Text
summaryFilePath config = rinModelDir (mrcInputNames config) <> "/output/" <> summaryFileName config
