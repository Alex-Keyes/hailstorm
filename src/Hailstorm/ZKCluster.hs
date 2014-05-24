module Hailstorm.ZKCluster
( MasterState(..)
, ZKOptions (..)
, childrenWatchLoop
, createMasterState
, getStatus
, initializeCluster
, monitorMasterState
, quietZK
, registerProcessor
, setMasterState
) where

import Control.Concurrent
import Control.Monad
import Hailstorm.Processor
import qualified Database.Zookeeper as ZK
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8

type ProcessorAction = (ZK.Zookeeper -> IO ())
data ZKOptions       = ZKOptions { connectionString :: String }

data MasterState = Unavailable | Initialization | SpoutPause | GreenLight
    deriving (Eq, Read, Show)

-- | Zookeeper node for living processors.
zkLivingProcessorsNode :: String
zkLivingProcessorsNode = "/living_processors"

-- | Master state 
zkMasterStateNode :: String
zkMasterStateNode = "/master_state"

-- | Timeout for Zookeeper connections.
zkTimeout :: ZK.Timeout
zkTimeout = 10000

registerProcessor :: ZKOptions
                  -> ProcessorId
                  -> ProcessorAction
                  -> IO ()
registerProcessor opts p@(pname, pinstance) action =
    withConnection opts $ \zk -> do
        me <- ZK.create zk (zkLivingProcessorsNode ++ "/" ++ pname ++ "-" ++ show pinstance)

            Nothing ZK.OpenAclUnsafe [ZK.Ephemeral]
        case me of
            Left e  -> putStrLn $
                "Error (register " ++ show p ++ ") from zookeeper: " ++
                    show e
            Right _ -> do putStrLn $ "Added to zookeeper: " ++ show p
                          action zk

initializeCluster :: ZKOptions -> IO ()
initializeCluster opts = withConnection opts $ \zk -> do
    me <- ZK.create zk zkLivingProcessorsNode Nothing ZK.OpenAclUnsafe []
    case me of
        Left e -> putStrLn $ "Error (initialize) from zookeeper: " ++ show e
        Right _ -> return ()

getStatus :: ZKOptions -> IO String
getStatus opts = withConnection opts $ \zk -> do
    me <- ZK.getChildren zk zkLivingProcessorsNode Nothing
    case me of
        Left e  -> return $ "Error (get status) from zookeeper: " ++ show e
        Right p -> return $ "Living processors: " ++ show p

-- | Delivers children change events to the callback. Uses the same thread
-- as was called in with
childrenWatchLoop :: ZK.Zookeeper -> String -> ([String] -> IO ()) -> IO ()
childrenWatchLoop zk path cb = do
    childrenVar <- newMVar True
    _ <- ZK.getChildren zk path (Just $ watcher childrenVar)
    childLoop childrenVar []

    where watcher childrenVar _ _ _ _ = putMVar childrenVar True
          childLoop childrenVar lastChildren = do
            _ <- takeMVar childrenVar
            me <- ZK.getChildren zk path (Just $ watcher childrenVar)
            case me of
              Left e -> do 
                putStrLn $ "Error in children watch loop from zookeeper: " ++ show e
                childLoop childrenVar lastChildren
              Right children -> do when (children /= lastChildren) (cb children)
                                   childLoop childrenVar children

-- | Delivers master state change events to the callback. Uses the same thread
-- as was called in with
monitorMasterState :: ZK.Zookeeper -> (Either ZK.ZKError MasterState -> IO ()) -> IO ()
monitorMasterState zk cb = do
    mVar <- newMVar True
    _ <- ZK.get zk zkMasterStateNode (Just $ watcher mVar)
    monitorLoop mVar Unavailable

    where watcher mVar _ _ _ _ = putMVar mVar True
          monitorLoop mVar lastState = do
            _ <- takeMVar mVar
            me <- ZK.get zk zkMasterStateNode (Just $ watcher mVar)
            case me of 
                (Left e) -> cb (Left e) >> monitorLoop mVar lastState
                (Right (Just s, _)) -> do
                    let ms = deserializeMasterState s
                    when (lastState /= ms) (cb $ Right ms)
                    monitorLoop mVar ms
                _ -> cb (Left ZK.NothingError) >> monitorLoop mVar lastState

deserializeMasterState :: BS.ByteString -> MasterState
deserializeMasterState = read . C8.unpack

serializeMasterState :: MasterState -> BS.ByteString
serializeMasterState = C8.pack . show 

createMasterState :: ZK.Zookeeper -> MasterState -> IO (Either ZK.ZKError String)
createMasterState zk ms = ZK.create zk zkMasterStateNode 
                            (Just $ serializeMasterState ms) ZK.OpenAclUnsafe [ZK.Ephemeral]

setMasterState :: ZK.Zookeeper -> MasterState -> IO (Either ZK.ZKError ZK.Stat)
setMasterState zk ms = ZK.set zk zkMasterStateNode
                        (Just $ serializeMasterState ms) Nothing

quietZK :: IO ()
quietZK = ZK.setDebugLevel ZK.ZLogWarn

-- @withConnection opts action@ runs @action@, which takes a Zookeeper handler.
withConnection :: ZKOptions -> (ZK.Zookeeper -> IO a) -> IO a
withConnection opts = ZK.withZookeeper (connectionString opts) zkTimeout
    Nothing Nothing
