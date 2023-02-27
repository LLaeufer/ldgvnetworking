module Networking.NetworkingMethod.Stateless where

import Networking.NetworkingMethod.NetworkingMethodCommon

import Network.Socket
import GHC.IO.Handle
import System.IO
import qualified Control.Concurrent.MVar as MVar
import qualified Data.Map as Map
import Control.Concurrent
import Control.Monad
import Control.Exception

import Networking.NetworkConnection
import ProcessEnvironmentTypes
import qualified Networking.Serialize as NSerialize
import qualified ValueParsing.ValueTokens as VT
import qualified ValueParsing.ValueGrammar as VG
import qualified Config
import qualified Syntax

type ConnectionHandler = ActiveConnectionsStateless -> MVar.MVar (Map.Map String (NetworkConnection Value Message)) -> MVar.MVar [(String, (Syntax.Type, Syntax.Type))] -> (Socket, SockAddr) -> Conversation -> String -> String -> Message -> IO ()

type Conversation = ConversationStateless 

sendMessage :: NSerialize.Serializable a => Conversation -> a -> IO ()
sendMessage conv@(handle, _) value = do
    serializedValue <- NSerialize.serialize value
    hPutStrLn handle (serializedValue ++" ")

sendResponse :: NSerialize.Serializable a => Conversation -> a -> IO ()
sendResponse = sendMessage

recieveMessageInternal :: Conversation -> VT.Alex t -> (String -> IO b) -> (String -> t -> IO b) -> IO b
recieveMessageInternal conv@(handle, _) grammar fallbackResponse messageHandler = do
    waitWhileEOF conv
    message <- hGetLine handle
    case VT.runAlex message grammar of
        Left err -> do
            Config.traceNetIO $ "Error during recieving a networkmessage: "++err++" Malformed message: " ++ message
            fallbackResponse message
        Right deserialmessage -> do
            messageHandler message deserialmessage


waitWhileEOF :: Conversation -> IO ()
waitWhileEOF conv@(handle, _) = do
    isEOF <- catch (hIsEOF handle) onException
    when isEOF (do
        threadDelay 10000
        waitWhileEOF conv
        )
    where
        onException :: IOException -> IO Bool
        onException _ = return True


startConversation :: ActiveConnectionsStateless -> String -> String -> Int -> Int -> IO (Maybe Conversation)
startConversation _ hostname port waitTime tries = do
    let hints = defaultHints {
                addrFamily = AF_INET
              , addrFlags = []
              , addrSocketType = Stream
            }
    convMVar <- MVar.newEmptyMVar
    threadid <- forkIO $ catch (do
        Config.traceNetIO $ "Trying to connect to: " ++ hostname ++":"++port
        addrInfo <- getAddrInfo (Just hints) (Just hostname) $ Just port
        clientsocket <- openSocketNC $ head addrInfo
        connect clientsocket $ addrAddress $ head addrInfo
        handle <- getHandleFromSocket clientsocket
        MVar.putMVar convMVar (handle, (clientsocket, addrAddress $ head addrInfo))
        Config.traceNetIO $ "Connected to: " ++ hostname ++ ":"++port
        ) $ printConErr hostname port
    getFromNetworkThread Nothing threadid convMVar waitTime tries


printConErr :: String -> String -> IOException -> IO ()
printConErr hostname port err = Config.traceIO $ "startConversation: Communication Partner " ++ hostname ++ ":" ++ port ++ "not found!"

waitForConversation :: ActiveConnectionsStateless -> String -> String -> Int -> Int -> IO (Maybe Conversation)
waitForConversation ac hostname port waitTime tries = do
    mbyConv <- startConversation ac hostname port waitTime tries
    case mbyConv of
        Just conv -> return mbyConv
        Nothing -> waitForConversation ac hostname port waitTime tries


