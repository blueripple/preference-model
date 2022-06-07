{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}

module Stan.ModelBuilder.TypedExpressions.Format
  (
    module Stan.ModelBuilder.TypedExpressions.Format
  )
  where

import Stan.ModelBuilder.TypedExpressions.Recursion
import Stan.ModelBuilder.TypedExpressions.Types
import Stan.ModelBuilder.TypedExpressions.Indexing
import Stan.ModelBuilder.TypedExpressions.Operations
import Stan.ModelBuilder.TypedExpressions.Functions
import Stan.ModelBuilder.TypedExpressions.Expressions
import Stan.ModelBuilder.TypedExpressions.Statements

import qualified Data.Functor.Foldable as RS
import qualified Data.Foldable as Foldable

import qualified Data.IntMap.Strict as IM
import qualified Data.List as List
import qualified Data.List.NonEmpty as NE
import Data.List ((!!))
import qualified Data.Vec.Lazy as DT
import qualified Data.Type.Nat as DT
import qualified Data.Fin as DT
import qualified Data.Text as T

import qualified Stan.ModelBuilder.Expressions as SME
import Prelude hiding (Nat)
import Relude.Extra
import qualified Data.Map.Strict as Map

import qualified Prettyprinter as PP
import Prettyprinter ((<+>))
--import qualified Data.List.NonEmpty.Extra as List


type CodePP = PP.Doc ()

-- we unfold to replace LExprs within statements with prettyprinted code
-- then fold up the statements to produce code
stmtToCodeE :: LStmt -> Either Text CodePP
stmtToCodeE = stmtToCodeE' . lStmtToCodeStmt

stmtToCodeE2 :: LStmt -> Either Text CodePP
stmtToCodeE2 = RS.hylo stmtToCodeAlg' statementExpressionsToCodeCoalg

-- unfold to put code in for all expressions
lStmtToCodeStmt :: LStmt -> Stmt (K CodePP)
lStmtToCodeStmt = RS.ana statementExpressionsToCodeCoalg

statementExpressionsToCodeCoalg :: LStmt -> StmtF (K CodePP) LStmt
statementExpressionsToCodeCoalg = \case
  SDeclare txt st divf vms -> SDeclareF txt st (hfmap f divf) (fmap (hfmap f) vms)
  SDeclAssign txt st divf vms rhse -> SDeclAssignF txt st (hfmap f divf) (fmap (hfmap f) vms) (f rhse)
  SAssign lhs rhs -> SAssignF (f lhs) (f rhs)
  STarget rhs -> STargetF (f rhs)
  SSample lhs d al -> SSampleF (f lhs) d (hfmap f al)
  SFor ctr le ue body -> SForF ctr (f le) (f ue) body
  SForEach ctr ctre body -> SForEachF ctr (f ctre) body
  SIfElse conds ifFalseS -> SIfElseF (first f <$> conds) ifFalseS
  SWhile c body -> SWhileF (f c) body
  SBreak -> SBreakF
  SContinue -> SContinueF
  SFunction func al body re -> SFunctionF func al body (f re)
  SComment cs -> SCommentF cs
  SPrint al -> SPrintF (hfmap f al)
  SReject al -> SRejectF (hfmap f al)
  SScoped body -> SScopedF body
  SBlock sb body -> SBlockF sb body
  SContext ml body -> SContextF ml body
  where
    f = exprToCode

-- fold to put the expressions and staements together
stmtToCodeE' :: Stmt (K CodePP) -> Either Text CodePP
stmtToCodeE' = RS.cata stmtToCodeAlg'

