module Networking.DirectionalConnection where

import Control.Concurrent.MVar
import Control.Concurrent
import qualified Control.Concurrent.SSem as SSem
import qualified System.Directory
import Control.Monad

data DirectionalConnection a = DirectionalConnection { messages :: MVar [a], messagesUnreadStart :: MVar Int, messagesCount :: MVar Int, readLock :: SSem.SSem}
    deriving Eq

newConnection :: IO (DirectionalConnection a)
newConnection = do
    messages <- newEmptyMVar
    putMVar messages []
    messagesUnreadStart <- newEmptyMVar 
    putMVar messagesUnreadStart 0
    messagesCount <- newEmptyMVar 
    putMVar messagesCount 0
    readLock <- SSem.new 1
    return $ DirectionalConnection messages messagesUnreadStart messagesCount readLock


createConnection :: [a] -> Int -> IO (DirectionalConnection a)
createConnection messages unreadStart = do
    msg <- newEmptyMVar
    putMVar msg messages
    messagesUnreadStart <- newEmptyMVar 
    putMVar messagesUnreadStart unreadStart
    messagesCount <- newEmptyMVar 
    putMVar messagesCount $ length messages
    readLock <- SSem.new 1
    return $ DirectionalConnection msg messagesUnreadStart messagesCount readLock


writeMessage :: DirectionalConnection a -> a -> IO ()
writeMessage connection message = do
    modifyMVar_ (messagesCount connection) (\c -> do
        modifyMVar_ (messages connection) (\m -> return $ m ++ [message])
        return $ c + 1
        )

writeMessageIfNext :: DirectionalConnection a -> Int -> a -> IO Bool
writeMessageIfNext connection count message = do
    modifyMVar (messagesCount connection) (\c ->
        if count == c + 1 then do 
            modifyMVar_ (messages connection) (\m -> return $ m ++ [message])
            return (c + 1, True) 
        else 
            return (c, False)
        )
    

-- This relies on the message array giving having the same first entrys as the internal messages
syncMessages :: DirectionalConnection a -> [a] -> IO ()
syncMessages connection msgs = do
    mymessagesCount <- takeMVar $ messagesCount connection
    mymessages <- takeMVar $ messages connection
    if length mymessages < length msgs then do 
        putMVar (messages connection) msgs
        putMVar (messagesCount connection) $ length msgs
    else do 
        putMVar (messages connection) mymessages
        putMVar (messagesCount connection) mymessagesCount

-- Gives all outMessages until this point
allMessages :: DirectionalConnection a -> IO [a]
allMessages connection = readMVar (messages connection)

readUnreadMessageMaybe :: DirectionalConnection a -> IO (Maybe a)
readUnreadMessageMaybe connection = modifyMVar (messagesUnreadStart connection) (\i -> do
    messagesBind <- allMessages connection
    if length messagesBind == i then return (i, Nothing) else return ((i+1), Just (messagesBind!!i))
    )
    
readUnreadMessage :: DirectionalConnection a -> IO a
readUnreadMessage connection = do
    maybeval <- readUnreadMessageMaybe connection
    case maybeval of
        Nothing -> do 
            threadDelay 5000
            readUnreadMessage connection
        Just val -> return val

readUnreadMessageInterpreter :: DirectionalConnection a -> IO a
readUnreadMessageInterpreter connection = do
    -- debugExists <- System.Directory.doesFileExist "print.me"
    -- when debugExists $ putStrLn "DC: Trying to read message"
    maybeval <- SSem.withSem (readLock connection) $ readUnreadMessageMaybe connection
    -- when debugExists $ putStrLn "DC: Read message"
    -- allVals <- countMessages connection
    -- currentRead <- readMVar $ messagesUnreadStart connection
    -- when debugExists $ putStrLn $ "DC: "++ show currentRead++" out of "++show allVals
    case maybeval of
        Nothing -> do 
            threadDelay 5000
            readUnreadMessageInterpreter connection
        Just val -> return val

serializeConnection :: DirectionalConnection a -> IO ([a], Int)
serializeConnection connection = do
    messageList <- allMessages connection
    messageUnread <- readMVar $ messagesUnreadStart connection
    return (messageList, messageUnread)

countMessages :: DirectionalConnection a -> IO Int
countMessages connection = readMVar $ messagesCount connection

lockInterpreterReads :: DirectionalConnection a -> IO ()
lockInterpreterReads  connection = SSem.wait (readLock connection)

unlockInterpreterReads :: DirectionalConnection a -> IO ()
unlockInterpreterReads  connection = SSem.signal (readLock connection)

test = do
    mycon <- newConnection
    writeMessage mycon "a"
    writeMessage mycon "b"
    allMessages mycon >>= print
    readUnreadMessage mycon >>= print
    allMessages mycon >>= print
    readUnreadMessage mycon >>= print
    readUnreadMessage mycon >>= print