-- |
-- This module implements the desugaring pass which creates type synonyms for type class dictionaries
-- and dictionary expressions for type class instances.
--
module Language.PureScript.Sugar.TypeClasses
  ( desugarTypeClasses
  , typeClassMemberName
  , superClassDictionaryNames
  ) where

import Prelude.Compat

import           Control.Arrow (first, second)
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.State
import           Control.Monad.Supply.Class
import           Data.Either (partitionEithers)
import           Data.List ((\\), find, sortBy)
import qualified Data.Map as M
import           Data.Maybe (catMaybes, mapMaybe, isJust)
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Language.PureScript.Constants as C
import           Language.PureScript.Crash
import           Language.PureScript.Environment
import           Language.PureScript.Errors hiding (isExported)
import           Language.PureScript.Externs
import           Language.PureScript.Kinds
import           Language.PureScript.Label (Label(..))
import           Language.PureScript.Names
import           Language.PureScript.PSString (mkString)
import           Language.PureScript.Sugar.CaseDeclarations
import           Language.PureScript.Types
import           Language.PureScript.TypeClassDictionaries (superclassName)

type MemberMap = M.Map (ModuleName, ProperName 'ClassName) TypeClassData

type Desugar = StateT MemberMap

-- |
-- Add type synonym declarations for type class dictionary types, and value declarations for type class
-- instance dictionary expressions.
--
desugarTypeClasses
  :: (MonadSupply m, MonadError MultipleErrors m)
  => [ExternsFile]
  -> [Module]
  -> m [Module]
desugarTypeClasses externs = flip evalStateT initialState . traverse desugarModule
  where
  initialState :: MemberMap
  initialState =
    M.mapKeys (qualify (ModuleName [ProperName C.prim])) primClasses
    `M.union` M.fromList (externs >>= \ExternsFile{..} -> mapMaybe (fromExternsDecl efModuleName) efDeclarations)

  fromExternsDecl
    :: ModuleName
    -> ExternsDeclaration
    -> Maybe ((ModuleName, ProperName 'ClassName), TypeClassData)
  fromExternsDecl mn (EDClass name args members implies deps) = Just ((mn, name), typeClass) where
    typeClass = makeTypeClassData args members implies deps
  fromExternsDecl _ _ = Nothing

desugarModule
  :: (MonadSupply m, MonadError MultipleErrors m)
  => Module
  -> Desugar m Module
desugarModule (Module ss coms name decls (Just exps)) = do
  (newExpss, declss) <- unzip <$> parU (sortBy classesFirst decls) (desugarDecl name exps)
  return $ Module ss coms name (concat declss) $ Just (exps ++ catMaybes newExpss)
  where
  classesFirst :: Declaration -> Declaration -> Ordering
  classesFirst d1 d2
    | isTypeClassDeclaration d1 && not (isTypeClassDeclaration d2) = LT
    | not (isTypeClassDeclaration d1) && isTypeClassDeclaration d2 = GT
    | otherwise = EQ
desugarModule _ = internalError "Exports should have been elaborated in name desugaring"

{- Desugar type class and type class instance declarations
--
-- Type classes become type synonyms for their dictionaries, and type instances become dictionary declarations.
-- Additional values are generated to access individual members of a dictionary, with the appropriate type.
--
-- E.g. the following
--
--   module Test where
--
--   class Foo a where
--     foo :: a -> a
--
--   instance fooString :: Foo String where
--     foo s = s ++ s
--
--   instance fooArray :: (Foo a) => Foo [a] where
--     foo = map foo
--
--   {- Superclasses -}
--
--   class (Foo a) <= Sub a where
--     sub :: a
--
--   instance subString :: Sub String where
--     sub = ""
--
-- becomes:
--
--   <TypeClassDeclaration Foo ...>
--
--   type Foo a = { foo :: a -> a }
--
--   -- this following type is marked as not needing to be checked so a new Abs
--   -- is not introduced around the definition in type checking, but when
--   -- called the dictionary value is still passed in for the `dict` argument
--   foo :: forall a. (Foo a) => a -> a
--   foo dict = dict.foo
--
--   fooString :: {} -> Foo String
--   fooString _ = <TypeClassDictionaryConstructorApp Foo { foo: \s -> s ++ s }>
--
--   fooArray :: forall a. (Foo a) => Foo [a]
--   fooArray = <TypeClassDictionaryConstructorApp Foo { foo: map foo }>
--
--   {- Superclasses -}
--
--   <TypeClassDeclaration Sub ...>
--
--   type Sub a = { sub :: a
--                , "Foo0" :: {} -> Foo a
--                }
--
--   -- As with `foo` above, this type is unchecked at the declaration
--   sub :: forall a. (Sub a) => a
--   sub dict = dict.sub
--
--   subString :: {} -> Sub String
--   subString _ = { sub: "",
--                 , "Foo0": \_ -> <DeferredDictionary Foo String>
--                 }
--
-- and finally as the generated javascript:
--
--   function Foo(foo) {
--       this.foo = foo;
--   };
--
--   var foo = function (dict) {
--       return dict.foo;
--   };
--
--   var fooString = function (_) {
--       return new Foo(function (s) {
--           return s + s;
--       });
--   };
--
--   var fooArray = function (__dict_Foo_15) {
--       return new Foo(map(foo(__dict_Foo_15)));
--   };
--
--   function Sub(Foo0, sub) {
--       this["Foo0"] = Foo0;
--       this.sub = sub;
--   };
--
--   var sub = function (dict) {
--       return dict.sub;
--   };
--
--   var subString = function (_) {
--       return new Sub(fooString, "");
--   };
-}
desugarDecl
  :: (MonadSupply m, MonadError MultipleErrors m)
  => ModuleName
  -> [DeclarationRef]
  -> Declaration
  -> Desugar m (Maybe DeclarationRef, [Declaration])
desugarDecl mn exps = go
  where
  go d@(TypeClassDeclaration sa name args implies deps members) = do
    modify (M.insert (mn, name) (makeTypeClassData args (map memberToNameAndType members) implies deps))
    return (Nothing, d : typeClassDictionaryDeclaration sa name args implies members : map (typeClassMemberToDictionaryAccessor mn name args) members)
  go (TypeInstanceDeclaration _ _ _ _ _ DerivedInstance) = internalError "Derived instanced should have been desugared"
  go d@(TypeInstanceDeclaration sa name deps className tys (ExplicitInstance members)) = do
    desugared <- desugarCases members
    dictDecl <- typeInstanceDictionaryDeclaration sa name mn deps className tys desugared
    return (expRef name className tys, [d, dictDecl])
  go d@(TypeInstanceDeclaration sa name deps className tys (NewtypeInstanceWithDictionary dict)) = do
    let dictTy = foldl TypeApp (TypeConstructor (fmap coerceProperName className)) tys
        constrainedTy = quantify (foldr ConstrainedType dictTy deps)
    return (expRef name className tys, [d, ValueDeclaration sa name Private [] [MkUnguarded (TypedValue True dict constrainedTy)]])
  go other = return (Nothing, [other])

  expRef :: Ident -> Qualified (ProperName 'ClassName) -> [Type] -> Maybe DeclarationRef
  expRef name className tys
    | isExportedClass className && all isExportedType (getConstructors `concatMap` tys) = Just $ TypeInstanceRef genSpan name
    | otherwise = Nothing

  isExportedClass :: Qualified (ProperName 'ClassName) -> Bool
  isExportedClass = isExported (elem . TypeClassRef genSpan)

  isExportedType :: Qualified (ProperName 'TypeName) -> Bool
  isExportedType = isExported $ \pn -> isJust . find (matchesTypeRef pn)

  isExported
    :: (ProperName a -> [DeclarationRef] -> Bool)
    -> Qualified (ProperName a)
    -> Bool
  isExported test (Qualified (Just mn') pn) = mn /= mn' || test pn exps
  isExported _ _ = internalError "Names should have been qualified in name desugaring"

  matchesTypeRef :: ProperName 'TypeName -> DeclarationRef -> Bool
  matchesTypeRef pn (TypeRef _ pn' _) = pn == pn'
  matchesTypeRef _ _ = False

  getConstructors :: Type -> [Qualified (ProperName 'TypeName)]
  getConstructors = everythingOnTypes (++) getConstructor
    where
    getConstructor (TypeConstructor tcname) = [tcname]
    getConstructor _ = []

  genSpan :: SourceSpan
  genSpan = internalModuleSourceSpan "<generated>"

memberToNameAndType :: Declaration -> (Ident, Type)
memberToNameAndType (TypeDeclaration _ ident ty) = (ident, ty)
memberToNameAndType _ = internalError "Invalid declaration in type class definition"

typeClassDictionaryDeclaration
  :: SourceAnn
  -> ProperName 'ClassName
  -> [(Text, Maybe Kind)]
  -> [Constraint]
  -> [Declaration]
  -> Declaration
typeClassDictionaryDeclaration sa name args implies members =
  let superclassTypes = superClassDictionaryNames implies `zip`
        [ function unit (foldl TypeApp (TypeConstructor (fmap coerceProperName superclass)) tyArgs)
        | (Constraint superclass tyArgs _) <- implies
        ]
      members' = map (first runIdent . memberToNameAndType) members
      mtys = members' ++ superclassTypes
  in TypeSynonymDeclaration sa (coerceProperName name) args (TypeApp tyRecord $ rowFromList (map (first (Label . mkString)) mtys, REmpty))

typeClassMemberToDictionaryAccessor
  :: ModuleName
  -> ProperName 'ClassName
  -> [(Text, Maybe Kind)]
  -> Declaration
  -> Declaration
typeClassMemberToDictionaryAccessor mn name args (TypeDeclaration sa ident ty) =
  let className = Qualified (Just mn) name
  in ValueDeclaration sa ident Private [] $
    [MkUnguarded (
     TypedValue False (TypeClassDictionaryAccessor className ident) $
       moveQuantifiersToFront (quantify (ConstrainedType (Constraint className (map (TypeVar . fst) args) Nothing) ty))
    )]
typeClassMemberToDictionaryAccessor _ _ _ _ = internalError "Invalid declaration in type class definition"

unit :: Type
unit = TypeApp tyRecord REmpty

typeInstanceDictionaryDeclaration
  :: forall m
   . (MonadSupply m, MonadError MultipleErrors m)
  => SourceAnn
  -> Ident
  -> ModuleName
  -> [Constraint]
  -> Qualified (ProperName 'ClassName)
  -> [Type]
  -> [Declaration]
  -> Desugar m Declaration
typeInstanceDictionaryDeclaration sa name mn deps className tys decls =
  rethrow (addHint (ErrorInInstance className tys)) $ do
  m <- get

  -- Lookup the type arguments and member types for the type class
  TypeClassData{..} <-
    maybe (throwError . errorMessage . UnknownName $ fmap TyClassName className) return $
      M.lookup (qualify mn className) m

  case map fst typeClassMembers \\ mapMaybe declIdent decls of
    member : _ -> throwError . errorMessage $ MissingClassMember member
    [] -> do
      -- Replace the type arguments with the appropriate types in the member types
      let memberTypes = map (second (replaceAllTypeVars (zip (map fst typeClassArguments) tys))) typeClassMembers

      -- Create values for the type instance members
      members <- zip (map typeClassMemberName decls) <$> traverse (memberToValue memberTypes) decls

      -- Create the type of the dictionary
      -- The type is a record type, but depending on type instance dependencies, may be constrained.
      -- The dictionary itself is a record literal.
      let superclasses = superClassDictionaryNames typeClassSuperclasses `zip`
            [ Abs (VarBinder (Ident C.__unused)) (DeferredDictionary superclass tyArgs)
            | (Constraint superclass suTyArgs _) <- typeClassSuperclasses
            , let tyArgs = map (replaceAllTypeVars (zip (map fst typeClassArguments) tys)) suTyArgs
            ]

      let dependencies = map (addDependencies (S.fromList (map fst members))) members

      (remaining, start) <- case addLayer S.empty dependencies of
        (errors, []) -> throwError . errorMessage $ OverlappingNamesInLet -- FIXME
        layer -> pure layer

      let placeholders = map (second (const $ Var (Qualified Nothing (Ident "undefined"))) . snd) remaining

      let props = Literal $ ObjectLiteral $ map (first mkString) (start ++ superclasses ++ placeholders)
          dictTy = foldl TypeApp (TypeConstructor (fmap coerceProperName className)) tys
          constrainedTy = quantify (foldr ConstrainedType dictTy deps)
          rawDict = TypeClassDictionaryConstructorApp className props
      fullDict <- either (const (throwError . errorMessage $ OverlappingNamesInLet)) pure $ recurse remaining (S.fromList (map fst start)) rawDict
      let result = ValueDeclaration sa name Private [] [MkUnguarded (TypedValue True fullDict constrainedTy)]
      return result

  where

  declIdent :: Declaration -> Maybe Ident
  declIdent (ValueDeclaration _ ident _ _ _) = Just ident
  declIdent (TypeDeclaration _ ident _) = Just ident
  declIdent _ = Nothing

  memberToValue :: [(Ident, Type)] -> Declaration -> Desugar m Expr
  memberToValue tys' (ValueDeclaration _ ident _ [] [MkUnguarded val]) = do
    _ <- maybe (throwError . errorMessage $ ExtraneousClassMember ident className) return $ lookup ident tys'
    return val
  memberToValue _ _ = internalError "Invalid declaration in type instance definition"

  -- Given the method/member dependencies satisfied already,
  --   return the next layer that can be added and the remaining
  addLayer :: S.Set Text -> [(S.Set Text, (Text, Expr))] -> ([(S.Set Text, (Text, Expr))], [(Text, Expr)])
  addLayer provided remaining =
    let
      check (ids, d) = case ids S.\\ provided of
        m | S.null m -> Right d
        m -> Left (m, d)
    in partitionEithers $ map check remaining

  recurse :: [(S.Set Text, (Text, Expr))] -> S.Set Text -> Expr -> Either [(Text, S.Set Text)] Expr
  recurse [] _ e = Right e
  recurse remaining provided e = case addLayer provided remaining of
    (errors, []) -> Left $ map (\(ids, (n, _)) -> (n, ids)) errors
    (more, some) -> recurse more
      (S.union provided $ S.fromList $ map fst some)
      (ObjectUpdate e $ map (first mkString) some)

  usedImmediateIdents :: S.Set Text -> Expr -> S.Set Text
  usedImmediateIdents incl e =
    let (_, f, _, _, _) = everythingWithContextOnValues True S.empty S.union def usedNamesE def def def
    in f e
    where
    Qualified moduleName _ = className

    def s _ = (s, S.empty)

    usedNamesE :: Bool -> Expr -> (Bool, S.Set Text)
    usedNamesE True (Var (Qualified moduleName' name))
      | moduleName == moduleName'
      , i <- runIdent name
      , i `S.member` incl
      = (True, S.singleton i)
    usedNamesE True (Abs _ _) = (False, S.empty)
    usedNamesE scope _ = (scope, S.empty)

  addDependencies :: S.Set Text -> (Text, Expr) -> (S.Set Text, (Text, Expr))
  addDependencies incl v@(_, e) = (usedImmediateIdents incl e, v)

typeClassMemberName :: Declaration -> Text
typeClassMemberName (TypeDeclaration _ ident _) = runIdent ident
typeClassMemberName (ValueDeclaration _ ident _ _ _) = runIdent ident
typeClassMemberName _ = internalError "typeClassMemberName: Invalid declaration in type class definition"

superClassDictionaryNames :: [Constraint] -> [Text]
superClassDictionaryNames supers =
  [ superclassName pn index
  | (index, Constraint pn _ _) <- zip [0..] supers
  ]
