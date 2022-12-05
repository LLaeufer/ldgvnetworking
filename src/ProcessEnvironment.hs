{-# LANGUAGE LambdaCase #-}

module ProcessEnvironment where
import Syntax as S
import GHC.IO.Handle
import Control.Concurrent.Chan as C
import Control.Concurrent.MVar as MVar
import Control.Monad.Reader as T
import Data.Set (Set)
import Data.Map as Map
import qualified Data.Set as Set
import Kinds (Multiplicity(..))

import Networking.DirectionalConnection
-- import qualified Networking.Common as NC

import Network.Socket
-- import qualified Networking.Common as NC

-- | the interpretation monad
type InterpretM a = T.ReaderT PEnv IO a

extendEnv :: String -> Value -> PEnv -> PEnv
extendEnv = curry (:)

-- | a Process Envronment maps identifiers to Values of expressions and stores
type PEnv = [PEnvEntry]
type PEnvEntry = (String, Value)

type Label = String
type LabelType = Set Label

labelsFromList :: [Label] -> LabelType
labelsFromList = Set.fromList

data FuncType = FuncType PEnv String S.Type S.Type
  deriving Eq

instance Show FuncType where
  show (FuncType _ s t1 t2) = "FuncType " ++ show s ++ " " ++ show t1 ++ " " ++ show t2


type ValueRepr = String

-- | (Unit, Label, Int, Values of self-declared Data Types), Channels
data Value
  = VUnit
  | VLabel String
  | VInt Int
  | VDouble Double
  | VString String
  -- we have two channels, one for reading and one for writing to the other
  -- end, so we do not read our own written values
  -- | VChan (C.Chan Value) (C.Chan Value) (Maybe Handle) (Maybe SockAddr) (Maybe String) (Maybe String)
  | VChan CommunicationChannel
  --        Read Chan       Write Chan    Handle of Con   Address of other  other Userid  own UserID
--  | VChan (C.Chan Value) (C.Chan Value)
  | VSend Value
  | VPair Value Value -- pair of ids that map to two values
  | VType S.Type
  | VFunc PEnv String Exp
  | VDynCast Value GType -- (Value : G => *)
  | VFuncCast Value FuncType FuncType -- (Value : (ρ,α,Π(x:A)A') => (ρ,α,Π(x:B)B'))
  | VRec PEnv String String Exp Exp
  | VNewNatRec PEnv String String String Type Exp String Exp
  -- | VServerSocket (MVar.MVar Socket)
  -- | VServerSocket Socket
  | VServerSocket (MVar.MVar (Map.Map String ConnectionInfo)) (C.Chan String) String
                                                                              -- This is the server id
  deriving Eq

data ConnectionInfo = ConnectionInfo {ciHandle :: Handle, ciAddr :: SockAddr, ciReadChannel :: DirectionalConnection Value, ciWriteChannel :: DirectionalConnection Value}
  deriving Eq

-- data CommunicationChannel = CommunicationChannel {ccRead :: DirectionalConnection Value, ccWrite :: DirectionalConnection Value, ccPartnerUserID :: Maybe String, ccOwnUserID :: Maybe String, ccPartnerAddress :: Maybe (MVar.MVar SockAddr), ccChannelState :: MVar.MVar ChannelState}
data CommunicationChannel = CommunicationChannel {ccRead :: DirectionalConnection Value, ccWrite :: DirectionalConnection Value, ccPartnerUserID :: Maybe String, ccOwnUserID :: Maybe String, ccChannelState :: MVar.MVar ChannelState}
  deriving Eq
                                                                                                                                                                                                   -- Change this to Maybe MVar SockAddr                                           

data ChannelState = Connected {csConInfoMap :: MVar.MVar (Map.Map String ConnectionInfo)}
                  | Disconnected
                  | Emulated
                  | Disabled -- Used when a Channel was sent  --> Maybe we can automatically change this on serialization when we put this in a MVar 
  deriving Eq


-- If a channel is about to be send it should be deactivated
disableVChan :: Value -> IO ()
disableVChan = \case
  VSend v -> disableVChan v
  VPair v1 v2 -> disableVChan v1 >> disableVChan v2
  VFunc penv _ _ -> disableVChanArr penv
  VDynCast v _ -> disableVChan v
  VFuncCast v _ _ -> disableVChan v
  VRec penv _ _ _ _ -> disableVChanArr penv
  VNewNatRec penv _ _ _ _ _ _ _ -> disableVChanArr penv
  VChan cc -> do
    channelstate <- MVar.takeMVar $ ccChannelState cc
    case channelstate of
      Connected infomap -> MVar.putMVar (ccChannelState cc) Disabled
      _ -> MVar.putMVar (ccChannelState cc) channelstate
  _ -> return ()
  where
    disableVChanArr :: PEnv -> IO ()
    disableVChanArr [] = return ()
    disableVChanArr (x:xs) = disableVChan (snd x) >> disableVChanArr xs





instance Show Value where
  show = \case
    VUnit -> "VUnit"
    VLabel s -> "VLabel " ++ s
    VInt i -> "VInt " ++ show i
    VDouble d -> "VDouble " ++ show d
    VString s -> "VString \"" ++ show s ++ "\""
    VChan {} -> "VChan"
    VSend v -> "VSend (" ++ show v ++ ")"
    VPair a b -> "VPair <" ++ show a ++ ", " ++ show b ++ ">"
    VType t -> "VType " ++ show t
    VFunc _ s exp -> "VFunc " ++ show s ++ " " ++ show exp
    VDynCast v t -> "VDynCast (" ++ show v ++ ") (" ++ show t ++ ")"
    VFuncCast v ft1 ft2 -> "VFuncCast (" ++ show v ++ ") (" ++ show ft1 ++ ") (" ++ show ft2 ++ ")"
    VRec env f x e1 e0 -> "VRec " ++ " " ++ f ++ " " ++ x ++ " " ++ show e1 ++ " " ++ show e0
    VNewNatRec env f n tid ty ez x es -> "VNewNatRec " ++ f ++ n ++ tid ++ show ty ++ show ez ++ x ++ show es
    VServerSocket {} -> "VServerSocket"

class Subtypeable t where
  isSubtypeOf :: t -> t -> Bool

-- Types in Head Normal Form
data NFType
  = NFBot
  | NFDyn
  | NFFunc FuncType  -- (ρ, α, Π(x: A) B)
  | NFPair FuncType  -- (ρ, α, Σ(x: A) B)
  | NFGType GType -- every ground type is also a type in normal form
  deriving (Show, Eq)

instance Subtypeable NFType where
  -- NFFunc and NFPair default to false, which is not really correct.
  -- Implementation would be quite complicated and its not necessary,
  -- i.e. not used anywhere.
  isSubtypeOf NFBot _ = True
  isSubtypeOf NFDyn NFDyn = True
  isSubtypeOf (NFGType gt1) (NFGType gt2) = gt1 `isSubtypeOf` gt2
  isSubtypeOf _ _ = False

data GType
  = GUnit
  | GLabel LabelType
  | GFunc Multiplicity -- Π(x: *) *
  | GPair -- Σ(x: *) *
  | GNat
  | GNatLeq Integer
  | GInt
  | GDouble
  | GString
  deriving (Show, Eq)

instance Subtypeable GType where
  isSubtypeOf GUnit GUnit = True
  isSubtypeOf (GLabel ls1) (GLabel ls2) = ls1 `Set.isSubsetOf` ls2
  isSubtypeOf (GFunc _) (GFunc _) = True
  isSubtypeOf (GPair) (GPair) = True
  isSubtypeOf GNat GNat = True
  isSubtypeOf (GNatLeq _) GNat = True
  isSubtypeOf (GNatLeq n1) (GNatLeq n2) = n1 <= n2
  isSubtypeOf GInt GInt = True
  isSubtypeOf GDouble GDouble = True
  isSubtypeOf GString GString = True
  isSubtypeOf _ _ = False
