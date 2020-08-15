{-# LANGUAGE OverloadedStrings #-}

module Network.UdpServerSpec where

import           Control.Monad             ((>=>))
import qualified Data.ByteString           as S (ByteString)
import qualified Data.ByteString.Char8     as C (pack, unpack)
import           Data.Default.Class
import           Data.Foldable             (for_)
import qualified Data.Set                  as Set (fromList, size)
import           Data.Traversable          (for)

import           Network.Socket            (Family (..), PortNumber,
                                            SockAddr (..), Socket,
                                            SocketType (..), close, connect,
                                            defaultProtocol, socket,
                                            tupleToHostAddress)
import           Network.Socket.ByteString (recv, sendAll)
import           UnliftIO
import           UnliftIO.Concurrent       (myThreadId, threadDelay)

import           Test.Hspec
import           Test.QuickCheck

import           Network.UdpServer

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}

helloWorldMessage = "hello, world"

withUdpServer :: UdpServerConfig -> MessageHandler -> (PortNumber -> IO ()) -> IO ()
withUdpServer userConf handler inner = do
    readyMarker <- newEmptyMVar
    let conf = userConf { udpServerConfigBeforeMainLoop = putMVar readyMarker }
    withAsync (newUdpServer conf handler) $ \_ -> takeMVar readyMarker >>= inner

withUdpConnection :: PortNumber -> (Socket -> IO a) -> IO a
withUdpConnection port = bracket connToUdpServer close
  where
    connToUdpServer = do
        sk <- socket AF_INET Datagram defaultProtocol
        connect sk . SockAddrInet port $ tupleToHostAddress (127,0,0,1)
        pure sk

withUdpConnection_ :: PortNumber -> (Socket -> IO a) -> IO ()
withUdpConnection_ port = withUdpConnection port >=> \_ -> pure ()

echoServer :: MessageHandler
echoServer receive send = go
  where
    go = receive >>= maybe (pure ()) (\msg -> send msg *> go)

withEchoServer :: (PortNumber -> IO ()) -> IO ()
withEchoServer = withUdpServer def echoServer

threadEchoServer :: MessageHandler
threadEchoServer receive send = go
  where
    go = do
        maybeMsg <- receive
        case maybeMsg of
            Nothing     -> pure ()
            Just msg    -> do
                tid <- myThreadId
                send $ C.pack (show tid) <> " " <> msg
                go

extractThreadEcho :: S.ByteString -> (String, String, String)
extractThreadEcho bs = (w0, w1, w2)
  where
    w0:w1:w2:_ = words $ C.unpack bs

withThreadEchoServer :: (PortNumber -> IO ()) -> IO ()
withThreadEchoServer = withUdpServer def threadEchoServer

withShortTimeoutServer :: (PortNumber -> IO ()) -> IO ()
withShortTimeoutServer = withUdpServer (def { udpServerConfigTimeout = 500000 }) threadEchoServer

allSame :: Eq a => [a] -> Bool
allSame []     = True
allSame (x:xs) = all (x ==) xs