stmtToCodeAlg' :: StmtF (K CodePP) (Either Text CodePP) -> Either Text CodePP
stmtToCodeAlg' = \case
  SDeclareF txt st divf vms -> Right $ stanDeclHead st (unK <$> DT.toList (unDeclIndexVecF divf)) vms <+> PP.pretty txt <> PP.semi
  SDeclAssignF txt st divf vms rhs -> Right $ stanDeclHead st (unK <$> DT.toList (unDeclIndexVecF divf)) vms <+> PP.pretty txt <+> PP.equals <+> unK rhs <> PP.semi
  SAssignF lhs rhs -> Right $ unK lhs <+> PP.equals <+> unK rhs <> PP.semi
  STargetF rhs -> Right $ "target +=" <+> unK rhs
  SSampleF lhs (Density dn _ _) al -> Right $ unK lhs <+> "~" <+> PP.pretty dn <> PP.parens (csArgList al)
  SForF txt fe te body -> (\b -> "for" <+> PP.parens (PP.pretty txt <+> "in" <+> unK fe <> PP.colon <> unK te) <+> bracketBlock b) <$> sequenceA body
  SForEachF txt e body -> (\b -> "foreach" <+> PP.parens (PP.pretty txt <+> "in" <+> unK e) <+> bracketBlock b) <$> sequence body
  SIfElseF condAndIfTrueL allFalse -> ifElseCode condAndIfTrueL allFalse
  SWhileF if' body -> (\b -> "while" <+> PP.parens (unK if') <+> bracketBlock b) <$> sequence body
  SBreakF -> Right $ "break" <> PP.semi
  SContinueF -> Right $ "continue" <> PP.semi
  SFunctionF (Function fname rt ats) al body re ->
    (\b -> PP.pretty (sTypeName rt) <+> "function" <+> PP.pretty fname <> functionArgs ats al <+> bracketBlock (b `appendList` ["return" <+> unK re <> PP.semi])) <$> sequence body
  SCommentF (c :| []) -> Right $ "//" <+> PP.pretty c
  SCommentF cs -> Right $ "{*" <> PP.line <> PP.indent 2 (PP.vsep $ NE.toList $ PP.pretty <$> cs) <> PP.line <> "*}"
  SPrintF al -> Right $ "print" <+> PP.parens (csArgList al) <> PP.semi
  SRejectF al -> Right $ "reject" <+> PP.parens (csArgList al) <> PP.semi
  SScopedF body -> bracketBlock <$> sequence body
  SBlockF bl body -> maybe (Right mempty) (fmap (\x -> PP.pretty (stmtBlockHeader bl) <> bracketBlock x) . sequenceA) $ nonEmpty body
  SContextF mf body -> case mf of
    Just _ -> Left "stmtToCodeAlg: Impossible! SContext with a change function remaining!"
    Nothing -> blockCode <$> sequence body

indexCodeL :: [CodePP] -> CodePP
indexCodeL [] = ""
indexCodeL x = PP.brackets $ PP.hsep $ PP.punctuate "," x

stanDeclHead :: StanType t -> [CodePP] -> [VarModifier (K CodePP) (InternalType t)] -> CodePP
stanDeclHead st il vms = case st of
  StanArray sn st -> let (adl, sdl) = List.splitAt (fromIntegral $ DT.snatToNatural sn) il
                     in "array" <> indexCodeL adl <+> stanDeclHead st sdl vms
  _ -> PP.pretty (stanTypeName st)  <> indexCodeL il <> varModifiersToCode vms
  where
    vmToCode = \case
      VarLower x -> "lower" <> PP.equals <> unK x
      VarUpper x -> "upper" <> PP.equals <> unK x
      VarOffset x -> "offset" <> PP.equals <> unK x
      VarMultiplier x -> "multiplier" <> PP.equals <> unK x
    varModifiersToCode vms =
      if null vms
      then mempty
      else PP.langle <> (PP.hsep $ PP.punctuate ", " $ fmap vmToCode vms) <> PP.rangle

-- add brackets and indent the lines of code
bracketBlock :: NonEmpty CodePP -> CodePP
bracketBlock = bracketCode . blockCode

-- surround with brackets and indent
bracketCode :: CodePP -> CodePP
bracketCode c = "{" <> PP.line <> PP.indent 2 c <> PP.line <> "} "

-- put each item of code on a separate line
blockCode :: NonEmpty CodePP -> CodePP
blockCode ne = PP.vsep $ NE.toList ne

-- put each line *after the first* on a new line
blockCode' :: NonEmpty CodePP -> CodePP
blockCode' (c :| cs) = c <> PP.vsep cs

appendList :: NonEmpty a -> [a] -> NonEmpty a
appendList (a :| as) as' = a :| (as ++ as')

functionArgs:: ArgTypeList args -> ArgList (FuncArg Text) args -> CodePP
functionArgs argTypes argNames = PP.parens $ mconcat $ PP.punctuate (PP.comma <> PP.space) argCodeList
  where
    handleFA :: CodePP -> FuncArg Text t -> CodePP
    handleFA c = \case
      Arg a -> c <+> PP.pretty a
      DataArg a -> "data" <+> c <+> PP.pretty a

    arrayIndices :: SNat n -> CodePP
    arrayIndices sn = if n == 0 then mempty else PP.brackets (mconcat $ List.replicate (n-1) PP.comma)
      where n = fromIntegral $ DT.snatToNatural sn

    handleType :: SType t -> CodePP
    handleType st = case st of
      SArray sn st -> "array" <> arrayIndices sn <+> handleType st
      _ -> PP.pretty $ sTypeName st

    f :: SType t -> FuncArg Text t -> K CodePP t
    f st fa = K $ handleFA (handleType st) fa

    argCodeList = argsKToList $ zipArgListsWith f (argTypesToSTypeList argTypes) argNames

