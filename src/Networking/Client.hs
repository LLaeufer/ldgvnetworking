{-# LANGUAGE LambdaCase #-}

module Networking.Client where

import qualified Config
import ProcessEnvironmentTypes
import qualified Control.Concurrent.MVar as MVar
import qualified Networking.NetworkBuffer as NB
import qualified Networking.RandomID as RandomID
import qualified Data.Map as Map
import Control.Concurrent
import Control.Exception
import qualified Syntax
import qualified Networking.Common as NC
import Networking.NetworkConnection
import qualified Networking.Serialize as NSerialize
import Control.Monad
import qualified Networking.NetworkingMethod.NetworkingMethodCommon as NMC
import qualified Control.Concurrent.SSem as SSem
import qualified Networking.NetworkConnection as NCon
import qualified Networking.NetworkBuffer as NC


newtype ClientException = NoIntroductionException String
    deriving Eq

instance Show ClientException where
    show = \case
        NoIntroductionException s -> "Partner didn't introduce itself, but sent: " ++ s

instance Exception ClientException

sendValueInternal :: Bool -> VChanConnections -> NMC.ActiveConnections -> NetworkConnection Value Message -> Value -> String -> Int -> IO Bool
sendValueInternal threaded vchanconsmvar activeCons networkconnection val ownport resendOnError = do
    connectionstate <- MVar.readMVar $ ncConnectionState networkconnection
    case connectionstate of
        Emulated {} -> do
            --waitTillReadyToSend val
            vchancons <- MVar.readMVar vchanconsmvar
            valCleaned <- serializeVChan val
            NB.write(ncWrite networkconnection) valCleaned
            let ownid = ncOwnUserID networkconnection
            let mbypartner = Map.lookup ownid vchancons
            case mbypartner of
                Just partner -> do
                    NB.write (ncRead partner) valCleaned
                    return True
                _ -> do
                    Config.traceNetIO "Something went wrong when sending over a emulated connection"
                    return False
        _ -> do
            let hostname = csHostname connectionstate
            let port = csPort connectionstate
            --waitTillReadyToSend val
            setRedirectRequests vchanconsmvar activeCons hostname port ownport val
            Config.traceNetIO $ "Redirected: " ++ show val
            valcleaned <- serializeVChan val
            Config.traceNetIO $ "Serialized: " ++ show val
            messagesCount <- NB.write (ncWrite networkconnection) valcleaned
            Config.traceNetIO $ "Wrote to Buffer: " ++ show val
            let msg = NewValue (ncOwnUserID networkconnection) messagesCount valcleaned
            result <- if threaded then do
                NB.write (ncSendQueue networkconnection) (hostname, port, msg, resendOnError)
                return True
                else tryToSendNetworkMessage activeCons networkconnection hostname port msg resendOnError
            Config.traceNetIO $ "Sent message: " ++ show val
            return result

sendValue :: VChanConnections -> NMC.ActiveConnections -> NetworkConnection Value Message -> Value -> String -> Int -> IO Bool
sendValue = sendValueInternal False

sendValueThreaded :: VChanConnections -> NMC.ActiveConnections -> NetworkConnection Value Message -> Value -> String -> Int -> IO ()
sendValueThreaded vc ac nc v s i = void $ sendValueInternal True vc ac nc v s i

waitTillReadyToSend :: Value -> IO ()
waitTillReadyToSend input = do
    ready <- channelReadyToSend input
    unless ready $ threadDelay 5000 >> waitTillReadyToSend input

channelReadyToSend :: Value -> IO Bool
channelReadyToSend = searchVChans handleChannel True (&&)
    where
        handleChannel :: Value -> IO Bool
        handleChannel input = case input of
            VChan nc used -> NB.isAllAcknowledged $ ncWrite nc
            _ -> return True

sendNetworkMessageInternal :: Bool -> NMC.ActiveConnections -> NetworkConnection Value Message -> Message -> Int -> IO Bool
sendNetworkMessageInternal threaded activeCons networkconnection message resendOnError = do
    connectionstate <- MVar.readMVar $ ncConnectionState networkconnection
    case connectionstate of
        Emulated {} -> return True
        _ -> do
            let hostname = csHostname connectionstate
            let port = csPort connectionstate
            if threaded then do
                NB.write (ncSendQueue networkconnection) (hostname, port, message, resendOnError)
                return True
            else
                tryToSendNetworkMessage activeCons networkconnection hostname port message resendOnError

sendNetworkMessage :: NMC.ActiveConnections -> NetworkConnection Value Message -> Message -> Int -> IO Bool
sendNetworkMessage = sendNetworkMessageInternal False

sendNetworkMessageThreaded :: NMC.ActiveConnections -> NetworkConnection Value Message -> Message -> Int -> IO ()
sendNetworkMessageThreaded ac nc m i = void $ sendNetworkMessageInternal True ac nc m i

tryToSendNetworkMessage :: NMC.ActiveConnections -> NetworkConnection Value Message -> String -> String -> Message -> Int -> IO Bool
tryToSendNetworkMessage activeCons networkconnection hostname port message resendOnError = do
    serializedMessage <- NSerialize.serialize message
    sendingNetLog serializedMessage $ "Sending message as: " ++ ncOwnUserID networkconnection ++ " to: " ++  ncPartnerUserID networkconnection ++ " Over: " ++ hostname ++ ":" ++ port

    mbycon <- NC.startConversation activeCons hostname port 10000 10
    mbyresponse <- case mbycon of
        Just con -> do
            sendingNetLog serializedMessage "Aquired connection"
            NC.sendMessage con message
            sendingNetLog serializedMessage "Sent message"
            potentialResponse <- NC.recieveResponse con 10000 50
            sendingNetLog serializedMessage "Recieved response"
            NC.endConversation con 10000 10
            sendingNetLog serializedMessage "Ended connection"
            return potentialResponse
        Nothing -> do
            sendingNetLog serializedMessage "Connecting unsuccessful"
            return Nothing

    success <- case mbyresponse of
        Just response -> case response of
            Okay -> do
                sendingNetLog serializedMessage "Message okay"
                return True
            Redirect host port -> do
                sendingNetLog serializedMessage "Communication partner changed address, resending"
                tryToSendNetworkMessage activeCons networkconnection host port message resendOnError
            Wait -> do
                sendingNetLog serializedMessage "Communication out of sync lets wait!"
                threadDelay 1000000
                tryToSendNetworkMessage activeCons networkconnection hostname port message resendOnError
            _ -> do
                sendingNetLog serializedMessage "Unknown communication error"
                return False

        Nothing -> do
            sendingNetLog serializedMessage "Error when recieving response"
            if resendOnError /= 0 then do
                connectionState <- MVar.readMVar $ ncConnectionState networkconnection
                case connectionState of
                    Connected updatedhost updatedport _ _ _ -> do
                        sendingNetLog serializedMessage $ "Trying to resend to: " ++ updatedhost ++ ":" ++ updatedport
                        tryToSendNetworkMessage activeCons networkconnection updatedhost updatedport message $ max (resendOnError-1) (-1)
                    _ -> return False
            else return False
    sendingNetLog serializedMessage "Message got send or finally failed!"
    return success


sendingNetLog :: String -> String -> IO ()
sendingNetLog msg info = Config.traceNetIO $ "Sending message: "++msg++" \n    Status: "++info

printConErr :: String -> String -> IOException -> IO Bool
printConErr hostname port err = do
    Config.traceIO $ "Communication Partner " ++ hostname ++ ":" ++ port ++ "not found! \n    " ++ show err
    return False


initialConnect :: NMC.ActiveConnections -> VChanConnections  -> String -> String -> String -> (Syntax.Type, Syntax.Type) -> IO Value
initialConnect activeCons mvar hostname port ownport syntype= do
    mbycon <- NC.waitForConversation activeCons hostname port 1000 100  -- This should be 10000 100 in the real world, expecting just a 100ms ping in the real world might be a little aggressive.

    case mbycon of
        Just con -> do
            ownuserid <- RandomID.newRandomID
            NC.sendMessage con (IntroduceClient ownuserid ownport (fst syntype) $ snd syntype)
            mbyintroductionanswer <- NC.recieveResponse con 10000 (-1)
            NC.endConversation con 10000 10
            case mbyintroductionanswer of
                Just introduction -> case introduction of
                    OkayIntroduce introductionanswer -> do
                        msgserial <- NSerialize.serialize $ IntroduceClient ownuserid ownport (fst syntype) $ snd syntype
                        Config.traceNetIO $ "Sending message as: " ++ ownuserid ++ " to: " ++  introductionanswer
                        Config.traceNetIO $ "    Over: " ++ hostname ++ ":" ++ port
                        Config.traceNetIO $ "    Message: " ++ msgserial
                        newConnection <- newNetworkConnection introductionanswer ownuserid hostname port introductionanswer ownuserid
                        
                        -- Setup threaded message sending
                        forkIO $ iterateOnSendQueue activeCons newConnection

                        networkconnectionmap <- MVar.takeMVar mvar
                        let newNetworkconnectionmap = Map.insert introductionanswer newConnection networkconnectionmap
                        MVar.putMVar mvar newNetworkconnectionmap
                        used <- MVar.newEmptyMVar
                        MVar.putMVar used False
                        return $ VChan newConnection used

                    _ -> do
                        introductionserial <- NSerialize.serialize introduction
                        Config.traceNetIO $ "Illegal answer from server: " ++ introductionserial
                        threadDelay 1000000
                        initialConnect activeCons mvar hostname port ownport syntype
                Nothing -> do
                    Config.traceNetIO "Something went wrong while connection to the server"
                    threadDelay 1000000
                    initialConnect activeCons mvar hostname port ownport syntype
        Nothing -> do
            Config.traceNetIO "Couldn't connect to server. Retrying"
            threadDelay 1000000
            initialConnect activeCons mvar hostname port ownport syntype

setRedirectRequests :: VChanConnections -> NMC.ActiveConnections -> String -> String -> String -> Value -> IO Bool
setRedirectRequests vchanconmvar activeconnections newhost newport ownport = searchVChans (handleVChan vchanconmvar activeconnections newhost newport ownport) True (&&)
    where
        handleVChan ::  VChanConnections -> NMC.ActiveConnections -> String -> String -> String -> Value -> IO Bool
        handleVChan vchanconmvar activeconnections newhost newport ownport input = case input of
            VChan nc _ -> do
                Config.traceNetIO $ "Trying to set RedirectRequest for " ++ ncPartnerUserID nc ++ " to " ++ newhost ++ ":" ++ newport

                SSem.withSem (ncHandlingIncomingMessage nc) (do
                    oldconnectionstate <- MVar.takeMVar $ ncConnectionState nc
                    case oldconnectionstate of
                        Connected hostname port partConID ownConID confirmed -> MVar.putMVar (ncConnectionState nc) $ RedirectRequest hostname port newhost newport partConID ownConID confirmed
                        RedirectRequest hostname port _ _ partConID ownConID confirmed -> MVar.putMVar (ncConnectionState nc) $ RedirectRequest hostname port newhost newport partConID ownConID confirmed
                        Emulated partConID ownConID confirmed -> do
                            Config.traceNetIO "TODO: Allow RedirectRequest for Emulated channel"
                            vchanconnections <- MVar.takeMVar vchanconmvar

                            let userid = ncOwnUserID nc
                            let mbypartner = Map.lookup userid vchanconnections
                            case mbypartner of
                                Just partner -> do
                                    MVar.putMVar (ncConnectionState nc) $ RedirectRequest "" ownport newhost newport partConID ownConID confirmed -- Setting this to 127.0.0.1 is a temporary hack
                                    oldconectionstatePartner <- MVar.takeMVar $ ncConnectionState partner
                                    MVar.putMVar (ncConnectionState partner) $ Connected newhost newport partConID ownConID confirmed

                                    -- Setup threaded sending for partner
                                    void $ forkIO $ iterateOnSendQueue activeconnections partner 
                                Nothing -> do
                                    MVar.putMVar (ncConnectionState nc) oldconnectionstate
                                    Config.traceNetIO "Error occured why getting the linked emulated channel"


                            MVar.putMVar vchanconmvar vchanconnections
                        Disconnected hostname partner partConID ownConID confirmed -> do
                            MVar.putMVar (ncConnectionState nc) oldconnectionstate
                            Config.traceNetIO "Cannot set RedirectRequest for a disconnected channel"
                    )
                Config.traceNetIO $ "Set RedirectRequest for " ++ ncPartnerUserID nc ++ " to " ++ newhost ++ ":" ++ newport
                return True
            _ -> return True

serializeVChan :: Value -> IO Value
serializeVChan = modifyVChans handleVChan
    where
        handleVChan :: Value -> IO Value
        handleVChan input = case input of
            VChan nc _-> do
                waitTillEmpty nc
                (r, ro, rl, w, wo, wl, pid, oid, h, p, partConID) <- serializeNetworkConnection nc
                return $ VChanSerial (r, ro, rl) (w, wo, wl) pid oid (h, p, partConID)
            _ -> return input
        waitTillEmpty :: NetworkConnection Value Message -> IO ()
        waitTillEmpty nc = do
            empty <- NC.isEmpty $ ncSendQueue nc
            unless empty $ threadDelay 5000 >> waitTillEmpty nc

sendDisconnect :: NMC.ActiveConnections -> MVar.MVar (Map.Map String (NetworkConnection Value Message)) -> IO ()
sendDisconnect ac mvar = do
    networkConnectionMap <- MVar.readMVar mvar
    let allNetworkConnections = Map.elems networkConnectionMap
    goodbyes <- doForall ac allNetworkConnections
    unless goodbyes $ do
        threadDelay 100000
        sendDisconnect ac mvar
    where
        doForall ac (x:xs) = do
            xres <- sendDisconnectNetworkConnection ac x
            rest <- doForall ac xs
            return $ xres && rest
        doForall ac [] = return True
        sendDisconnectNetworkConnection :: NMC.ActiveConnections -> NetworkConnection Value Message -> IO Bool
        sendDisconnectNetworkConnection ac con = do
            let writeVals = ncWrite con
            let sendQ = ncSendQueue con
            connectionState <- MVar.readMVar $ ncConnectionState con
            -- unreadVals <- DC.unreadMessageStart writeVals
            -- lengthVals <- DC.countMessages writeVals
            -- Config.traceNetIO "Checking if everything is acknowledged"
            -- NB.serialize writeVals >>= Config.traceNetIO . show
            -- NB.isAllAcknowledged writeVals >>= Config.traceNetIO . show
            case connectionState of
                Connected host port _ _ _ -> do
                    allAck <- NB.isAllAcknowledged writeVals
                    allSend <- NB.isEmpty sendQ
                    let ret = allAck && allSend
                    if ret then do
                        sent <- catch (sendNetworkMessage ac con (Disconnect $ ncOwnUserID con) $ -1) (\x -> printConErr host port x >> return True)
                        when sent $ NCon.disconnectFromPartner con  -- This should cause a small speedup
                        return sent
                    else
                        return False
                    -- return False
                _ -> return True

iterateOnSendQueue :: NMC.ActiveConnections -> NetworkConnection Value Message -> IO ()
iterateOnSendQueue activecons nc = do
    mbyPkg <- NB.tryGetAtNB (ncSendQueue nc) 0
    case mbyPkg of
        Just (hostname, port, msg, resend) -> do 
            void $ tryToSendNetworkMessage activecons nc hostname port msg resend
            NB.tryTake $ ncSendQueue nc
        Nothing -> threadDelay 5000
    iterateOnSendQueue activecons nc

                    