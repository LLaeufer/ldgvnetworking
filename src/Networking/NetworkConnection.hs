module Networking.NetworkConnection where

import Networking.NetworkBuffer
import Networking.RandomID
import qualified Data.Map as Map
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Concurrent.SSem as SSem

data NetworkConnection a b = NetworkConnection {ncRead :: NetworkBuffer a, ncWrite :: NetworkBuffer a, ncPartnerUserID :: String, ncOwnUserID :: String, ncConnectionState :: MVar.MVar ConnectionState, ncHandlingIncomingMessage :: SSem.SSem, ncSendQueue :: NetworkBuffer (Package b)}
    deriving Eq

data ConnectionState = Connected {csHostname :: String, csPort :: String, csPartnerConnectionID :: String, csOwnConnectionID :: String, csConfirmedConnection :: Bool}
                     | Disconnected {csHostname :: String, csPort :: String, csPartnerConnectionID :: String, csOwnConnectionID :: String, csConfirmedConnection :: Bool}
                     | Emulated {csPartnerConnectionID :: String, csOwnConnectionID :: String, csConfirmedConnection :: Bool}
                     | RedirectRequest {csHostname :: String, csPort :: String, csRedirectHostname :: String, csRedirectPort :: String, csPartnerConnectionID :: String, csOwnConnectionID :: String, csConfirmedConnection :: Bool} -- Asks to redirect to this connection
    deriving (Eq, Show)

type Package a = (String, String, a, Int)

newNetworkConnection :: String -> String -> String -> String -> String -> String -> IO (NetworkConnection a b)
newNetworkConnection partnerID ownID hostname port partnerConnectionID ownConnectionID = do
    read <- newNetworkBuffer 
    write <- newNetworkBuffer 
    connectionstate <- MVar.newMVar $ Connected hostname port partnerConnectionID ownConnectionID True
    incomingMsg <- SSem.new 1
    sendQueue <- newNetworkBuffer
    return $ NetworkConnection read write partnerID ownID connectionstate incomingMsg sendQueue


createNetworkConnection :: ([a], Int, Int) -> ([a], Int, Int) -> String -> String -> (String, String, String) -> IO (NetworkConnection a b)
createNetworkConnection (readList, readOffset, readLength) (writeList, writeOffset, writeLength) partnerID ownID (hostname, port, partnerConnectionID) = do
    read <- deserializeMinimal (readList, readOffset, readLength)
    write <- deserializeMinimal (writeList, writeOffset, writeLength)
    ownConnectionID <- newRandomID
    connectionstate <- if port=="" then 
            MVar.newMVar $ Disconnected "" "" partnerConnectionID ownConnectionID True 
        else 
            MVar.newMVar $ Connected hostname port partnerConnectionID ownConnectionID False
    incomingMsg <- SSem.new 1
    sendQueue <- newNetworkBuffer
    return $ NetworkConnection read write partnerID ownID connectionstate incomingMsg sendQueue


newEmulatedConnection :: MVar.MVar (Map.Map String (NetworkConnection a b)) -> IO (NetworkConnection a b, NetworkConnection a b)
newEmulatedConnection mvar = do
    ncmap <- MVar.takeMVar mvar
    read <- newNetworkBuffer 
    write <- newNetworkBuffer
    read2 <- newNetworkBuffer 
    write2 <- newNetworkBuffer
    connectionid1 <- newRandomID 
    connectionid2 <- newRandomID 
    sendQueue1 <- newNetworkBuffer
    sendQueue2 <- newNetworkBuffer
    connectionstate <- MVar.newMVar $ Emulated connectionid2 connectionid1 True
    connectionstate2 <- MVar.newMVar $ Emulated connectionid1 connectionid2 True
    userid <- newRandomID
    userid2 <- newRandomID
    incomingMsg <- SSem.new 1
    incomingMsg2 <- SSem.new 1
    let nc1 = NetworkConnection read write userid2 userid connectionstate incomingMsg sendQueue1 
    let nc2 = NetworkConnection read2 write2 userid userid2 connectionstate2 incomingMsg2 sendQueue2
    let ncmap1 = Map.insert userid2 nc1 ncmap
    let ncmap2 = Map.insert userid nc2 ncmap1
    MVar.putMVar mvar ncmap2
    return (nc1, nc2)

serializeNetworkConnection :: NetworkConnection a b -> IO ([a], Int, Int, [a], Int, Int, String, String, String, String, String)
serializeNetworkConnection nc = do
    constate <- MVar.readMVar $ ncConnectionState nc
    (readList, readOffset, readLength) <- serializeMinimal $ ncRead nc
    (writeList, writeOffset, writeLength) <- serializeMinimal $ ncWrite nc
    (address, port, partnerConnectionID) <- case constate of
        Connected address port partnerConnectionID _ _ -> return (address, port, partnerConnectionID)
        RedirectRequest address port _ _ partnerConnectionID _ _ -> return (address, port, partnerConnectionID)
        _ -> return ("", "", csPartnerConnectionID constate)
    return (readList, readOffset, readLength, writeList, writeOffset, writeLength, ncPartnerUserID nc, ncOwnUserID nc, address, port, partnerConnectionID)

changePartnerAddress :: NetworkConnection a b -> String -> String -> String -> IO ()
changePartnerAddress con hostname port partnerConnectionID = do
    oldConnectionState <- MVar.takeMVar $ ncConnectionState con
    MVar.putMVar (ncConnectionState con) $ Connected hostname port partnerConnectionID (csOwnConnectionID oldConnectionState) $ csConfirmedConnection oldConnectionState

disconnectFromPartner :: NetworkConnection a b -> IO ()
disconnectFromPartner con = do
    oldConnectionState <- MVar.takeMVar $ ncConnectionState con
    case oldConnectionState of
        Emulated {} -> 
            MVar.putMVar (ncConnectionState con) $ Disconnected "" "" (csPartnerConnectionID oldConnectionState) (csOwnConnectionID oldConnectionState) True
        _ -> MVar.putMVar (ncConnectionState con) $ Disconnected (csHostname oldConnectionState) (csPort oldConnectionState) (csPartnerConnectionID oldConnectionState) (csOwnConnectionID oldConnectionState) True

isConnectionConfirmed :: NetworkConnection a b -> IO Bool
isConnectionConfirmed con = do
    conState <- MVar.readMVar $ ncConnectionState con
    return $ csConfirmedConnection conState

confirmConnectionID :: NetworkConnection a b -> String -> IO Bool
confirmConnectionID con ownConnectionID = do
    conState <- MVar.takeMVar $ ncConnectionState con
    if ownConnectionID == csOwnConnectionID conState then do
        newConState <- case conState of
            Connected host port part own conf -> return $ Connected host port part own True
            Disconnected host port part own conf -> return $ Disconnected host port part own True
            Emulated part own conf -> return $ Emulated part own True
            RedirectRequest host port rehost report part own conf -> return $ RedirectRequest host port rehost report part own True
        MVar.putMVar (ncConnectionState con) newConState
        return True
        else do 
            MVar.putMVar (ncConnectionState con) conState
            return False

        