ifElseCode :: NonEmpty (K CodePP EBool, Either Text CodePP) -> Either Text CodePP -> Either Text CodePP
ifElseCode ecNE c = do
  let (conds, ifTrueCodeEs) = NE.unzip ecNE
      condCode (e :| es) = "if" <+> PP.parens (unK e) <> PP.space :| fmap (\le -> "else if" <+> PP.parens (unK le) <> PP.space) es
      condCodeNE = condCode conds `appendList` ["else"]
  ifTrueCodes <- sequenceA (ifTrueCodeEs `appendList` [c])
  let ecNE = NE.zipWith (<+>) condCodeNE (fmap (bracketBlock . one) ifTrueCodes)
  return $ blockCode' ecNE

data  IExprCode :: Type where
  Unsliced :: CodePP -> IExprCode
  Oped :: SBinaryOp op -> CodePP -> IExprCode -- has an binary operator in it so might need parentheses
  Sliced :: CodePP -> IM.IntMap IExprCode -> IExprCode -- needs indexing

data IExprCodeF :: Type -> Type where
  UnslicedF :: CodePP -> IExprCodeF a
  OpedF :: SBinaryOp op -> CodePP -> IExprCodeF a
  SlicedF :: CodePP -> IM.IntMap a -> IExprCodeF a

instance Functor IExprCodeF where
  fmap f = \case
    UnslicedF doc -> UnslicedF doc
    OpedF b c -> OpedF b c
    SlicedF c im -> SlicedF c (f <$> im)

instance Foldable IExprCodeF where
  foldMap f = \case
    UnslicedF doc -> mempty
    OpedF _ _ -> mempty
    SlicedF c im -> foldMap f im

instance Traversable IExprCodeF where
  traverse g = \case
    UnslicedF doc -> pure $ UnslicedF doc
    OpedF b c -> pure $ OpedF b c
    SlicedF c im -> SlicedF c <$> traverse g im

type instance RS.Base IExprCode = IExprCodeF

instance RS.Recursive IExprCode where
  project = \case
    Unsliced doc -> UnslicedF doc
    Oped b c -> OpedF b c
    Sliced iec im -> SlicedF iec im

instance RS.Corecursive IExprCode where
  embed = \case
    UnslicedF doc -> Unsliced doc
    OpedF b c -> Oped b c
    SlicedF doc im -> Sliced doc im

iExprToDocAlg :: IExprCodeF CodePP -> CodePP
iExprToDocAlg = \case
  UnslicedF doc -> doc
  OpedF b c -> c
  SlicedF doc im -> doc <> PP.brackets (mconcat $ PP.punctuate ", " $ withLeadingEmpty im) -- or hsep?

withLeadingEmpty :: IntMap CodePP -> [CodePP]
withLeadingEmpty im = imWLE where
  minIndex = Foldable.minimum $ IM.keys im
  imWLE = List.replicate minIndex mempty ++ IM.elems im

iExprToCode :: IExprCode -> CodePP
iExprToCode = RS.cata iExprToDocAlg

csArgList :: ArgList (K CodePP) args -> CodePP
csArgList = mconcat . PP.punctuate (PP.comma <> PP.space) . argsKToList

