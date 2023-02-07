module Networking.NetworkingMethod.Fast where

import Networking.NetworkingMethod.NetworkingMethodCommon
import Network.Socket
import GHC.IO.Handle
import System.IO
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Concurrent.Chan as Chan
import qualified Data.Maybe
import qualified Data.Map as Map
import Control.Concurrent
import Control.Monad
import Control.Exception

import Networking.Messages
import Networking.NetworkConnection
import Networking.UserID
import qualified Syntax
import qualified Networking.Serialize as NSerialize
import qualified ValueParsing.ValueTokens as VT
import qualified ValueParsing.ValueGrammar as VG
import qualified Config
import qualified Networking.NetworkingMethod.Stateless as Stateless
import ProcessEnvironmentTypes
import qualified Control.Concurrent.SSem as SSem

type ResponseMapMVar = MVar.MVar (Map.Map String (String, Responses))

data Conversation = Conversation {convID :: String, convHandle :: Stateless.Conversation, convRespMap :: ResponseMapMVar, convSending :: SSem.SSem}

type ConnectionHandler = ActiveConnectionsFast -> MVar.MVar (Map.Map String (NetworkConnection Value)) -> MVar.MVar [(String, Syntax.Type)] -> (Socket, SockAddr) -> Conversation -> String -> String -> Messages -> IO ()

-- type NetworkAddress = (String, String)
--  deriving (Eq, Show, Ord)

-- type Connectionhandler = MVar.MVar (Map.Map String (NetworkConnection Value)) -> MVar.MVar [(String, Syntax.Type)] -> (Socket, SockAddr) -> Handle -> String -> String -> Messages -> IO ()


sendMessage ::  Conversation -> Messages -> IO ()
sendMessage conv value = SSem.withSem (convSending conv) $ Stateless.sendMessage (convHandle conv) (ConversationMessage (convID conv) value)

sendResponse :: Conversation -> Responses -> IO ()
sendResponse conv value = SSem.withSem (convSending conv) $ Stateless.sendResponse (convHandle conv) (ConversationResponse (convID conv) value)

conversationHandler :: Stateless.Conversation -> IO Connection
conversationHandler handle = do
    chan <- Chan.newChan
    mvar <- MVar.newEmptyMVar
    MVar.putMVar mvar Map.empty
    sem <- SSem.new 1
    conversationHandlerChangeHandle handle chan mvar sem

conversationHandlerChangeHandle handle chan mvar sem = do
    isClosed <- MVar.newEmptyMVar
    MVar.putMVar isClosed False
    forkIO $ whileNotMVar isClosed (do
        -- Config.traceNetIO "Waiting for new conversation"
        Stateless.recieveMessageInternal handle VG.parseConversation (\_ -> return ()) (\mes des -> do
            -- Config.traceNetIO "Got new conversation"  
            case des of
                ConversationMessage cid message -> Chan.writeChan chan (cid, (mes, message))
                ConversationResponse cid response -> do
                    -- Config.traceNetIO "Trying to take mvar"
                    mymap <- MVar.takeMVar mvar
                    MVar.putMVar mvar $ Map.insert cid (mes, response) mymap
                    -- Config.traceNetIO "Set responses mvar"
                ConversationCloseAll -> do
                    Config.traceNetIO $ "Recieved Message: " ++ mes
                    MVar.takeMVar isClosed
                    MVar.putMVar isClosed True
                    forkIO $ catch (do
                        closed <- hIsClosed $ fst handle
                        unless closed $ hClose $ fst handle) onException
                    return ()
            )
        )
    return (handle, isClosed, chan, mvar, sem)
    where
        whileNotMVar :: MVar.MVar Bool -> IO () -> IO ()
        whileNotMVar mvar func = do
            shouldStop <- MVar.readMVar mvar
            unless shouldStop (do
                _ <- func
                whileNotMVar mvar func
                )
        onException :: IOException -> IO ()
        onException _ = return ()



recieveResponse :: Conversation -> Int -> Int -> IO (Maybe Responses)
recieveResponse conv{-ersation@(cid, handle, mvar, sem)-} waitTime tries = do
    -- Config.traceNetIO "Trying to take mvar for responses mvar"
    responsesMap <- MVar.takeMVar $ convRespMap conv
    -- Config.traceNetIO "Got MVar for responses"
    case Map.lookup (convID conv) responsesMap of
        Just (messages, deserial) -> do
            MVar.putMVar (convRespMap conv) $ Map.delete (convID conv) responsesMap
            return $ Just deserial
        Nothing -> do
            MVar.putMVar (convRespMap conv) responsesMap
            handleClosed <- hIsClosed $ fst (convHandle conv)
            if tries /= 0 && not handleClosed then do
                -- Config.traceNetIO "Nothing yet retrying!" 
                threadDelay waitTime
                recieveResponse conv waitTime $ max (tries-1) (-1) else return Nothing

recieveNewMessage :: Connection -> IO (Conversation, String, Messages)
recieveNewMessage connection@(handle, isClosed, chan, mvar, sem) = do
    (cid, (serial, deserial)) <- Chan.readChan chan
    return (Conversation cid handle mvar sem, serial, deserial)


