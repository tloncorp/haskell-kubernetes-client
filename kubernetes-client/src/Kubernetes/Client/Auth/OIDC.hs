{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Kubernetes.Client.Auth.OIDC
  (oidcAuth, OIDCCache, cachedOIDCAuth)
where

import Control.Applicative
import Control.Concurrent.STM
import Control.Exception.Safe                (Exception, throwM)
import Data.Either.Combinators
import Data.Function                         ((&))
import Data.Map                              (Map)
import Data.Maybe
import Data.Monoid                           ((<>))
import Data.Text
import Data.Time.Clock.POSIX                 (getPOSIXTime)
import Jose.Jwt
import Kubernetes.Client.Auth.Internal.Types
import Kubernetes.Client.Internal.TLSUtils
import Kubernetes.Client.KubeConfig
import Kubernetes.OpenAPI.Core
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.OAuth.OAuth2                  as OAuth
import Network.TLS                           as TLS
import URI.ByteString
import Web.OIDC.Client.Discovery             as OIDC

import qualified Data.ByteString                   as BS
import qualified Data.ByteString.Base64            as B64
import qualified Data.Map                          as Map
import qualified Data.Text                         as Text
import qualified Data.Text.Encoding                as Text
import qualified Lens.Micro                        as L
import qualified Network.OAuth.OAuth2.TokenRequest as OAuth2TokenRequest

data OIDCAuth = OIDCAuth { issuerURL        :: Text
                         , clientID         :: Text
                         , clientSecret     :: Text
                         , tlsParams        :: TLS.ClientParams
                         , idTokenTVar      :: TVar(Maybe Text)
                         , refreshTokenTVar :: TVar(Maybe Text)
                         }

-- | Cache OIDCAuth based on issuerURL and clientID.
type OIDCCache = TVar (Map (Text, Text) OIDCAuth)

instance AuthMethod OIDCAuth where
  applyAuthMethod _ oidc req = do
    token <- getToken oidc
    pure
      $ setHeader req [("Authorization", "Bearer " <> (Text.encodeUtf8 token))]
      & L.set rAuthTypesL []

data OIDCGetTokenException = OIDCOAuthException (OAuth2Error OAuth2TokenRequest.Errors)
                           | OIDCURIException URIParseError
                           | OIDCGetTokenException String
  deriving Show
instance Exception OIDCGetTokenException

data OIDCAuthParsingException = OIDCAuthCAParsingFailed ParseCertException
                              | OIDCAuthMissingInformation String
  deriving Show
instance Exception OIDCAuthParsingException

-- TODO: Consider a token expired few seconds before actual expiry to account for time skew
getToken :: OIDCAuth -> IO Text
getToken auth@(OIDCAuth{..}) = do
  now <- getPOSIXTime
  maybeIdToken <- readTVarIO idTokenTVar
  case maybeIdToken of
    Nothing -> fetchToken auth
    Just idToken -> do
      let maybeExpiry = do
            (_, claims) <- decodeClaims (Text.encodeUtf8 idToken)
                           & rightToMaybe
            jwtExp claims
      case maybeExpiry of
        Nothing -> fetchToken auth
        Just (IntDate expiryDate) ->
          if now < expiryDate
          then pure idToken
          else fetchToken auth

fetchToken :: OIDCAuth -> IO Text
fetchToken auth@(OIDCAuth{..}) = do
  mgr <- newManager tlsManagerSettings
  maybeToken <- readTVarIO refreshTokenTVar
  case maybeToken of
    Nothing -> throwM $ OIDCGetTokenException "cannot refresh id-token without a refresh token"
    Just token -> do
      tokenEndpoint <- fetchTokenEndpoint mgr auth
      tokenURI <- parseURI strictURIParserOptions (Text.encodeUtf8 tokenEndpoint)
                  & either (throwM . OIDCURIException) pure
      let oauth = OAuth2{ oauth2ClientId = clientID
                        , oauth2ClientSecret = Just clientSecret
                        , oauth2AccessTokenEndpoint = tokenURI
                        , oauth2OAuthorizeEndpoint = tokenURI
                        , oauth2Callback = Nothing
                        }
      oauthToken <- refreshAccessToken mgr oauth (RefreshToken token)
                    >>= either (throwM . OIDCOAuthException) pure
      case OAuth.idToken oauthToken of
        Nothing -> throwM $ OIDCGetTokenException "token response did not contain an id_token, either the scope \"openid\" wasn't requested upon login, or the provider doesn't support id_tokens as part of the refresh response."
        Just (IdToken t) -> do
          _ <- atomically $ writeTVar idTokenTVar (Just t)
          return t

fetchTokenEndpoint :: Manager -> OIDCAuth -> IO Text
fetchTokenEndpoint mgr OIDCAuth{..} = do
  discover issuerURL mgr
    & (fmap configuration)
    & (fmap tokenEndpoint)

{-
   Detects if auth-provier name is oidc, if it is configures the 'KubernetesClientConfig' with OIDCAuth 'AuthMethod'.
   Does not use cache, consider using 'cachedOIDCAuth'.
-}
oidcAuth :: DetectAuth
oidcAuth AuthInfo{authProvider = Just(AuthProviderConfig "oidc" (Just cfg))} (tls, kubecfg)
  = Just
    $ parseOIDCAuthInfo cfg
    >>= either throwM (\oidc -> pure (tls, addAuthMethod kubecfg oidc))
oidcAuth _ _ = Nothing

-- TODO: Consider doing this whole function atomically, as two threads may miss the cache simultaneously
{-
   Detects if auth-provier name is oidc, if it is configures the 'KubernetesClientConfig' with OIDCAuth 'AuthMethod'.
   First looks for Auth information to be present in 'OIDCCache'. If found returns that, otherwise creates new Auth information and persists it in cache.
-}
cachedOIDCAuth :: OIDCCache -> DetectAuth
cachedOIDCAuth cache AuthInfo{authProvider = Just(AuthProviderConfig "oidc" (Just cfg))} (tls, kubecfg) = Just $ do
  latestCache <- readTVarIO cache
  issuerURL <- lookupOrThrow "idp-issuer-url"
  clientID <- lookupOrThrow "client-id"
  case Map.lookup (issuerURL, clientID) latestCache of
    Just cacheHit -> return $ newTLSAndAuth cacheHit
    Nothing -> do
      parsedAuth <- parseOIDCAuthInfo cfg
                    >>= either throwM pure
      let newCache = Map.insert (issuerURL, clientID) parsedAuth latestCache
      _ <- atomically $ swapTVar cache newCache
      return $ newTLSAndAuth parsedAuth
  where lookupOrThrow k = Map.lookup k cfg
                         & maybe (throwM $ OIDCAuthMissingInformation $ Text.unpack k) pure
        newTLSAndAuth auth = (tls, addAuthMethod kubecfg auth)
cachedOIDCAuth _ _ _ = Nothing

parseOIDCAuthInfo :: Map Text Text -> IO (Either OIDCAuthParsingException OIDCAuth)
parseOIDCAuthInfo authInfo = do
  eitherTLSParams <- parseCA authInfo
  idTokenTVar <- atomically $ newTVar $ Map.lookup "id-token" authInfo
  refreshTokenTVar <- atomically $ newTVar $ Map.lookup "refresh-token" authInfo
  return $ do
    tlsParams <- mapLeft OIDCAuthCAParsingFailed eitherTLSParams
    issuerURL <- lookupEither "idp-issuer-url"
    clientID <- lookupEither "client-id"
    clientSecret <- lookupEither "client-secret"
    return OIDCAuth{..}
    where lookupEither k = Map.lookup k authInfo
                           & maybeToRight (OIDCAuthMissingInformation $ Text.unpack k)

parseCA :: Map Text Text -> IO (Either ParseCertException TLS.ClientParams)
parseCA authInfo = do
  tlsParams <- defaultTLSClientParams
  let maybeNewParams = (parseCAFile tlsParams authInfo
                        <|> parseCAData tlsParams authInfo)
  fromMaybe (pure $ Right tlsParams) maybeNewParams

parseCAFile :: TLS.ClientParams -> Map Text Text -> Maybe (IO (Either ParseCertException TLS.ClientParams))
parseCAFile tlsParams authInfo = do
  caFile <- Text.unpack <$> Map.lookup "idp-certificate-authority" authInfo
  Just $ do
    caText <- BS.readFile caFile
    return $ updateClientParams tlsParams caText

parseCAData :: TLS.ClientParams -> Map Text Text -> Maybe (IO (Either ParseCertException TLS.ClientParams))
parseCAData tlsParams authInfo = do
  caBase64 <- Map.lookup "idp-certificate-authority-data" authInfo
  Just $ pure $ do
    caText <- B64.decode (Text.encodeUtf8 caBase64)
              & mapLeft Base64ParsingFailed
    updateClientParams tlsParams caText