-- I am not sure about/do not understand the quantified constraint here.
exprToDocAlg :: IAlg LExprF (K IExprCode) -- LExprF ~> K IExprCode
exprToDocAlg = K . \case
  LNamed txt st -> Unsliced $ PP.pretty txt
  LInt n -> Unsliced $ PP.pretty n
  LReal x -> Unsliced $ PP.pretty x
  LComplex x y -> Unsliced $ PP.parens $ PP.pretty x <+> "+" <+> "i" <> PP.pretty y -- (x + iy))
  LString t -> Unsliced $ PP.dquotes $ PP.pretty t
  LVector xs -> Unsliced $ PP.brackets $ PP.pretty $ T.intercalate ", " (show <$> xs)
  LMatrix ms -> Unsliced $ unNestedToCode PP.brackets [length ms] $ PP.pretty <$> concatMap DT.toList ms--PP.brackets $ PP.pretty $ T.intercalate "," $ fmap (T.intercalate "," . fmap show . DT.toList) ms
  LArray nv -> Unsliced $ nestedVecToCode nv
  LFunction (Function fn _ _) al -> Unsliced $ PP.pretty fn <> PP.parens (csArgList $ hfmap f al)
  LDensity (Density dn _ _) k al -> Unsliced $ PP.pretty dn <> PP.parens (unK (f k) <> PP.pipe <+> csArgList (hfmap f al))
  LBinaryOp sbo le re -> Oped sbo $ unK (f $ parenthesizeOped le) <+> opDoc sbo <+> unK (f $ parenthesizeOped re)
  LUnaryOp op e -> Unsliced $ unaryOpDoc (unK (f $ parenthesizeOped e)) op
  LCond ce te fe -> Unsliced $ unK (f ce) <+> "?" <+> unK (f te) <+> PP.colon <+> unK (f fe)
  LSlice sn ie e -> sliced sn ie e
  where
    f :: K IExprCode ~> K CodePP
    f = K . iExprToCode . unK
    parenthesizeOped :: K IExprCode ~> K IExprCode
    parenthesizeOped x = case unK x of
       Oped bo doc -> K $ Oped bo $ PP.parens doc
       x -> K x
    slice :: SNat n -> K IExprCode EInt -> K IExprCode d -> IM.IntMap IExprCode -> IM.IntMap IExprCode
    slice sn kei ke im = im'
      where
        newIndex :: Int = fromIntegral $ DT.snatToNatural sn
        skip = IM.size $ IM.filterWithKey (\k _ -> k <= newIndex) im
        im' = IM.insert (newIndex + skip) (unK kei) im
    sliced :: SNat n -> K IExprCode EInt -> K IExprCode t -> IExprCode
    sliced sn kei ke = case unK ke of
      Unsliced c -> Sliced c $ slice sn kei ke $ IM.empty
      Oped _ c -> Sliced (PP.parens c) $ slice sn kei ke $ IM.empty
      Sliced c im -> Sliced c $ slice sn kei ke im

exprToIExprCode :: LExpr ~> K IExprCode
exprToIExprCode = iCata exprToDocAlg

exprToCode :: LExpr ~> K CodePP
exprToCode = K . iExprToCode . unK . exprToIExprCode

unaryOpDoc :: CodePP -> SUnaryOp op -> CodePP
unaryOpDoc ed = \case
  SNegate -> "-" <> ed
  STranspose -> ed <> "'"

boolOpDoc :: SBoolOp op -> CodePP
boolOpDoc = \case
  SEq -> PP.equals <> PP.equals
  SNEq -> "!="
  SLT -> PP.langle
  SLEq -> "<="
  SGT -> PP.rangle
  SGEq -> ">="
  SAnd -> "&&"
  SOr -> "||"

opDoc :: SBinaryOp op -> CodePP
opDoc = \case
  SAdd ->  "+"
  SSubtract -> "-"
  SMultiply -> "*"
  SDivide -> PP.slash
  SPow -> "^"
  SModulo -> "%"
  SElementWise sbo -> PP.dot <> opDoc sbo
  SAndEqual sbo -> opDoc sbo <> PP.equals
  SBoolean bop -> boolOpDoc bop

nestedVecToCode :: NestedVec n (K IExprCode t) -> CodePP
nestedVecToCode nv = unNestedToCode PP.braces (drop 1 $ reverse dims) itemsCode
  where
    f = iExprToCode . unK
    (dims, items) = unNest nv
    itemsCode = f <$> items

-- given a way to surround a group,
-- a set of dimensions to group in order of grouping (so reverse order of left to right indexes)
-- items of code in one long list
-- produce a code item with them grouped
-- e.g., renderAsText $ unNestedCode PP.parens [2, 3] ["a","b","c","d","e","f"] = "((a, b), (c, d), (e, f))"
unNestedToCode :: (CodePP -> CodePP) -> [Int] -> [CodePP] -> CodePP
unNestedToCode surroundF dims items = surround $ go dims items
  where
    rdims = reverse dims
    surround = surroundF . PP.hsep . PP.punctuate ", "
    group :: Int -> [CodePP] -> [CodePP] -> [CodePP]
    group _ [] bs = bs
    group n as bs = let (g , as') = List.splitAt n as in group n as' (bs ++ [surround g]) -- this is quadratic. Fix.
    go :: [Int] -> [CodePP] -> [CodePP]
    go [] as = as
    go (x : xs) as = go xs (group x as [])

stmtBlockHeader :: StmtBlock -> Text
stmtBlockHeader = \case
  FunctionsStmts -> "functions"
  DataStmts -> "data"
  TDataStmts -> "transformed data"
  ParametersStmts -> "parameters"
  TParametersStmts -> "transformed parameters"
  ModelStmts -> "model"
  GeneratedQuantitiesStmts -> "generated quantities"