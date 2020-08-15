{-# LANGUAGE Strict #-}

module Network.UdpServer where

import           Data.ByteString               (ByteString)
import           Data.Default.Class

import           Data.Map.Strict               (delete, empty, insert, (!?))
import           Network.Socket                (Family (..), PortNumber,
                                                SockAddr (..), SocketType (..),
                                                bind, close, defaultProtocol,
                                                socket, socketPort)
import           Network.Socket.ByteString     (recvFrom, sendAllTo)
import           UnliftIO

import           Control.Concurrent.Supervisor hiding (send)
import qualified Control.Concurrent.Supervisor as SV (send)


type MessageHandler = IO (Maybe ByteString) -> (ByteString -> IO ()) -> IO ()

data WorkerManagerCommand
    = Msg SockAddr ByteString
    | Die SockAddr

data UdpServerConfig = UdpServerConfig
    { udpServerConfigPort           :: PortNumber
    , udpServerConfigTimeout        :: Int
    , udpServerConfigBeforeMainLoop :: PortNumber -> IO ()
    }

instance Default UdpServerConfig where
    def = UdpServerConfig 0 5000000 (\_ -> pure ())

newUdpServer :: UdpServerConfig -> MessageHandler -> IO ()
newUdpServer (UdpServerConfig port tout readyToSend) handler = do
    bracket newSocket close $ \sk -> do
        socketPort sk >>= readyToSend
        makeUdpServer sk
  where
    makeUdpServer sk = do
        Actor workerSVQ workerSV <- newActor newSimpleOneForOneSupervisor
        Actor managerQ manager <- newActor $ newWorkerManager handler tout (flip $ sendAllTo sk) workerSVQ
        let workerSVProc    = newChildSpec Permanent workerSV
            managerProc     = newChildSpec Permanent manager
            receiverProc    = newChildSpec Permanent $ receiver sk managerQ
        actorAction =<< newActor (newSupervisor OneForAll def [workerSVProc, managerProc, receiverProc])

    receiver sk managerQ = go
      where
        go = do
            (bs, peer) <- recvFrom sk 0x10000
            SV.send managerQ (Msg peer bs)
            go

    newSocket = do
        sk <- socket AF_INET Datagram defaultProtocol
        bind sk (SockAddrInet port 0)
        pure sk

newWorkerManager
    :: MessageHandler
    -> Int -- ^ Receive timeout in microseconds
    -> (SockAddr -> ByteString -> IO())  -- ^ sending function
    -> SupervisorQueue
    -> ActorHandler WorkerManagerCommand ()
newWorkerManager msgHandler tout sender svQ inbox = go empty
  where
    go workers = do
        msg <- receive inbox
        case msg of
            Msg peer bs -> do
                case workers !? peer of
                    Just workerQ -> SV.send workerQ bs *> go workers

                    Nothing     -> do
                        Actor newWorkerQ newWorker <- newActor $ \workerInbox ->
                            msgHandler (receiver workerInbox) (sender peer) `catchAny` \_ -> pure ()
                        let newWorkerProc = newMonitoredChildSpec Temporary $ watch (monitor peer) newWorker
                        _ <- newChild def svQ newWorkerProc
                        SV.send newWorkerQ bs
                        go $ insert peer newWorkerQ workers

            Die peer    -> go $ delete peer workers

    receiver = timeout tout . receive

    monitor peer _ _ = sendToMe inbox (Die peer)
