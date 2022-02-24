{-# LANGUAGE LambdaCase #-}

module ProcessEnvironment where
import PrettySyntax
import Syntax as S
import Control.Concurrent.Chan as C
import Control.Monad.Reader as T
import Control.Exception
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set

data InterpreterException
  = MathException String
  | LookupException String
  | CastException Exp
  | ApplicationException Exp
  | RecursorException String
  | RecursorNotNatException
  | NotImplementedException Exp
  | TypeNotImplementedException Type

instance Show InterpreterException where
  show = \case
    (MathException s) -> "MathException: " ++ s
    (LookupException s) -> "LookupException: Lookup of '" ++ s ++ "' did not yield a value"
    (CastException exp) -> "CastException: (" ++ pshow exp ++ ") failed"
    (ApplicationException exp) -> "ApplicationException: expression '" ++ pshow exp ++ "' not allowed"
    (RecursorException s) -> "RecursorException: " ++ s
    RecursorNotNatException -> "Recursor only works on natural numbers"
    (NotImplementedException exp) -> "NotImplementedException: " ++ pshow exp
    (TypeNotImplementedException typ) -> "TypeNotImplementedException: " ++ pshow typ

instance Exception InterpreterException

-- | the interpretation monad
type InterpretM a = T.ReaderT (PEnv, NREnv) IO a

createEntry :: Decl -> Maybe (String, Value)
createEntry = \case
  d@(DType str mult kind typ) -> Just (str, VType typ)
  d@(DFun str args e mt) -> Just (str, VDecl d)
  _ -> Nothing

createPEnv :: [Decl] -> PEnv
createPEnv = mapMaybe createEntry

extendEnv :: String -> Value -> (PEnv, NREnv) -> (PEnv, NREnv)
extendEnv s v (penv, aenv) = ((s, v) : penv, aenv)

-- | a Process Envronment maps identifiers to Values of expressions and stores
type PEnv = [PEnvEntry]
type PEnvEntry = (String, Value)

-- | environment for bindings of recursive natrec types
type NREnv = [(String, NREntry)]
data NREntry = NREntry PEnv Value String Type Type -- (ρ, natrec V (a.A) B)
  deriving (Show, Eq)

type Label = String
type LabelType = Set Label

labelsFromList :: [Label] -> LabelType
labelsFromList = Set.fromList

data FuncType = FuncType PEnv NREnv String S.Type S.Type
  deriving (Show, Eq)

-- | (Unit, Label, Int, Values of self-declared Data Types), Channels
data Value
  = VUnit
  | VLabel String
  | VInt Int
  | VDouble Double
  -- we have two channels, one for reading and one for writing to the other
  -- end, so we do not read our own written values
  | VChan (C.Chan Value) (C.Chan Value)
  | VSend Value
  | VPair Value Value -- pair of ids that map to two values
  | VDecl S.Decl -- when an identifier maps to another function we have not yet interpreted
  | VType S.Type
  | VFunc PEnv String Exp
  | VDynCast Value GType -- (Value : G => *)
  | VFuncCast Value FuncType FuncType -- (Value : (ρ,α,Π(x:A)A') => (ρ,α,Π(x:B)B'))
  | VRec PEnv String String Exp Exp
  deriving Eq

instance Show Value where
  show = \case
    VUnit -> "VUnit"
    VLabel s -> "VLabel " ++ s
    VInt i -> "VInt " ++ show i
    VDouble d -> "VDouble " ++ show d
    VChan _ _ -> "VChan"
    VSend v -> "VSend (" ++ show v ++ ")"
    VPair a b -> "VPair <" ++ show a ++ ", " ++ show b ++ ">"
    VDecl d -> "VDecl " ++ show d
    VType t -> "VType " ++ show t
    VFunc env s exp -> "VFunc " ++ show env ++ " " ++ show s ++ " " ++ show exp
    VDynCast v t -> "VDynCast (" ++ show v ++ ") (" ++ show t ++ ")"
    VFuncCast v ft1 ft2 -> "VFuncCast (" ++ show v ++ ") (" ++ show ft1 ++ ") (" ++ show ft2 ++ ")"
    VRec env f x e1 e0 -> "VRec " ++ show env ++ " " ++ show f ++ " " ++ show x ++ " " ++ show e1 ++ " " ++ show e0

class Subtypeable t where
  isSubtypeOf :: t -> t -> Bool

-- Types in Head Normal Form
data NFType
  = NFBot
  | NFDyn
  | NFUnit
  | NFNat
  | NFNatLeq Integer
  | NFLabel LabelType
  | NFFunc FuncType  -- (ρ, α, Π(x: A) B)
  | NFPair FuncType  -- (ρ, α, Σ(x: A) B)
  | NFInt
  | NFDouble
  | NFGType GType -- every ground type is also a type in normal form
  deriving (Show, Eq)

instance Subtypeable NFType where
  -- TODO: NFFunc and NFPair default to false, but should be handled explicitly
  isSubtypeOf NFBot _ = True
  isSubtypeOf NFDyn NFDyn = True
  isSubtypeOf NFUnit NFUnit = True
  isSubtypeOf NFNat NFNat = True
  isSubtypeOf (NFNatLeq _) NFNat = True
  isSubtypeOf (NFNatLeq n1) (NFNatLeq n2) = n1 <= n2
  isSubtypeOf (NFLabel ls1) (NFLabel ls2) = ls1 `Set.isSubsetOf` ls2
  isSubtypeOf NFInt NFInt = True
  isSubtypeOf NFDouble NFDouble = True
  isSubtypeOf (NFGType gt1) (NFGType gt2) = gt1 `isSubtypeOf` gt2
  isSubtypeOf _ _ = False

data GType = GUnit
  | GLabel LabelType
  | GFunc -- Π(x: *) *
  | GPair -- Σ(x: *) *
  | GNat
  | GNatLeq Integer
  deriving (Show, Eq)

instance Subtypeable GType where
  isSubtypeOf GUnit GUnit = True
  isSubtypeOf (GLabel ls1) (GLabel ls2) = ls1 `Set.isSubsetOf` ls2
  isSubtypeOf GFunc GFunc = True
  isSubtypeOf GPair GPair = True
  isSubtypeOf GNat GNat = True
  isSubtypeOf (GNatLeq _) GNat = True
  isSubtypeOf (GNatLeq n1) (GNatLeq n2) = n1 <= n2
  isSubtypeOf _ _ = False