spec :: Spec
spec = do
    describe "UdpServer with no response" $ do
        it "reacts on incoming UDP message" $ do
            marker <- newEmptyMVar
            let server receive _ = receive >>= putMVar marker

            withUdpServer def server $ \port -> withUdpConnection_ port $ \sk -> do
                let msg = "hello, world"
                sendAll sk msg
                maybeBs <- readMVar marker
                maybeBs `shouldBe` Just msg

    around withEchoServer $ do
        describe "UDP echo server" $ do
            it "returns received UDP message" $ \port -> withUdpConnection_ port $ \sk -> do
                let msg = "hello, world2"
                sendAll sk msg
                bs <- recv sk 0x10000
                bs `shouldBe` msg

            it "returns received UDP message" $ \port -> property $ \xs -> withUdpConnection_ port $ \sk -> do
                let msgs = map (C.pack . show) (0:xs ::[Int])
                for_ msgs $ \i -> do
                    sendAll sk i
                    bs <- recv sk 0x10000
                    bs `shouldBe` i

            it "handles concurrent peer" $ \port ->
                withUdpConnection_ port $ \sk1 -> withUdpConnection_ port $ \sk2 -> do
                    let msgs1 = map (C.pack . show) [1..1000]
                        msgs2 = reverse msgs1
                    a1 <- async $ for_ msgs1 $ \i -> do
                        sendAll sk1 i
                        bs1 <- recv sk1 0x10000
                        bs1 `shouldBe` i
                    a2 <- async $ for_ msgs2 $ \i -> do
                        sendAll sk2 i
                        bs2 <- recv sk2 0x10000
                        bs2 `shouldBe` i
                    wait a1
                    wait a2

            it "handles many sequential peer" $ \port -> do
                for_ [1..100] $ \n -> withUdpConnection_ port $ \sk -> do
                    let msgs = map (C.pack . show) [n .. n+99]
                    for_ msgs $ \i -> do
                        sendAll sk i
                        bs <- recv sk 0x10000
                        bs `shouldBe` i

            it "handles many concurrent peer" $ \port -> do
                workers <- for [1..100] $ \n -> async $ withUdpConnection_ port $ \sk -> do
                    let msgs = map (C.pack . show) [n .. n+200]
                    for_ msgs $ \i -> do
                        sendAll sk i
                        bs <- recv sk 0x10000
                        bs `shouldBe` i
                for_ workers wait

    around withThreadEchoServer $ do
        describe "UDP thread echo server" $ do
            it "returns handler ThreadId and received UDP message" $ \port -> withUdpConnection_ port $ \sk -> do
                let msg = "hello"
                sendAll sk $ C.pack msg
                bs <- recv sk 0x10000
                let (_, _, echo) = extractThreadEcho bs
                echo `shouldBe` msg

            it "uses same handling thread for same peer" $ \port ->
                property $ \xs -> withUdpConnection_ port $ \sk -> do
                    let msgs = map show (0:xs ::[Int])
                    tids <- for msgs $ \i -> do
                        sendAll sk $ C.pack i
                        bs <- recv sk 0x10000
                        let (_, tid, echo) = extractThreadEcho bs
                        echo `shouldBe` i
                        pure tid
                    tids `shouldSatisfy` allSame

            it "uses different thread for different peer" $ \port ->
                withUdpConnection_ port $ \sk1 -> withUdpConnection_ port $ \sk2 -> do
                    let msg1 = "hello1"
                    sendAll sk1 $ C.pack msg1
                    bs1 <- recv sk1 0x10000
                    let (_, tid1, echo1) = extractThreadEcho bs1
                    echo1 `shouldBe` msg1

                    let msg2 = "hello2"
                    sendAll sk2 $ C.pack msg2
                    bs2 <- recv sk2 0x10000
                    let (_, tid2, echo2) = extractThreadEcho bs2
                    echo2 `shouldBe` msg2

                    echo1 `shouldSatisfy` (/= echo2)
                    tid1 `shouldSatisfy` (/= tid2)

            it "handles many sequential peer" $ \port -> do
                for_ [1..100] $ \n -> withUdpConnection_ port $ \sk -> do
                    let msgs = map show [n .. n+99]
                    tids <- for msgs $ \i -> do
                        sendAll sk $ C.pack i
                        bs <- recv sk 0x10000
                        let (_, tid, echo) = extractThreadEcho bs
                        echo `shouldBe` i
                        pure tid
                    tids `shouldSatisfy` allSame

            it "handles many concurrent peer" $ \port -> do
                workers <- for [1..100] $ \n -> async $ withUdpConnection port $ \sk -> do
                    let msgs = map show [n .. n+200]
                    tids <- for msgs $ \i -> do
                        sendAll sk $ C.pack i
                        bs <- recv sk 0x10000
                        let (_, tid, echo) = extractThreadEcho bs
                        echo `shouldBe` i
                        pure tid
                    tids `shouldSatisfy` allSame
                    pure $ head tids
                worker_tids <- for workers wait
                Set.size (Set.fromList worker_tids) `shouldBe` length workers

    around (\cont -> withShortTimeoutServer $ \port -> withUdpConnection_ port cont) $ do
        describe "UDP server with worker thread timeout" $ do
            it "notifies receive timeout to worker thread" $ \sk -> do
                let msg1 = "hello1"
                sendAll sk $ C.pack msg1
                bs1 <- recv sk 0x10000
                let (_, tid1, echo1) = extractThreadEcho bs1
                echo1 `shouldBe` msg1

                let msg2 = "hello2"
                sendAll sk $ C.pack msg2
                bs2 <- recv sk 0x10000
                let (_, tid2, echo2) = extractThreadEcho bs2
                echo2 `shouldBe` msg2
                tid2 `shouldBe` tid1

                let msg3 = "hello3"
                threadDelay 1000000
                sendAll sk $ C.pack msg3
                bs3 <- recv sk 0x10000
                let (_, tid3, echo3) = extractThreadEcho bs3
                echo3 `shouldBe` msg3
                tid3 `shouldSatisfy` (/= tid2)
