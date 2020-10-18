{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module Stan.ModelBuilder where

{-
import qualified Knit.Report as K
import qualified Knit.Effect.Logger            as K
import qualified BlueRipple.Utilities.KnitUtils as BR


import qualified Data.Aeson.Encoding as A
import qualified Data.ByteString.Lazy as BL
import qualified Polysemy as P
-}
import           Control.Monad (when)
import Data.Maybe (fromMaybe)
import qualified Data.Time.Clock as Time
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified System.Environment as Env
import qualified System.Directory as Dir

type DataBlock = T.Text
type TransformedDataBlock = T.Text
type ParametersBlock = T.Text
type TransformedParametersBlock = T.Text
type ModelBlock = T.Text
type GeneratedQuantitiesBlock = T.Text

data GeneratedQuantities = NoLL | OnlyLL | All 

data StanModel = StanModel { dataBlock :: DataBlock
                           , transformedDataBlockM :: Maybe TransformedDataBlock
                           , parametersBlock :: ParametersBlock
                           , transformedParametersBlockM :: Maybe TransformedParametersBlock
                           , modelBlock :: ModelBlock
                           , generatedQuantitiesBlockM :: Maybe GeneratedQuantitiesBlock
                           , genLogLikelihoodBlock :: GeneratedQuantitiesBlock
                           } deriving (Show, Eq, Ord)

stanModelAsText :: GeneratedQuantities -> StanModel -> T.Text
stanModelAsText gq sm =
  let section h b = h <> " {\n" <> b <> "\n}\n"
      maybeSection h = maybe "" (section h)
  in section "data" (dataBlock sm)
     <> maybeSection "transformed data" (transformedDataBlockM sm)
     <> section "parameters" (parametersBlock sm)
     <> maybeSection "transformed parameters" (transformedParametersBlockM sm)
     <> section "model" (modelBlock sm)
     <> case gq of
          NoLL -> maybeSection "generated quantities" (generatedQuantitiesBlockM sm)
          OnlyLL -> section "generated quantities" (genLogLikelihoodBlock sm)
          All -> section "generated quantities"
                 $ genLogLikelihoodBlock sm
                 <> "\n"
                 <> fromMaybe "" (generatedQuantitiesBlockM sm)

modelFile :: T.Text -> T.Text
modelFile modelNameT =  modelNameT <> ".stan"

-- The file is either not there, there but the same, or there but different so we
-- need an available file name to proceed
data ModelState = New | Same | Updated T.Text deriving (Show)

renameAndWriteIfNotSame :: GeneratedQuantities -> StanModel -> T.Text -> T.Text -> IO ModelState
renameAndWriteIfNotSame gq m modelDir modelName = do
  let fileName d n = T.unpack $ d <> "/" <> n <> ".stan"
      curFile = fileName modelDir modelName
      findAvailableName modelDir modelName n = do
        let newName = fileName modelDir (modelName <> "_o" <> (T.pack $ show n)) 
        newExists <- Dir.doesFileExist newName
        if newExists then findAvailableName modelDir modelName (n+1) else return $ T.pack newName
      newModel =  stanModelAsText gq m 
  exists <- Dir.doesFileExist curFile
  case exists of
    False -> do
      T.writeFile (fileName modelDir modelName) newModel
      return New
    True -> do
      extant <- T.readFile curFile
      case extant == newModel of
        True -> return Same
        False -> do
          newName <- findAvailableName modelDir modelName 1
          Dir.renameFile (fileName modelDir modelName) (T.unpack newName)
          T.writeFile (fileName modelDir modelName) newModel
          return $ Updated newName
        

