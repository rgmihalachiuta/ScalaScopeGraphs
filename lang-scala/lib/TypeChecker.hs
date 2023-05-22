{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
module TypeChecker where

import Data.Functor
import Data.Regex

import Free
import Free.Scope hiding (edge, new, sink)
import qualified Free.Scope as S (edge, new, sink)
import Free.Error
import ScSyntax
import Debug.Trace


----------------------------
-- Scope Graph Parameters --
----------------------------

data Label
  = P -- Lexical Parent Label
  | I -- Import Label
  | VAR -- Variable Label
  | OBJ -- Object label
  deriving (Show, Eq)

data Decl
  = Decl String Type   -- Variable declaration
  | Import String Sc -- Importdeclaration
  | ObjD String Sc -- Object declaration
  deriving (Eq)


instance Show Decl where
  show (Decl x t) = x ++ " : " ++ show t
  show (Import x s) = "Import" ++ x ++ " @ " ++ show s
  show (ObjD x s) = "Object" ++ x ++ "@" ++ show s

projTy :: Decl -> Type
projTy (Decl _ t) = t
projTy (ObjD _ _) = error "Cannot project an object"
projTy (Import _ _) = error "Cannot project a module"

-- Scope Graph Library Convenience
edge :: Scope Sc Label Decl < f => Sc -> Label -> Sc -> Free f ()
edge = S.edge @_ @Label @Decl

new :: Scope Sc Label Decl < f => Free f Sc
new = S.new @_ @Label @Decl

sink :: Scope Sc Label Decl < f => Sc -> Label -> Decl -> Free f ()
sink = S.sink @_ @Label @Decl

-- Regular expression P*D
re :: RE Label
re = Dot (Star $ Atom P) $ Atom VAR

-- Path order based on length
pShortest :: PathOrder Label Decl
pShortest p1 p2 = lenRPath p1 < lenRPath p2

-- Path order based on Ministatix priorities.
pStatix :: PathOrder Label Decl
pStatix p1 p2 = label == LT || label == EQ
  where
    label = pStatixHelper p1 p2

pStatixHelper :: ResolvedPath Label Decl -> ResolvedPath Label Decl -> Ordering
pStatixHelper (ResolvedPath p1 _ _) (ResolvedPath p2 _ _) = comparePaths (extractPath p1) (extractPath p2)
  where
    comparePaths [] [] = EQ
    comparePaths (_:_) [] = GT
    comparePaths [] (_:_) = LT
    comparePaths (x:xs) (y:ys) = case compareLabel x y of
      Just r -> r
      Nothing -> comparePaths xs ys
    -- compareLabel MOD P = Just LT
    -- compareLabel P MOD = Just GT
    -- compareLabel MOD I = Just LT
    -- compareLabel I MOD = Just GT
    compareLabel VAR P = Just LT
    compareLabel P VAR = Just GT
    compareLabel VAR I = Just LT
    compareLabel I VAR = Just GT
    compareLabel I P = Just LT
    compareLabel P I = Just GT
    compareLabel _ _ = Nothing
    extractPath (Start _) = []
    extractPath (Step p l _) = extractPath p ++ [l]

-- Match declaration with particular name
matchDecl :: String -> Decl -> Bool
matchDecl x (Decl x' _) = x == x'
matchDecl x (Import x' _) = x == x'
matchDecl x (ObjD x' _) = x == x'

------------------
-- Type Checker --
------------------

-- Function to type check scala expressions
tcScExp :: (Functor f, Error String < f, Scope Sc Label Decl < f) => ScExp -> Sc -> Free f Type
tcScExp (ScNum _) _ = return NumT
tcScExp (ScBool _) _ = return BoolT
tcScExp (ScId x) s = do
  ds <- query s re pShortest (matchDecl x) <&> map projTy 
  case ds of
    []  -> err "No matching declarations found"
    [t] -> return t
    _   -> err "BUG: Multiple declarations found" -- cannot happen for STLC
tcScExp (ScPlus l r) s = tcBinOp l r NumT NumT s
tcScExp (ScIf cond thenBranch elseBranch) s = do
  ifBool <- tcScExp cond s
  trueBranch <- tcScExp thenBranch s
  falseBranch <- tcScExp elseBranch s
  if ifBool == BoolT then
    if trueBranch == falseBranch then return trueBranch else err "Branches need the same output type."
  else err "There needs to be a boolean condition."
tcScExp (ScFun (ScParam str strType) body) s = do
  let newTy = strType
  s' <- new
  edge s' P s
  sink s' VAR $ Decl str newTy
  t' <- tcScExp body s'
  return $ FunT newTy t'
tcScExp (ScApp func app) s = do
  f' <- tcScExp func s
  a' <- tcScExp app s
  case f' of
    (FunT t t') | t == a' -> return t'
    (FunT t _) -> err $ "Expected argument of type '" ++ show t ++ "' got '" ++ show a' ++ "'"
    _ -> err "Not function."


tcBinOp :: (Functor f, Error String < f, Scope Sc Label Decl < f) => ScExp -> ScExp -> Type -> Type -> Sc -> Free f Type
tcBinOp l r inp out s = do
  tcL <- tcScExp l s
  tcR <- tcScExp r s
  if tcL == inp && tcR == inp then
    return out
  else
    err "Error when type checking a binary operator."


tcScDecl :: (Functor f, Error String < f, Scope Sc Label Decl < f) => ScDecl -> Sc -> Free f Type
tcScDecl (ScVal (ScParam name t) expr) s = do
    let newTy = t
    sink s VAR $ Decl name newTy
    tcScExp expr s
    return (ValT name)
tcScDecl (ScDef name t expr) s = do
    let newTy = t
    s' <- new
    edge s' P s
    sink s' VAR $ Decl name newTy
    tcScExp expr s'
    return (ValT name)
tcScDecl (ScObject name defs) s = do
    -- add object declarations scope
  sObjDef <- new
  -- add obj declaration to the outer scope
  sink s OBJ $ ObjD name sObjDef
  -- add edge between object scope and outer scope (which is the parent)
  edge sObjDef P s
  -- type check declarations 
  -- construct all the associated scopes of the obeject
  mapM_ (`tcScDecl` sObjDef) defs
  return (ObjT name)


-- tc (ClassE name fields methods static const) sc = do -- TODO make sure fields and methods are actually fields and methods 
--   sink sc D $ ClassDecl name fields methods static const
--   classScope <- new
--   edge classScope P sc
--   addSinksForFields fields classScope
--   addSinksForMethods methods classScope
--   return $ JavaClass name static const


-- tcScExp (ScObj s) _ = return $ ObjT s
    -- case op of 
    -- ScAdd -> tcBinOp l r intT intT s
    -- ScMinus -> tcBinOp l r intT intT s
    -- ScMult -> tcBinOp l r intT intT s
    -- ScDiv -> tcBinOp l r intT intT s
    -- ScEquals -> tcBinOp l r intT boolT s
    -- ScLessThan -> tcBinOp l r intT boolT s


-- Create all declarations.
  -- = AAnon Sc [LModule] [AnnotatedModTree] [LDecl]
  -- | ANamed Sc String [LModule] [AnnotatedModTree] [LDecl]
-- constrDecls :: (Functor f, Error String < f, Scope Sc Label Decl < f) => [ScDecl] -> Sc -> Free f [(Sc, Type, ScExp)]
-- constrDecls decls s  = constrDecls' g children decls

-- Specifically, create declarations of current module and recurse to child modules.
-- constrDecls' :: (Functor f,  Error String < f, Scope Sc Label Decl < f) => Sc -> [ScDecl] -> Free f [(Sc, Type, ScExp)]
-- constrDecls' g children decls = do
--   curr <- catMaybes <$> mapM (make g) decls
--   rest <- concat <$> mapM constrDecls children
--   return $ curr ++ rest
--   where
--     make g (ScVal s e) = do
--       t <- exists
--       sink g V $ Var s t
--       return $ Just (g, t, e)
--     make _ _ = return Nothing

-- Tie it all together
runTC :: ScExp -> Either String (Type, Graph Label Decl)
runTC e = un
        $ handle hErr
        $ handle_ hScope (tcScExp e 0) emptyGraph

runTCDecl :: ScDecl -> Either String (Type, Graph Label Decl)
runTCDecl decl = un 
        $ handle hErr 
        $ handle_ hScope (tcScDecl decl 0) emptyGraph

