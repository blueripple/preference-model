{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -O0 -freduction-depth=0 #-}
module BlueRipple.Data.ACS_PUMS_Loader.Pums2008 where


import           BlueRipple.Data.ACS_PUMS (PUMS, pumsLoader)
import qualified BlueRipple.Data.ACS_PUMS_Loader.ACS_PUMS_Frame as BR
import qualified Knit.Report as K
import qualified Frames as F

pumsLoader2008 :: K.KnitEffects r => K.Sem r (F.FrameRec PUMS)
pumsLoader2008 = pumsLoader @(F.RecordColumns BR.PUMS_2008) 2008
