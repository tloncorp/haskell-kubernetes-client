{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Kubernetes.Client.Auth.Basic where

import           Data.ByteString.Base64         ( encode )
import           Data.Function                  ( (&) )
import           Data.Monoid                    ( (<>) )
import           Data.Text                      ( Text )
import           Kubernetes.Client.Auth.Internal.Types
import           Kubernetes.OpenAPI.Core
import           Kubernetes.Client.KubeConfig

import qualified Data.Text.Encoding            as T
import qualified Lens.Micro                    as L
import qualified Data.Proxy                    as P
import qualified Data.Data                     as P (typeRep)

data BasicAuth = BasicAuth { basicAuthUsername :: Text
                           , basicAuthPassword :: Text
                           }

instance AuthMethod BasicAuth where
  applyAuthMethod _ BasicAuth{..} req =
    pure
      $           req
      `setHeader` toHeader ("authorization", "Basic " <> encodeBasicAuth)
      &           L.set rAuthTypesL []
    where
      encodeBasicAuth = T.decodeUtf8 $ encode $ T.encodeUtf8 $ basicAuthUsername <> ":" <> basicAuthPassword

-- |Detects if username and password is specified in AuthConfig, if it is configures 'KubernetesClientConfig' with 'BasicAuth'
basicAuth :: DetectAuth
basicAuth auth (tlsParams, cfg) = do
  u <- username auth
  p <- password auth
  return $ return (tlsParams, setBasicAuth u p cfg)

-- |Configures the 'KubernetesClientConfig' to use basic authentication.
setBasicAuth
  :: Text                 -- ^Username
  -> Text                 -- ^Password
  -> KubernetesClientConfig
  -> KubernetesClientConfig
setBasicAuth u p kcfg = kcfg
  { configAuthMethods = [AnyAuthMethod typeRep (BasicAuth u p)]
  }
  where
    typeRep = P.typeRep (P.Proxy :: P.Proxy BasicAuth)
