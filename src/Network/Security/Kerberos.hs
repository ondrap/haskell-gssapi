{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf               #-}
{-# LANGUAGE OverloadedStrings        #-}

-- | FFI binding to libkrb5 library

module Network.Security.Kerberos (
    krb5Login
  , krb5Resolve
  , KrbException(..)
) where

import           Control.Exception     (Exception, bracket, mask_, throwIO)
import           Control.Monad         (when)
import qualified Data.ByteString.Char8 as BS
import           Foreign
import           Foreign.C.String
import           Foreign.C.Types

-- | Exception raised by this module
data KrbException = KrbException Word BS.ByteString
  deriving (Show)
instance Exception KrbException

data KerberosCTX
data KerberosPrincipal

type Context = Ptr KerberosCTX
type Principal = ForeignPtr KerberosPrincipal

foreign import ccall unsafe "krb5.h krb5_init_context"
  _krb5_init_context :: Ptr (Ptr KerberosCTX) -> IO CInt

foreign import ccall unsafe "krb5.h krb5_free_context"
  _krb5_free_context :: Ptr KerberosCTX -> IO ()

krb5_init_context :: IO Context
krb5_init_context =
  alloca $ \nptr -> do
    code <- _krb5_init_context nptr
    if | code == 0 -> peek nptr
       | otherwise -> throwIO (KrbException (fromIntegral code) "Cannot initialize kerberos context.")

withKrbContext :: (Context -> IO a) -> IO a
withKrbContext = bracket krb5_init_context _krb5_free_context

foreign import ccall unsafe "krb5.h krb5_parse_name"
  _krb5_parse_name :: Ptr KerberosCTX -> CString -> Ptr (Ptr KerberosPrincipal) -> IO CInt

foreign import ccall unsafe "krb5.h &krb5_free_principal"
  _krb5_free_principal :: FinalizerEnvPtr KerberosCTX KerberosPrincipal

krb5_parse_name :: Context -> BS.ByteString -> IO Principal
krb5_parse_name ctx name =
  alloca $ \nprincipal ->
    BS.useAsCString name $ \cname ->
      mask_ $ do
        code <- _krb5_parse_name ctx cname nprincipal
        if | code == 0 -> do
                ptr <- peek nprincipal
                newForeignPtrEnv _krb5_free_principal ctx ptr
           | otherwise -> krb5_throw ctx code

foreign import ccall unsafe "krb5.h krb5_unparse_name"
  _krb5_unparse_name :: Context -> Ptr KerberosPrincipal -> Ptr CString -> IO CInt

krb5_unparse_name :: Context -> Principal -> IO BS.ByteString
krb5_unparse_name ctx principal =
  withForeignPtr principal $ \ptrprincipal ->
      alloca $ \nstring ->
        mask_ $ do
          code <- _krb5_unparse_name ctx ptrprincipal nstring
          if | code == 0 -> do
                  ctxt <- peek nstring
                  result <- BS.packCString ctxt
                  free ctxt
                  return result
             | otherwise -> krb5_throw ctx code

foreign import ccall unsafe "krb5.h krb5_get_error_message"
  _krb5_get_error_message :: Ptr KerberosCTX -> CInt -> IO CString
foreign import ccall unsafe "krb5.h krb5_free_error_message"
  _krb5_free_error_message :: Ptr KerberosCTX -> CString -> IO ()

krb5_throw :: Context -> CInt -> IO a
krb5_throw ctx code = do
    errtext <- bracket
                (_krb5_get_error_message ctx code)
                (_krb5_free_error_message ctx)
                BS.packCString
    throwIO (KrbException (fromIntegral code) errtext)

foreign import ccall safe "hkrb5.h _hkrb5_login"
  _krb5_login :: Ptr KerberosCTX -> Ptr KerberosPrincipal -> CString -> IO CInt

krb5_login :: Context -> Principal -> BS.ByteString -> IO ()
krb5_login ctx principal password = do
  code <- withForeignPtr principal $ \ptrprincipal ->
      BS.useAsCString password $ \cpass ->
          _krb5_login ctx ptrprincipal cpass
  when (code /= 0) $ krb5_throw ctx code

-- | Try to login with principal and password. If logging fails, exception is raised
krb5Login :: BS.ByteString -> BS.ByteString -> IO ()
krb5Login svcname password =
  withKrbContext $ \ctx -> do
      principal <- krb5_parse_name ctx svcname
      krb5_login ctx principal password

-- | Call 'krb5_unparse . krb5_parse' - i.e. add system-wide default realm to the principal name
krb5Resolve :: BS.ByteString -> IO BS.ByteString
krb5Resolve svcname =
  withKrbContext $ \ctx -> do
      principal <- krb5_parse_name ctx svcname
      krb5_unparse_name ctx principal
