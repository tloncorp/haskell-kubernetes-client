{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}
module Kubernetes.Client.Auth.TokenFile where

import           Control.Concurrent.STM
import           Data.Function                  ( (&) )
import           Data.Monoid                    ( (<>) )
import           Data.Text                      ( Text )
import           Data.Time.Clock
import           Kubernetes.Client.Auth.Internal.Types
import           Kubernetes.OpenAPI.Core
import           Kubernetes.Client.KubeConfig
                                         hiding ( token )
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T
import qualified Lens.Micro                    as L
import qualified Data.Proxy                    as P
import qualified Data.Data                     as P (typeRep)

data TokenFileAuth = TokenFileAuth { token :: TVar(Maybe Text)
                                   , expiry :: TVar(Maybe UTCTime)
                                   , file :: FilePath
                                   , period :: NominalDiffTime
                                   }

instance AuthMethod TokenFileAuth where
  applyAuthMethod _ tokenFile req = do
    t <- getToken tokenFile
    pure
      $           req
      `setHeader` toHeader ("authorization", "Bearer " <> t)
      &           L.set rAuthTypesL []

-- |Detects if token-file is specified in AuthConfig.
tokenFileAuth :: DetectAuth
tokenFileAuth auth (tlsParams, cfg) = do
  file <- tokenFile auth
  return $ do
    c <- setTokenFileAuth file cfg
    return (tlsParams, c)

-- |Configures the 'KubernetesClientConfig' to use TokenFile authentication.
setTokenFileAuth
  :: FilePath -> KubernetesClientConfig -> IO KubernetesClientConfig
setTokenFileAuth f kcfg = atomically $ do
  t <- newTVar (Nothing :: Maybe Text)
  e <- newTVar (Nothing :: Maybe UTCTime)
  return kcfg
    { configAuthMethods =
      [ AnyAuthMethod
          typeRep
          (TokenFileAuth { token = t, expiry = e, file = f, period = 60 })
      ]
    }
  where
    typeRep = P.typeRep (P.Proxy :: P.Proxy TokenFileAuth)

getToken :: TokenFileAuth -> IO Text
getToken auth = getCurrentToken auth >>= maybe (reloadToken auth) return

getCurrentToken :: TokenFileAuth -> IO (Maybe Text)
getCurrentToken TokenFileAuth { token, expiry } = do
  now         <- getCurrentTime
  maybeExpiry <- readTVarIO expiry
  maybeToken  <- readTVarIO token
  return $ do
    e <- maybeExpiry
    if e > now then maybeToken else Nothing

reloadToken :: TokenFileAuth -> IO Text
reloadToken TokenFileAuth { token, expiry, file, period } = do
  content <- T.readFile file
  let t = T.strip content
  now <- getCurrentTime
  atomically $ do
    writeTVar token  (Just t)
    writeTVar expiry (Just (addUTCTime period now))
  return t
