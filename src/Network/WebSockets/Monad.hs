-- | Provides a simple, clean monad to write websocket servers in
{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}
module Network.WebSockets.Monad
    ( WebSocketsOptions (..)
    , defaultWebSocketsOptions
    , WebSockets (..)
    , runWebSockets
    , runWebSocketsWith
    , receive
    , sendMessage
    , getMessageSender
    , getSender
    , getOptions
    , getProtocol
    ) where

import Control.Applicative ((<$>))
import Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, replicateM)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.State (StateT, evalStateT)
import Control.Monad.Trans (MonadIO, lift, liftIO)
import System.Random (randomRIO)

import Blaze.ByteString.Builder (Builder)
import Blaze.ByteString.Builder.Enumerator (builderToByteString)
import Data.Attoparsec.Enumerator (iterParser)
import Data.ByteString (ByteString)
import Data.Enumerator ( Iteratee, Stream (..), checkContinue0, isEOF, returnI
                       , run, ($$), (>>==)
                       )
import qualified Data.ByteString as B

import Network.WebSockets.Decode (Decoder)
import Network.WebSockets.Demultiplex (DemultiplexState, emptyDemultiplexState)
import Network.WebSockets.Encode (Encoder)
import Network.WebSockets.Protocol (Protocol (..))
import Network.WebSockets.Protocol.Hybi10 (hybi10)
import qualified Network.WebSockets.Encode as E
import qualified Network.WebSockets.Types as T

-- | Options for the WebSocket program
data WebSocketsOptions = WebSocketsOptions
    { onPong       :: IO ()
    , pingInterval :: Maybe Int
    }

-- | Default options
defaultWebSocketsOptions :: WebSocketsOptions
defaultWebSocketsOptions = WebSocketsOptions
    { onPong       = return ()
    , pingInterval = Just 10
    }

-- | Environment in which the 'WebSockets' monad actually runs
data WebSocketsEnv = WebSocketsEnv
    { options     :: WebSocketsOptions
    , sendBuilder :: Builder -> IO ()
    , protocol    :: Protocol
    }

-- | The monad in which you can write WebSocket-capable applications
newtype WebSockets a = WebSockets
    { unWebSockets :: ReaderT WebSocketsEnv
        (StateT DemultiplexState (Iteratee ByteString IO)) a
    } deriving (Functor, Monad, MonadIO)

-- | Run a 'WebSockets' application on an 'Enumerator'/'Iteratee' pair.
runWebSockets :: WebSockets a
              -> Iteratee ByteString IO ()
              -> Iteratee ByteString IO a
runWebSockets = runWebSocketsWith defaultWebSocketsOptions

-- | Version of 'runWebSockets' which allows you to specify custom options
runWebSocketsWith :: WebSocketsOptions
                  -> WebSockets a
                  -> Iteratee ByteString IO ()
                  -> Iteratee ByteString IO a
runWebSocketsWith opts ws outIter = do
    sendLock <- liftIO $ newMVar () 
    let sender = makeSend sendLock
        env    = WebSocketsEnv opts sender hybi10
        state  = runReaderT (unWebSockets ws') env
        iter   = evalStateT state emptyDemultiplexState


    iter
  where
    makeSend sendLock x = do
        () <- takeMVar sendLock
        _ <- run $ singleton x $$ builderToByteString $$ outIter
        putMVar sendLock ()

    singleton c = checkContinue0 $ \_ f -> f (Chunks [c]) >>== returnI

    -- Spawn a ping thread first
    ws' = spawnPingThread >> ws

-- | Spawn a thread which sends a ping every few seconds, according to the
-- options set
spawnPingThread :: WebSockets ()
spawnPingThread = do
    sender <- getMessageSender
    opts <- getOptions
    case pingInterval opts of
        Nothing -> return ()
        Just i  -> do
            _ <- liftIO $ forkIO $ forever $ do
                sender $ T.ping ("Hi" :: ByteString)
                threadDelay (i * 1000 * 1000)  -- seconds
            return ()

-- | Receive some data from the socket, using a user-supplied parser.
receive :: Decoder a -> WebSockets (Maybe a)
receive = WebSockets . lift . lift . receiveIteratee

-- | Low-level interface. 'receive' is just this lifted to WebSockets
receiveIteratee :: Decoder a -> Iteratee ByteString IO (Maybe a)
receiveIteratee parser = do
    eof <- isEOF
    if eof then return Nothing else fmap Just (iterParser parser)

-- | Low-level sending with an arbitrary 'T.Message'
sendMessage :: T.Message -> WebSockets ()
sendMessage msg = getMessageSender >>= (liftIO . ($ msg))

-- | In case the user of the library wants to do asynchronous sending to the
-- socket, he can extract a 'Sender' and pass this value around, for example,
-- to other threads.
getMessageSender :: WebSockets (T.Message -> IO ())
getMessageSender = do
    proto <- getProtocol
    let encodeMsg = E.message (encodeFrame proto)
    getSender encodeMsg

getSender :: Encoder a -> WebSockets (a -> IO ())
getSender encoder = WebSockets $ do
    send' <- sendBuilder <$> ask
    return $ \x -> do
        bytes <- replicateM 4 (liftIO randomByte)
        send' (encoder (Just (B.pack bytes)) x)
  where
    randomByte = fromIntegral <$> randomRIO (0x00 :: Int, 0xff)

-- | Get the current configuration
getOptions :: WebSockets WebSocketsOptions
getOptions = WebSockets $ ask >>= return . options

-- | Get the underlying protocol
getProtocol :: WebSockets Protocol
getProtocol = WebSockets $ ask >>= return . protocol
