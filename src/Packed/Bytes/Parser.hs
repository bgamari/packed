{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE UnboxedSums #-}
{-# LANGUAGE UnboxedTuples #-}

{-# OPTIONS_GHC
 -Weverything
 -fno-warn-unsafe
 -fno-warn-implicit-prelude
 -fno-warn-missing-import-lists
 -O2
#-}

module Packed.Bytes.Parser
  ( Parser(..)
  , ParserLevity(..)
  , Result(..)
  , Leftovers(..)
  , parseStreamST
  , decimalWord
  , skipSpace
  , takeBytesWhileMember
  , bytes
  , byte
  , any
  , endOfInput
  ) where

import Prelude hiding (any)
import GHC.Int (Int(I#))
import GHC.Exts (State#,Int#,ByteArray#,Word#,(+#),(-#),(>#),plusWord#,timesWord#,
  indexWord8Array#,eqWord#)
import GHC.Types (TYPE,RuntimeRep(..))
import GHC.Word (Word(W#),Word8(W8#))
import GHC.ST (ST(..))
import Packed.Bytes (Bytes(..))
import Packed.Bytes.Small (ByteArray(..))
import Packed.Bytes.Stream (ByteStream(..))
import Packed.Bytes.Set (ByteSet)
import qualified Control.Monad
import qualified Packed.Bytes.Small as BA
import qualified Packed.Bytes.Stream as Stream
import qualified Packed.Bytes.Window as BAW
import qualified Packed.Bytes as B
import qualified Data.Primitive as PM

type Bytes# = (# ByteArray#, Int#, Int# #)
type Maybe# (a :: TYPE r) = (# (# #) | a #)
type Leftovers# s = (# Bytes# , ByteStream s #)
type Result# s (r :: RuntimeRep) (a :: TYPE r) =
  (# Maybe# (Leftovers# s), Maybe# a #)

data Result s a = Result
  { resultLeftovers :: !(Maybe (Leftovers s))
  , resultValue :: !(Maybe a)
  }

data Leftovers s = Leftovers
  { leftoversChunk :: {-# UNPACK #-} !Bytes
    -- ^ The last chunk pulled from the stream
  , leftoversStream :: ByteStream s
    -- ^ The remaining stream
  }

parseStreamST :: ByteStream s -> Parser a -> ST s (Result s a)
parseStreamST stream (Parser (ParserLevity f)) = ST $ \s0 ->
  case f (# | (# (# unboxByteArray BA.empty, 0#, 0# #), stream #) #) s0 of
    (# s1, r #) -> (# s1, boxResult r #)

boxResult :: Result# s 'LiftedRep a -> Result s a
boxResult (# leftovers, val #) = case val of
  (# (# #) | #) -> Result (boxLeftovers leftovers) Nothing
  (# | a #) -> Result (boxLeftovers leftovers) (Just a)

boxLeftovers :: Maybe# (Leftovers# s) -> Maybe (Leftovers s)
boxLeftovers (# (# #) | #) = Nothing
boxLeftovers (# | (# bytes, stream #) #) = Just (Leftovers (boxBytes bytes) stream)

newtype Parser a = Parser (ParserLevity 'LiftedRep a)

instance Functor Parser where
  fmap = mapParser

instance Applicative Parser where
  pure = pureParser
  (<*>) = Control.Monad.ap

instance Monad Parser where
  return = pure
  (>>=) = bindLifted

newtype ParserLevity (r :: RuntimeRep) (a :: TYPE r) = ParserLevity
  { getParserLevity :: forall s.
       Maybe# (Leftovers# s)
    -> State# s
    -> (# State# s, Result# s r a #)
  }

bytesLength :: Bytes# -> Int
bytesLength (# _, _, len #) = I# len

bytesPayload :: Bytes# -> ByteArray
bytesPayload (# arr, _, _ #) = ByteArray arr

bytesIndex :: Bytes# -> Int -> Word8
bytesIndex (# arr, off, _ #) ix = BA.unsafeIndex (ByteArray arr) (I# off + ix)

word8ToWord :: Word8 -> Word
word8ToWord = fromIntegral

nextNonEmpty :: ByteStream s -> State# s -> (# State# s, Maybe# (Leftovers# s) #)
nextNonEmpty (ByteStream f) s0 = case f s0 of
  (# s1, r #) -> case r of
    (# (# #) | #) -> (# s1, (# (# #) | #) #)
    (# | (# bytes@(# _,_,len #), stream #) #) -> case len of
      0# -> nextNonEmpty stream s1
      _ -> (# s1, (# | (# bytes, stream #) #) #)

{-# INLINE withNonEmpty #-}
withNonEmpty :: forall s (r :: RuntimeRep) (b :: TYPE r).
     Maybe# (Leftovers# s)
  -> State# s
  -> (State# s -> (# State# s, Result# s r b #))
  -> (Word# -> Bytes# -> ByteStream s -> State# s -> (# State# s, Result# s r b #))
     -- This lambda takes a Word8, not a full machine word.
     -- The second argument is the complete,non-empty chunk
     -- with the head byte still intact.
  -> (# State# s, Result# s r b #)
withNonEmpty (# (# #) | #) s0 g _ = g s0
withNonEmpty (# | (# bytes0@(# arr0,off0,len0 #), stream0 #) #) s0 g f = case len0 ># 0# of
  1# -> f (indexWord8Array# arr0 off0) bytes0 stream0 s0
  _ -> case nextNonEmpty stream0 s0 of
    (# s1, r #) -> case r of
      (# (# #) | #) -> g s1
      (# | (# bytes1@(# arr1, off1, _ #), stream1 #) #) -> 
        f (indexWord8Array# arr1 off1) bytes1 stream1 s1

decimalDigit :: ParserLevity 'WordRep Word#
decimalDigit = ParserLevity $ \leftovers0 s0 -> case leftovers0 of
  (# (# #) | #) -> (# s0, (# (# (# #) | #), (# (# #) | #) #) #)
  (# | (# bytes0@(# _,_,len #), stream0 #) #) ->
    let !(# s1, r #) = case len of
          0# -> nextNonEmpty stream0 s0
          _ -> (# s0, (# | (# bytes0, stream0 #) #) #)
     in case r of
          (# (# #) | #) -> (# s1, (# (# (# #) | #), (# (# #) | #) #) #)
          (# | (# bytes1, stream1 #) #) ->
            let !w = word8ToWord (bytesIndex bytes1 0) - 48
             in if w < 10
                  then (# s1, (# (# | (# unsafeDrop# 1 bytes1, stream1 #) #), (# | unboxWord w #) #) #)
                  else (# s1, (# (# | (# bytes1, stream1 #) #), (# (# #) | #) #) #)

decimalContinue :: Word# -> ParserLevity 'WordRep Word#
decimalContinue theWord = ParserLevity (action theWord) where
  action :: Word# -> Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'WordRep Word# #)
  action !w0 (# (# #) | #) s0 = (# s0, (# (# (# #) | #), (# | w0 #) #) #)
  action !w0 (# | leftovers0 #) s0 = go w0 leftovers0 s0
  go :: Word# -> Leftovers# s -> State# s -> (# State# s, Result# s 'WordRep Word# #)
  go !w0 leftovers0@(# (# _,_,len #), !stream0 #) s0 = 
    let !(# s1, leftovers1 #) = case len of
          0# -> nextNonEmpty stream0 s0
          _ -> (# s0, (# | leftovers0 #) #)
     in case leftovers1 of
          (# (# #) | #) -> (# s1, (# (# (# #) | #), (# | w0 #) #) #)
          (# | (# bytes1, stream1 #) #) ->
            let !w = word8ToWord (bytesIndex bytes1 0) - 48
             in if w < 10
                  then go (plusWord# (timesWord# w0 10##) (unboxWord w)) (# unsafeDrop# 1 bytes1, stream1 #) s1
                  else (# s1, (# (# | (# bytes1, stream1 #) #), (# | w0 #) #) #)

decimalWordUnboxed :: ParserLevity 'WordRep Word#
decimalWordUnboxed = bindWord decimalDigit decimalContinue

skipSpaceUnboxed :: ParserLevity 'LiftedRep ()
skipSpaceUnboxed = ParserLevity go where
  go :: Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'LiftedRep () #)
  go (# (# #) | #) s0 = (# s0, (# (# (# #) | #), (# | () #) #) #)
  go (# | (# bytes0@(# arr, off, len #), !stream0@(ByteStream streamFunc) #) #) s0 = case BAW.findNonAsciiSpace' (I# off) (I# len) (ByteArray arr) of
    (# (# #) | #) -> case streamFunc s0 of
      (# s1, r #) -> go r s1
    (# | ix #) -> (# s0, (# (# | (# unsafeDrop# (I# (ix -# off)) bytes0, stream0 #) #), (# | () #) #) #)


takeBytesWhileMember :: ByteSet -> Parser Bytes
takeBytesWhileMember b = Parser (takeBytesWhileMemberUnboxed b)

takeBytesWhileMemberUnboxed :: ByteSet -> ParserLevity 'LiftedRep Bytes
takeBytesWhileMemberUnboxed set = ParserLevity (go (# (# #) | #)) where
  go :: Maybe# Bytes# -> Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'LiftedRep Bytes #)
  go mbytes (# (# #) | #) s0 = (# s0, (# (# (# #) | #), (# | maybeBytesToBytes mbytes #) #) #)
  go mbytes (# | (# bytes0@(# arr, off, len #), !stream0@(ByteStream streamFunc) #) #) s0 = case BAW.findNonMemberByte (I# off) (I# len) set (ByteArray arr) of
    Nothing -> case streamFunc s0 of
      (# s1, r #) -> go (# | appendMaybeBytes mbytes bytes0 #) r s1
    Just (I# ix,!_) -> (# s0, (# (# | (# unsafeDrop# (I# (ix -# off)) bytes0, stream0 #) #), (# | boxBytes (appendMaybeBytes mbytes (# arr, off, ix -# off #)) #) #) #)

byteUnboxed :: Word8 -> ParserLevity 'LiftedRep ()
byteUnboxed expectedByte@(W8# expected) = ParserLevity go where
  go :: Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'LiftedRep () #)
  go m s0 = withNonEmpty m s0
    (\s -> (# s, (# (# (# #) | #), (# (# #) | #) #) #))
    (\actual bytes stream s -> case eqWord# expected actual of
      1# -> (# s, (# (# | (# unsafeDrop# 1 bytes, stream #) #), (# | () #) #) #)
      _ -> (# s, (# (# | (# bytes, stream #) #), (# (# #) | #) #) #)
    )

anyUnboxed :: ParserLevity 'WordRep Word#
anyUnboxed = ParserLevity go where
  go :: Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'WordRep Word# #)
  go m s0 = withNonEmpty m s0
    (\s -> (# s, (# (# (# #) | #), (# (# #) | #) #) #))
    (\theByte bytes stream s ->
      (# s, (# (# | (# unsafeDrop# 1 bytes, stream #) #), (# | theByte #) #) #)
    )

endOfInputUnboxed :: ParserLevity 'LiftedRep ()
endOfInputUnboxed = ParserLevity go where
  go :: Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'LiftedRep () #)
  go m s0 = withNonEmpty m s0
    (\s -> (# s, (# (# (# #) | #), (# | () #) #) #))
    (\_ bytes stream s -> 
      (# s, (# (# | (# bytes, stream #) #), (# (# #) | #) #) #)
    )

endOfInput :: Parser ()
endOfInput = Parser endOfInputUnboxed

any :: Parser Word8
any = Parser (boxWord8Parser anyUnboxed)

byte :: Word8 -> Parser ()
byte theByte = Parser (byteUnboxed theByte)

bytes :: Bytes -> Parser ()
bytes b = Parser (bytesUnboxed b)

bytesUnboxed :: Bytes -> ParserLevity 'LiftedRep ()
bytesUnboxed !theBytes@(Bytes parr poff plen) = ParserLevity (go poff) where
  pend = poff + plen
  go :: Int -> Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s 'LiftedRep () #)
  go !ix (# (# #) | #) s0 = if ix == pend
    then (# s0, (# (# (# #) | #), (# | () #) #) #)
    else (# s0, (# (# (# #) | #), (# (# #) | #) #) #)
  go !ix (# | leftovers@(# bytes0@(# arr, off, len #), !stream0@(ByteStream streamFunc) #) #) s0 = 
    case BAW.stripPrefixResumable ix (I# off) (pend - ix) (I# len) parr (ByteArray arr) of
      (# (# #) | | #) -> (# s0, (# (# | leftovers #), (# (# #) | #) #) #)
      (# | (# #) | #) -> (# s0, (# (# | (# unsafeDrop# (pend - ix) bytes0, stream0 #) #), (# | () #) #) #)
      (# | | (# #) #) -> case streamFunc s0 of
        (# s1, r #) -> go (ix + I# len) r s1

-- replicateUntilMember :: forall a. ByteSet -> Parser a -> Parser (Array a)
-- replicateUntilMember separators b p = go []
--   where
--   go :: [a] -> Parser
--   go !xs = 
  

-- {-# INLINE replicateUntilTemplate #-}
-- replicateUntilTemplate :: forall a. (Word8 -> Bool) -> Parser a -> Parser (Array a)
-- replicateUntilTemplate predicate (Parser (ParserLevity f)) = Parser (ParserLevity (go [])) where
--   go :: [a] -> Maybe# (Leftovers# s) -> State# s -> (# State# s, Result# s LiftedRep (Array a) #)
--   go !xs (# (# #) | #) s0 = (# s0, (# (# (# #) | #), (# (# #) | #) #) #)
--   go !xs (# | leftovers@(# bytes0@(# arr, off, len #), !stream0@(ByteStream streamFunc) #) #) s0 = 
--     if I# len > 0
--       then if predicate (PM.indexByteArray (ByteArray arr) (I# off))
--         then (# s0, (# (# | (# bytes0, stream0 #) #), (# (# #) | #) #) #)
--         else case f (# | (# unsafeDrop# 1 bytes0, stream0, stream0 #) #) s0 
--       else case nextNonEmpty stream0 s0 of
--         (# s1, r #) -> case r of
--           (# (# #) | #) -> (# s1, (# (# (# #) | #), (# (# #) | #) #) #)
--           (# | (# bytes1@(# arr1, off1, _ #), stream1 #) #) -> if predicate (PM.indexByteArray (ByteArray arr1) (I# off1))
--             then (# s1, (# (# | (# unsafeDrop# 1 bytes1, stream1 #) #), (# | () #) #) #)
--             else (# s1, (# (# | (# bytes1, stream1 #) #), (# (# #) | #) #) #)

appendMaybeBytes :: Maybe# Bytes# -> Bytes# -> Bytes#
appendMaybeBytes (# (# #) | #) theBytes = theBytes
appendMaybeBytes (# | b #) theBytes = unboxBytes (B.append (boxBytes b) (boxBytes theBytes))

maybeBytesToBytes :: Maybe# Bytes# -> Bytes
maybeBytesToBytes (# (# #) | #) = B.empty
maybeBytesToBytes (# | theBytes #) = boxBytes theBytes

skipSpace :: Parser ()
skipSpace = Parser skipSpaceUnboxed

decimalWord :: Parser Word
decimalWord = Parser (boxWordParser decimalWordUnboxed)

mapParser :: (a -> b) -> Parser a -> Parser b
mapParser f p = bindLifted p (pureParser . f)

pureParser :: a -> Parser a
pureParser a = Parser $ ParserLevity $ \leftovers0 s0 ->
  (# s0, (# leftovers0, (# | a #) #) #)

bindLifted :: Parser a -> (a -> Parser b) -> Parser b
bindLifted (Parser (ParserLevity f)) g = Parser $ ParserLevity $ \leftovers0 s0 -> case f leftovers0 s0 of
  (# s1, (# leftovers1, val #) #) -> case val of
    (# (# #) | #) -> (# s1, (# leftovers1, (# (# #) | #) #) #)
    (# | x #) -> case g x of
      Parser (ParserLevity k) -> k leftovers1 s1


bindWord :: ParserLevity 'WordRep Word# -> (Word# -> ParserLevity 'WordRep Word#) -> ParserLevity 'WordRep Word#
bindWord (ParserLevity f) g = ParserLevity $ \leftovers0 s0 -> case f leftovers0 s0 of
  (# s1, (# leftovers1, val #) #) -> case val of
    (# (# #) | #) -> (# s1, (# leftovers1, (# (# #) | #) #) #)
    (# | x #) -> case g x of
      ParserLevity k -> k leftovers1 s1

boxWord8Parser :: ParserLevity 'WordRep Word# -> ParserLevity 'LiftedRep Word8
boxWord8Parser p = ParserLevity $ \leftovers0 s0 ->
  case getParserLevity p leftovers0 s0 of
    (# s1, (# leftovers1, val #) #) -> case val of
      (# (# #) | #) -> (# s1, (# leftovers1, (# (# #) | #) #) #)
      (# | x #) -> (# s1, (# leftovers1, (# | W8# x #) #) #)

boxWordParser :: ParserLevity 'WordRep Word# -> ParserLevity 'LiftedRep Word
boxWordParser p = ParserLevity $ \leftovers0 s0 ->
  case getParserLevity p leftovers0 s0 of
    (# s1, (# leftovers1, val #) #) -> case val of
      (# (# #) | #) -> (# s1, (# leftovers1, (# (# #) | #) #) #)
      (# | x #) -> (# s1, (# leftovers1, (# | W# x #) #) #)

unboxWord :: Word -> Word#
unboxWord (W# i) = i

-- This assumes that the Bytes is longer than the index. It also does
-- not eliminate zero-length references to byte arrays.
unsafeDrop# :: Int -> Bytes# -> Bytes#
unsafeDrop# (I# i) (# arr, off, len #) = (# arr, off +# i, len -# i #)

unboxByteArray :: ByteArray -> ByteArray#
unboxByteArray (ByteArray arr) = arr

boxBytes :: Bytes# -> Bytes
boxBytes (# a, b, c #) = Bytes (ByteArray a) (I# b) (I# c)

unboxBytes :: Bytes -> Bytes#
unboxBytes (Bytes (ByteArray a) (I# b) (I# c)) = (# a,b,c #)

unboxInt :: Int -> Int#
unboxInt (I# i) = i