startConversation :: ActiveConnectionsFast -> String -> String -> Int -> Int -> IO (Maybe Conversation)
startConversation acmvar hostname port waitTime tries = do
    conversationid <- newRandomUserID
    connectionMap <- MVar.takeMVar acmvar
    case Map.lookup (hostname, port) connectionMap of
        Just (handle, isClosed, chan, mvar, sem) -> do
            handleClosed <- MVar.readMVar isClosed
            if handleClosed then do
                statelessActiveCons <- Stateless.createActiveConnections
                mbyNewHandle <- Stateless.startConversation statelessActiveCons hostname port waitTime tries
                case mbyNewHandle of
                    Just handle -> do
                        newconnection@(handle, isClosed, chan, mvar, sem) <- conversationHandlerChangeHandle handle chan mvar sem
                        MVar.putMVar acmvar $ Map.insert (hostname, port) newconnection connectionMap
                        return $ Just (Conversation conversationid handle mvar sem)
                    Nothing -> do
                        MVar.putMVar acmvar connectionMap
                        return Nothing
            else do
                MVar.putMVar acmvar connectionMap
                return $ Just (Conversation conversationid handle mvar sem)
        Nothing -> do
            statelessActiveCons <- Stateless.createActiveConnections
            mbyNewHandle <- Stateless.startConversation statelessActiveCons hostname port waitTime tries
            case mbyNewHandle of
                Just handle -> do
                    newconnection@(handle, isClosed, chan, mvar, sem) <- conversationHandler handle
                    MVar.putMVar acmvar $ Map.insert (hostname, port) newconnection connectionMap
                    return $ Just (Conversation conversationid handle mvar sem)
                Nothing -> do
                    MVar.putMVar acmvar connectionMap
                    return Nothing

waitForConversation :: ActiveConnectionsFast -> String -> String -> Int -> Int -> IO (Maybe Conversation)
waitForConversation ac hostname port waitTime tries = do
    mbyHandle <- startConversation ac hostname port waitTime tries
    case mbyHandle of
        Just handle -> return mbyHandle
        Nothing -> waitForConversation ac hostname port waitTime tries

createActiveConnections :: IO ActiveConnectionsFast
createActiveConnections = do
    activeConnections <- MVar.newEmptyMVar
    MVar.putMVar activeConnections Map.empty
    return activeConnections


acceptConversations :: ActiveConnectionsFast -> ConnectionHandler -> Int -> MVar.MVar (Map.Map Int ServerSocket) -> VChanConnections -> IO ServerSocket
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
        createServer :: ActiveConnectionsFast -> ConnectionHandler -> Int -> VChanConnections ->  IO (MVar.MVar [(String, Syntax.Type)])
        createServer activeCons connectionhandler port vchanconnections = do
            -- serverid <- UserID.newRandomUserID
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

        acceptClients :: ActiveConnectionsFast -> ConnectionHandler -> MVar.MVar (Map.Map String (NetworkConnection Value)) -> MVar.MVar [(String, Syntax.Type)] -> Socket -> String -> IO ()
        acceptClients activeCons connectionhandler mvar clientlist socket ownport = do
            Config.traceIO "Waiting for clients"
            clientsocket <- accept socket
            Config.traceIO "Accepted new client"

            forkIO $ acceptClient activeCons connectionhandler mvar clientlist clientsocket ownport
            acceptClients activeCons connectionhandler mvar clientlist socket ownport

        acceptClient :: ActiveConnectionsFast -> ConnectionHandler -> MVar.MVar (Map.Map String (NetworkConnection Value)) -> MVar.MVar [(String, Syntax.Type)] -> (Socket, SockAddr) -> String -> IO ()
        acceptClient activeCons connectionhandler mvar clientlist clientsocket ownport = do
            hdl <- Stateless.getSocketFromHandle $ fst clientsocket
            let statelessConv = (hdl, clientsocket)
            connection@(handle, isClosed, chan, responsesMvar, sem) <- conversationHandler statelessConv 
            -- NC.recieveMessage hdl VG.parseMessages (\_ -> return ()) $ connectionhandler mvar clientlist clientsocket hdl ownport
            forkIO $ forever (do
                (conversationid, (serial, deserial)) <- Chan.readChan chan
                connectionhandler activeCons mvar clientlist clientsocket (Conversation conversationid statelessConv responsesMvar sem) ownport serial deserial
                )
            return ()
            -- hClose hdl  


endConversation :: Conversation -> Int -> Int -> IO ()
endConversation _ _ _ = return ()

sayGoodbye :: ActiveConnectionsFast -> IO ()
sayGoodbye activeCons = do
    activeConsMap <- MVar.readMVar activeCons
    let connections = Map.elems activeConsMap
    runAll sayGoodbyeConnection connections
    where
        sayGoodbyeConnection :: Connection -> IO ()
        sayGoodbyeConnection connection@(statelessconv@(handle, _), isClosed, messages, responses, sem) = do
            forkIO $ catch (do
                handleClosed <- MVar.readMVar isClosed
                unless handleClosed $ SSem.withSem sem $ Stateless.sendMessage statelessconv ConversationCloseAll
                unless handleClosed $ SSem.withSem sem $ hPutStr handle " "
                hFlushAll handle
                hClose handle
                ) onException
            return ()
        runAll _ [] = return ()
        runAll f (x:xs) = do
            _ <- f x
            runAll f xs
        onException :: IOException -> IO ()
        onException _ = return ()


isClosed :: Conversation -> IO Bool
isClosed = hIsClosed . fst . convHandle

getPartnerHostaddress :: Conversation -> String
getPartnerHostaddress = Stateless.getPartnerHostaddress . convHandle