acceptConversations :: ActiveConnectionsStateless -> ConnectionHandler -> Int -> MVar.MVar (Map.Map Int ServerSocket) ->  VChanConnections -> IO ServerSocket
acceptConversations ac connectionhandler port socketsmvar vchanconnections = do
    sockets <- MVar.takeMVar socketsmvar
    case Map.lookup port sockets of
        Just socket -> do
            MVar.putMVar socketsmvar sockets
            return socket
        Nothing -> do
            Config.traceIO "Creating socket!"
            clientlist <- createServer ac connectionhandler port vchanconnections
            Config.traceIO "Socket created"
            let newsocket = (clientlist, show port)
            let updatedMap = Map.insert port newsocket sockets
            MVar.putMVar socketsmvar updatedMap
            return newsocket
    where
        createServer :: ActiveConnectionsStateless -> ConnectionHandler -> Int -> VChanConnections -> IO (MVar.MVar [(String, (Syntax.Type, Syntax.Type))])
        createServer activeCons connectionhandler port vchanconnections = do
            sock <- socket AF_INET Stream 0
            setSocketOption sock ReuseAddr 1
            let hints = defaultHints {
                    addrFamily = AF_INET
                , addrFlags = [AI_PASSIVE]
                , addrSocketType = Stream
            }
            addrInfo <- getAddrInfo (Just hints) Nothing $ Just $ show port
            bind sock $ addrAddress $ head addrInfo
            listen sock 1024
            clientlist <- MVar.newEmptyMVar
            MVar.putMVar clientlist []
            forkIO $ acceptClients activeCons connectionhandler vchanconnections clientlist sock $ show port
            return clientlist
        acceptClients :: ActiveConnectionsStateless -> ConnectionHandler -> MVar.MVar (Map.Map String (NetworkConnection Value Message)) -> MVar.MVar [(String, (Syntax.Type, Syntax.Type))] -> Socket -> String -> IO ()
        acceptClients activeCons connectionhandler mvar clientlist socket ownport = do
            clientsocket <- accept socket

            forkIO $ acceptClient activeCons connectionhandler mvar clientlist clientsocket ownport
            acceptClients activeCons connectionhandler mvar clientlist socket ownport

        acceptClient :: ActiveConnectionsStateless -> ConnectionHandler -> MVar.MVar (Map.Map String (NetworkConnection Value Message)) -> MVar.MVar [(String, (Syntax.Type, Syntax.Type))] -> (Socket, SockAddr) -> String -> IO ()
        acceptClient activeCons connectionhandler mvar clientlist clientsocket ownport = do
            hdl <- getHandleFromSocket $ fst clientsocket
            let conv = (hdl, clientsocket)
            recieveMessageInternal conv VG.parseMessages (\_ -> return ()) $ connectionhandler activeCons mvar clientlist clientsocket conv ownport
            hClose hdl

getFromNetworkThread :: Maybe Conversation -> ThreadId -> MVar.MVar a -> Int -> Int -> IO (Maybe a)
getFromNetworkThread conv = getFromNetworkThreadWithModification conv Just

getFromNetworkThreadWithModification :: Maybe Conversation -> (a -> Maybe b) -> ThreadId -> MVar a -> Int -> Int -> IO (Maybe b)
getFromNetworkThreadWithModification conv func threadid mvar waitTime currentTry = do
        mbyResult <- MVar.tryReadMVar mvar
        case mbyResult of
            Just result -> return $ func result
            Nothing -> do
                if currentTry /= 0 then do
                    threadDelay waitTime
                    getFromNetworkThreadWithModification conv func threadid mvar waitTime $ max (currentTry-1) (-1)
                else do
                    killThread threadid
                    return Nothing

recieveResponse :: Conversation -> Int -> Int -> IO (Maybe Response)
recieveResponse conv waitTime tries = do
    retVal <- MVar.newEmptyMVar
    threadid <- forkIO $ recieveMessageInternal conv VG.parseResponses (\_ -> MVar.putMVar retVal Nothing) (\_ des -> MVar.putMVar retVal $ Just des)
    getFromNetworkThreadWithModification (Just conv) id threadid retVal waitTime tries

recieveNewMessage :: Conversation -> IO (Conversation, String, Message)
recieveNewMessage conv = do
    recieveMessageInternal conv VG.parseMessages (\_ -> recieveNewMessage conv) $ \s des -> return (conv, s, des)


endConversation :: Conversation -> Int -> Int -> IO ()
endConversation conv@(handle, _) waitTime tries = do
    finished <- MVar.newEmptyMVar
    threadid <- forkIO $ hClose handle >> MVar.putMVar finished True
    _ <- getFromNetworkThread (Just conv) threadid finished waitTime tries
    return ()

createActiveConnections :: IO ActiveConnectionsStateless
createActiveConnections = return ActiveConnectionsStateless

openSocketNC :: AddrInfo -> IO Socket
openSocketNC addr = socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)

getHandleFromSocket :: Socket -> IO Handle
getHandleFromSocket socket = do
    hdl <- socketToHandle socket ReadWriteMode
    -- hSetBuffering hdl NoBuffering
    hSetBuffering hdl LineBuffering
    return hdl

sayGoodbye :: ActiveConnectionsStateless -> IO ()
sayGoodbye _ = return ()

hostaddressTypeToString :: HostAddress -> String
hostaddressTypeToString hostaddress = do
    let (a, b, c, d) = hostAddressToTuple hostaddress
    show a ++ "." ++ show b ++ "."++ show c ++ "." ++ show d

getPartnerHostaddress :: Conversation -> String
getPartnerHostaddress conv@(handle, (socket, sockAddress)) = case sockAddress of
    SockAddrInet _ hostaddress -> hostaddressTypeToString hostaddress
    _ -> ""