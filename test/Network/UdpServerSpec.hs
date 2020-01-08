{-# LANGUAGE OverloadedStrings #-}

module Network.UdpServerSpec where

import           Control.Monad                        ((>=>))
import qualified Data.ByteString                      as S (ByteString)
import qualified Data.ByteString.Char8                as C (pack, putStrLn,
                                                            unpack)
import           Data.Default.Class
import           Data.Foldable                        (for_)
import qualified Data.Set                             as Set (fromList, size)
import           Data.Traversable                     (for)

import           Network.Socket                       (Family (..), PortNumber,
                                                       SockAddr (..), Socket,
                                                       SocketType (..), close,
                                                       connect, defaultProtocol,
                                                       socket,
                                                       tupleToHostAddress)
import           Network.Socket.ByteString            (recv, sendAll)
import           UnliftIO
import           UnliftIO.Concurrent                  (myThreadId, threadDelay)

import           Test.Hspec
import           Test.Hspec.QuickCheck
import           Test.QuickCheck

import           Test.QuickCheck.Instances.ByteString

import           Network.UdpServer

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}

listenPort = udpServerConfigPort def

helloWorldMessage = "hello, world"

withUdpServer :: UdpServerConfig -> MessageHandler -> IO () -> IO ()
withUdpServer userConf handler inner = do
    readyMarker <- newEmptyMVar
    let conf = userConf { udpServerConfigBeforeMainLoop = putMVar readyMarker () }
    withAsync (newUdpServer conf handler) $ \_ -> takeMVar readyMarker *> inner

withUdpConnection :: (Socket -> IO a) -> IO a
withUdpConnection = bracket connToUdpServer close
  where
    connToUdpServer = do
        sk <- socket AF_INET Datagram defaultProtocol
        connect sk . SockAddrInet listenPort $ tupleToHostAddress (127,0,0,1)
        pure sk

withUdpConnection_ :: (Socket -> IO a) -> IO ()
withUdpConnection_ = withUdpConnection >=> \_ -> pure ()

echoServer :: MessageHandler
echoServer recv send = go
  where
    go = recv >>= maybe (pure ()) (\msg -> send msg *> go)

withEchoServer :: IO () -> IO ()
withEchoServer = withUdpServer def echoServer

threadEchoServer :: MessageHandler
threadEchoServer recv send = go
  where
    go = do
        maybeMsg <- recv
        case maybeMsg of
            Nothing     -> pure ()
            Just msg    -> do
                tid <- myThreadId
                send $ C.pack (show tid) <> " " <> msg
                go

extractThreadEcho :: S.ByteString -> (String, String, String)
extractThreadEcho bs = (ws !! 0, ws !! 1, ws !! 2)
  where
    ws = words $ C.unpack bs

withThreadEchoServer :: IO () -> IO ()
withThreadEchoServer = withUdpServer def threadEchoServer

withShortTimeoutServer :: IO () -> IO ()
withShortTimeoutServer = withUdpServer (def { udpServerConfigTimeout = 500000 }) threadEchoServer

spec :: Spec
spec = do
    describe "UdpServer with no response" $ do
        it "reacts on incoming UDP message" $ do
            marker <- newEmptyMVar
            let server recv _ = recv >>= putMVar marker

            withUdpServer def server $ withUdpConnection_ $ \sk -> do
                let msg = "hello, world"
                sendAll sk msg
                maybeBs <- readMVar marker
                maybeBs `shouldBe` Just msg

    around_ withEchoServer $ around withUdpConnection_ $ do
        describe "UDP echo server" $ do
            it "returns received UDP message" $ \sk -> do
                let msg = "hello, world2"
                sendAll sk msg
                bs <- recv sk 0x10000
                bs `shouldBe` msg

            it "returns received UDP message" $ \sk -> property $ \xs -> do
                let msgs = map (C.pack . show) (0:xs ::[Int])
                for_ msgs $ \i -> do
                    sendAll sk i
                    bs <- recv sk 0x10000
                    bs `shouldBe` i

            it "handles concurrent peer" $ \sk1 -> withUdpConnection_ $ \sk2 -> do
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

            it "handles many sequential peer" $ \_ -> do
                for_ [1..100] $ \n -> withUdpConnection_ $ \sk -> do
                    let msgs = map (C.pack . show) [n .. n+99]
                    for_ msgs $ \i -> do
                        sendAll sk i
                        bs <- recv sk 0x10000
                        bs `shouldBe` i

            it "handles many concurrent peer" $ \_ -> do
                workers <- for [1..100] $ \n -> async $ withUdpConnection_ $ \sk -> do
                    let msgs = map (C.pack . show) [n .. n+200]
                    for_ msgs $ \i -> do
                        sendAll sk i
                        bs <- recv sk 0x10000
                        bs `shouldBe` i
                for_ workers wait

    around_ withThreadEchoServer $ around withUdpConnection_ $ do
        describe "UDP thread echo server" $ do
            it "returns handler ThreadId and received UDP message" $ \sk -> do
                let msg = "hello"
                sendAll sk $ C.pack msg
                bs <- recv sk 0x10000
                let (_, _, echo) = extractThreadEcho bs
                echo `shouldBe` msg

            it "uses same handling thread for same peer" $ \sk -> property $ \xs -> do
                let msgs = map show (0:xs ::[Int])
                tids <- for msgs $ \i -> do
                    sendAll sk $ C.pack i
                    bs <- recv sk 0x10000
                    let (_, tid, echo) = extractThreadEcho bs
                    echo `shouldBe` i
                    pure tid
                (snd $ foldr (\e (h, flag) -> (h, flag == True && e == h)) (head tids, True) tids) `shouldBe` True

            it "uses different thread for different peer" $ \sk1 -> withUdpConnection_ $ \sk2 -> do
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

            it "handles many sequential peer" $ \_ -> do
                for_ [1..100] $ \n -> withUdpConnection_ $ \sk -> do
                    let msgs = map show [n .. n+99]
                    tids <- for msgs $ \i -> do
                        sendAll sk $ C.pack i
                        bs <- recv sk 0x10000
                        let (_, tid, echo) = extractThreadEcho bs
                        echo `shouldBe` i
                        pure tid
                    (snd $ foldr (\e (h, flag) -> (h, flag == True && e == h)) (head tids, True) tids) `shouldBe` True

            it "handles many concurrent peer" $ \_ -> do
                workers <- for [1..100] $ \n -> async $ withUdpConnection $ \sk -> do
                    let msgs = map show [n .. n+200]
                    tids <- for msgs $ \i -> do
                        sendAll sk $ C.pack i
                        bs <- recv sk 0x10000
                        let (_, tid, echo) = extractThreadEcho bs
                        echo `shouldBe` i
                        pure tid
                    (snd $ foldr (\e (h, flag) -> (h, flag == True && e == h)) (head tids, True) tids) `shouldBe` True
                    pure $ head tids
                worker_tids <- for workers wait
                (Set.size $ Set.fromList worker_tids) `shouldBe` length workers

    around_ withShortTimeoutServer $ around withUdpConnection_ $ do
        describe "UDP server with worker thread timeout" $ do
            it "stops worker thread when receive timeout happen" $ \sk -> do
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
