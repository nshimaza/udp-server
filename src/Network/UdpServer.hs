{-# LANGUAGE Strict #-}

module Network.UdpServer where

import           Data.ByteString               (ByteString)
import           Data.Default.Class

import           Data.Map.Strict               (Map, delete, empty, insert,
                                                (!?))
import           Network.Socket                (Family (..), PortNumber,
                                                SockAddr (..), Socket,
                                                SocketOption (..),
                                                SocketType (..), bind, close,
                                                defaultProtocol,
                                                setSocketOption, socket)
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
    , udpServerConfigBeforeMainLoop :: IO ()
    }

instance Default UdpServerConfig where
    def = UdpServerConfig 9000 5000000 (pure ())

newUdpServer :: UdpServerConfig -> MessageHandler -> IO ()
newUdpServer conf@(UdpServerConfig port tout readyToSend) handler = do
    bracket newSocket close $ \sk -> do
        readyToSend
        makeUdpServer sk
  where
    makeUdpServer sk = do
        (workerSVQ, workerSV) <- newActor newSimpleOneForOneSupervisor
        (managerQ, manager) <- newActor $ newWorkerManager handler tout (\peer bs -> sendAllTo sk bs peer) workerSVQ
        let workerSVProc    = newProcessSpec Permanent $ noWatch workerSV
            managerProc     = newProcessSpec Permanent $ noWatch manager
            receiverProc    = newProcessSpec Permanent $ noWatch $ receiver sk managerQ
        snd =<< newActor (newSupervisor OneForAll def [workerSVProc, managerProc, receiverProc])

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
                        (newWorkerQ, newWorker) <- newActor $ \inbox ->
                            msgHandler (receiver inbox) (sender peer) `catchAny` \_ -> pure ()
                        let newWorkerProc = newProcessSpec Temporary $ watch (monitor peer) newWorker
                        newChild def svQ newWorkerProc
                        SV.send newWorkerQ bs
                        go $ insert peer newWorkerQ workers

            Die peer    -> go $ delete peer workers

    receiver = timeout tout . receive
    -- receiver inbox = do
    --     r <- timeout tout $ receive inbox
    --     case r of
    --         Nothing -> throwString "Receive timeout"
    --         Just bs -> pure bs

    monitor peer _ _ = SV.send (Actor inbox) (Die peer)
