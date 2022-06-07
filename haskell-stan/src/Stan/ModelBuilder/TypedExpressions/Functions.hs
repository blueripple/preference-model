{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Stan.ModelBuilder.TypedExpressions.Functions
  (
    module Stan.ModelBuilder.TypedExpressions.Functions
  )
  where

import Stan.ModelBuilder.TypedExpressions.Types
import Stan.ModelBuilder.TypedExpressions.Recursion

import Prelude hiding (Nat)
import           Data.Kind (Type)

import qualified GHC.TypeLits as TE
import GHC.TypeLits (ErrorMessage((:<>:)))
import Data.Hashable.Generic (HashArgs)


logit :: Function EReal '[EReal]
logit = Function "logit" SReal (oneArgType SReal)

invLogit :: Function EReal '[EReal]
invLogit = Function "inv_logit" SReal (oneArgType SReal)


-- singleton for a list of arguments
data ArgTypeList :: [EType] -> Type where
  ArgTypeNil :: ArgTypeList '[]
  (::>) :: SType et -> ArgTypeList ets -> ArgTypeList (et ': ets)

infixr 2 ::>

argTypesToList ::  (forall t.SType t -> a) -> ArgTypeList args -> [a]
argTypesToList _ ArgTypeNil = []
argTypesToList f (st ::> ats) = f st : argTypesToList f ats

argTypesToArgListOfTypes :: ArgTypeList args -> ArgList SType args
argTypesToArgListOfTypes ArgTypeNil = ArgNil
argTypesToArgListOfTypes (st ::> atl) = st :> argTypesToArgListOfTypes atl

oneArgType :: SType et -> ArgTypeList '[et]
oneArgType st = st ::> ArgTypeNil

-- list of arguments.  Parameterized by an expression type and the list of arguments
data ArgList ::  (EType -> Type) -> [EType] -> Type where
  ArgNil :: ArgList f '[]
  (:>) :: f et -> ArgList f ets -> ArgList f (et ': ets)

infixr 2 :>

instance HFunctor ArgList where
  hfmap nat = \case
    ArgNil -> ArgNil
    (:>) get al -> nat get :> hfmap nat al

instance HTraversable ArgList where
  htraverse natM = \case
    ArgNil -> pure ArgNil
    (:>) aet al -> (:>) <$> natM aet <*> htraverse natM al
  hmapM = htraverse

zipArgListsWith :: (forall t. a t -> b t -> c t) -> ArgList a args -> ArgList b args -> ArgList c args
zipArgListsWith _ ArgNil ArgNil = ArgNil
zipArgListsWith f (a :> as) (b :> bs) = f a b :> zipArgListsWith f as bs

argsKToList :: ArgList (K a) ts -> [a]
argsKToList ArgNil = []
argsKToList (a :> al) = unK a : argsKToList al

oneArg :: f et -> ArgList f '[et]
oneArg e = e :> ArgNil

argTypesToSTypeList :: ArgTypeList args -> ArgList SType args
argTypesToSTypeList ArgTypeNil = ArgNil
argTypesToSTypeList (st ::> atl) = st :> argTypesToSTypeList atl

data Function :: EType -> [EType] -> Type  where
  Function :: Text -> SType r -> ArgTypeList args -> Function r args

functionArgTypes :: Function rt args -> ArgTypeList args
functionArgTypes (Function _ _ al) = al

data Density :: EType -> [EType] -> Type where
  Density :: Text -> SType g -> ArgTypeList args -> Density g args

-- const functor for holding arguments to functions
data FuncArg :: Type -> k -> Type where
  Arg :: a -> FuncArg a r
  DataArg :: a -> FuncArg a r

funcArgName :: FuncArg Text a -> Text
funcArgName = \case
  Arg txt -> txt
  DataArg txt -> txt

mapFuncArg :: (a -> b) -> FuncArg a r -> FuncArg b r
mapFuncArg f = \case
  Arg a -> Arg $ f a
  DataArg a -> DataArg $ f a