{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BinaryLiterals #-}

module Network.QUIC.TLS (
  -- * Payload encryption
    defaultCipher
  , clientInitialSecret
  , serverInitialSecret
  , aeadKey
  , initialVector
  , headerProtectionKey
  , encryptPayload
  , decryptPayload
  -- * Header Protection
  , headerProtection
  , unprotectHeader
  -- * Types
  , Salt
  , PlainText
  , CipherText
  , Key
  , IV
  , CID
  , Secret
  , AddDat
  , Sample
  , Mask
  , Nonce
  , Header
  ) where

import Network.TLS.Extra.Cipher
import Crypto.Cipher.AES
import Crypto.Cipher.Types hiding (Cipher, IV)
import Crypto.Error (throwCryptoError)
import Data.Bits
import Data.ByteArray (convert)
import qualified Data.ByteString as B
import Network.ByteOrder
import Network.TLS (Cipher)
import qualified Network.TLS as TLS

import Network.QUIC.Transport.Types

----------------------------------------------------------------

defaultCipher :: Cipher
defaultCipher = cipher_TLS13_AES128GCM_SHA256

----------------------------------------------------------------

type Salt       = ByteString
type PlainText  = ByteString
type CipherText = ByteString
type Key        = ByteString
type IV         = ByteString
type CID        = ByteString -- fixme
type Secret     = ByteString
type AddDat     = ByteString
type Sample     = ByteString
type Mask       = ByteString
type Nonce      = ByteString
type Header     = ByteString

----------------------------------------------------------------

-- "ef4fb0abb47470c41befcf8031334fae485e09a0"
initialSalt :: Salt
initialSalt = "\xef\x4f\xb0\xab\xb4\x74\x70\xc4\x1b\xef\xcf\x80\x31\x33\x4f\xae\x48\x5e\x09\xa0"

clientInitialSecret :: Cipher -> CID -> Secret
clientInitialSecret = initialSecret "client in"

serverInitialSecret :: Cipher -> CID -> Secret
serverInitialSecret = initialSecret "server in"

initialSecret :: ByteString -> Cipher -> CID -> Secret
initialSecret label cipher cid =
    TLS.hkdfExpandLabel hash iniSecret label "" hashSize
  where
    hash = TLS.cipherHash cipher
    iniSecret = TLS.hkdfExtract hash initialSalt cid
    hashSize = TLS.hashDigestSize hash

aeadKey :: Cipher -> Secret -> Key
aeadKey = genKey "quic key"

headerProtectionKey :: Cipher -> Secret -> Key
headerProtectionKey = genKey "quic hp"

genKey :: ByteString -> Cipher -> Secret -> Key
genKey label cipher secret = TLS.hkdfExpandLabel hash secret label "" keySize
  where
    hash = TLS.cipherHash cipher
    bulk = TLS.cipherBulk cipher
    keySize = TLS.bulkKeySize bulk

initialVector :: Cipher -> Secret -> IV
initialVector cipher secret = TLS.hkdfExpandLabel hash secret "quic iv" "" ivSize
  where
    hash = TLS.cipherHash cipher
    bulk = TLS.cipherBulk cipher
    ivSize  = max 8 (TLS.bulkIVSize bulk + TLS.bulkExplicitIV bulk)

----------------------------------------------------------------

cipherEncrypt :: Cipher -> Key -> Nonce -> PlainText -> AddDat -> CipherText
cipherEncrypt cipher
  | cipher == cipher_TLS13_AES128GCM_SHA256        = aes128gcmEncrypt
  | cipher == cipher_TLS13_AES128CCM_SHA256        = undefined
  | cipher == cipher_TLS13_AES256GCM_SHA384        = undefined
  | cipher == cipher_TLS13_CHACHA20POLY1305_SHA256 = undefined
  | otherwise                                      = error "cipherEncrypt"

cipherDecrypt :: Cipher -> Key -> Nonce -> CipherText -> AddDat -> PlainText
cipherDecrypt cipher
  | cipher == cipher_TLS13_AES128GCM_SHA256        = aes128gcmDecrypt
  | cipher == cipher_TLS13_AES128CCM_SHA256        = undefined
  | cipher == cipher_TLS13_AES256GCM_SHA384        = undefined
  | cipher == cipher_TLS13_CHACHA20POLY1305_SHA256 = undefined
  | otherwise                                      = error "cipherDecrypt"

aes128gcmEncrypt :: Key -> Nonce -> PlainText -> AddDat -> CipherText
aes128gcmEncrypt key nonce plain ad = encypted `B.append` convert tag
  where
    ctx = throwCryptoError (cipherInit key) :: AES128
    aeadIni = throwCryptoError $ aeadInit AEAD_GCM ctx nonce
    (AuthTag tag, encypted) = aeadSimpleEncrypt aeadIni ad plain 16

aes128gcmDecrypt :: Key -> Nonce -> CipherText -> AddDat -> PlainText
aes128gcmDecrypt key nonce encypted ad = simpleDecrypt aeadIni ad encypted 16
  where
    ctx = throwCryptoError $ cipherInit key :: AES128
    aeadIni = throwCryptoError $ aeadInit AEAD_GCM ctx nonce

simpleDecrypt :: AEAD cipher -> ByteString -> ByteString -> Int -> ByteString
simpleDecrypt aeadIni header encrypted taglen = plain
  where
    aead                = aeadAppendHeader aeadIni header
    (plain, _aeadFinal) = aeadDecrypt aead encrypted
    _tag                = aeadFinalize _aeadFinal taglen

----------------------------------------------------------------

encryptPayload :: Cipher -> Key -> IV -> PacketNumber -> PlainText -> AddDat -> CipherText
encryptPayload cipher key iv pn frames header = encrypt key nonce plain ad
  where
    encrypt = cipherEncrypt cipher
    ivLen = B.length iv
    pnList = loop pn []
    paddedPnList = replicate (ivLen - length pnList) 0 ++ pnList
    nonce = B.pack $ zipWith xor (B.unpack iv) paddedPnList
    plain = frames
    ad = header
    loop 0 ws = ws
    loop n ws = loop (n `shiftR` 8) (fromIntegral n : ws)

decryptPayload :: Cipher -> Key -> IV -> PacketNumber -> CipherText -> AddDat -> PlainText
decryptPayload cipher key iv pn frames header = decrypt key nonce encrypted ad
  where
    decrypt = cipherDecrypt cipher
    ivLen = B.length iv
    pnList = loop pn []
    paddedPnList = replicate (ivLen - length pnList) 0 ++ pnList
    nonce = B.pack $ zipWith xor (B.unpack iv) paddedPnList
    encrypted = frames
    ad = header
    loop 0 ws = ws
    loop n ws = loop (n `shiftR` 8) (fromIntegral n : ws)

----------------------------------------------------------------

headerProtection :: Cipher -> Key -> Sample -> Mask
headerProtection cipher key sample = cipherHeaderProtection cipher key sample

cipherHeaderProtection :: Cipher -> Key -> (Sample -> Mask)
cipherHeaderProtection cipher key
  | cipher == cipher_TLS13_AES128GCM_SHA256        =
    ecbEncrypt (throwCryptoError (cipherInit key) :: AES128)
  | cipher == cipher_TLS13_AES128CCM_SHA256        = undefined
  | cipher == cipher_TLS13_AES256GCM_SHA384        = undefined
  | cipher == cipher_TLS13_CHACHA20POLY1305_SHA256 = undefined
  | otherwise                                      = error "cipherHeaderProtection"

unprotectHeader :: Cipher -> Header -> Sample -> Key -> (Word8, PacketNumber, Header)
unprotectHeader cipher protectedAndPad sample key = (flags, pn, header)
  where
    mask0 = headerProtection cipher key sample
    Just (flagMask, maskPN) = B.uncons mask0
    Just (proFlags, protectedAndPad1) = B.uncons protectedAndPad
    flags = proFlags `xor` (flagMask .&. 0b1111) -- fixme
    pnLen = fromIntegral (flags .&. 0b11) + 1
    (intermediate, pnAndPad) = B.splitAt undefined protectedAndPad1
    header = B.cons flags (intermediate `B.append` undefined)
    pn = undefined
