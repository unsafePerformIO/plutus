-- editorconfig-checker-disable-file
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RoleAnnotations       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
module PlutusTx.Code where

import PlutusCore qualified as PLC
import PlutusIR qualified as PIR
import PlutusTx.Coverage
import PlutusTx.Lift.Instances ()
import UntypedPlutusCore qualified as UPLC

import Control.Exception
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Functor (void)
import Data.List qualified as List
import Data.Set (Set)
import Data.Set qualified as Set
import ErrorCode
import Flat (Flat (..), unflat)
import Flat.Decoder (DecodeException)
import GHC.Generics
-- We do not use qualified import because the whole module contains off-chain code
import Prelude as Haskell
import Prettyprinter

-- | The span between two source locations.
--
-- This corresponds roughly to the `SrcSpan` used by GHC, but we define our own version so we don't have to depend on `ghc` to use it.
--
-- The line and column numbers are 1-based, and the unit is Unicode code point (or `Char`).
data SrcSpan = SrcSpan
    { srcSpanFile  :: FilePath
    , srcSpanSLine :: Int
    , srcSpanSCol  :: Int
    , srcSpanELine :: Int
    , srcSpanECol  :: Int
    }
    deriving stock (Eq, Ord, Generic)
    deriving anyclass (Flat)

instance Show SrcSpan where
    showsPrec _ s =
        showString (srcSpanFile s)
            . showChar ':'
            . showsPrec 0 (srcSpanSLine s)
            . showChar ':'
            . showsPrec 0 (srcSpanSCol s)
            . showChar '-'
            . showsPrec 0 (srcSpanELine s)
            . showChar ':'
            . showsPrec 0 (srcSpanECol s)

instance Pretty SrcSpan where
    pretty = viaShow

newtype SrcSpans = SrcSpans {unSrcSpans :: Set SrcSpan}
    deriving newtype (Eq, Ord, Semigroup, Monoid)
    deriving stock (Generic)
    deriving anyclass (Flat)

instance Show SrcSpans where
    showsPrec _ (SrcSpans xs) =
        showString "{ "
            . showString
                ( case Set.toList xs of
                    [] -> "no-src-span"
                    ys -> List.intercalate ", " (show <$> ys)
                )
            . showString " }"

instance Pretty SrcSpans where
    pretty = viaShow

-- The final type parameter is inferred to be phantom, but we give it a nominal
-- role, since it corresponds to the Haskell type of the program that was compiled into
-- this 'CompiledCodeIn'. It could be okay to give it a representational role, since
-- we compile newtypes the same as their underlying types, but people probably just
-- shouldn't coerce the final parameter regardless, so we play it safe with a nominal role.
type role CompiledCodeIn representational representational nominal
-- NOTE: any changes to this type must be paralleled by changes
-- in the plugin code that generates values of this type. That is
-- done by code generation so it's not typechecked normally.
-- | A compiled Plutus Tx program. The last type parameter indicates
-- the type of the Haskell expression that was compiled, and
-- hence the type of the compiled code.
--
-- Note: the compiled PLC program does *not* have normalized types,
-- if you want to put it on the chain you must normalize the types first.
data CompiledCodeIn uni fun a =
    -- | Serialized UPLC code and possibly serialized PIR code with metadata used for program coverage.
    SerializedCode BS.ByteString (Maybe BS.ByteString) CoverageIndex
    -- | Deserialized UPLC program, and possibly deserialized PIR program with metadata used for program coverage.
    | DeserializedCode
        (UPLC.Program UPLC.NamedDeBruijn uni fun SrcSpans)
        (Maybe (PIR.Program PLC.TyName PLC.Name uni fun SrcSpans))
        CoverageIndex

-- | 'CompiledCodeIn' instantiated with default built-in types and functions.
type CompiledCode = CompiledCodeIn PLC.DefaultUni PLC.DefaultFun

-- | Apply a compiled function to a compiled argument.
applyCode
    :: (PLC.Closed uni, uni `PLC.Everywhere` Flat, Flat fun)
    => CompiledCodeIn uni fun (a -> b) -> CompiledCodeIn uni fun a -> CompiledCodeIn uni fun b
applyCode fun arg = DeserializedCode (UPLC.applyProgram (getPlc fun) (getPlc arg)) (PIR.applyProgram <$> getPir fun <*> getPir arg) (getCovIdx fun <> getCovIdx arg)

-- | The size of a 'CompiledCodeIn', in AST nodes.
sizePlc :: (PLC.Closed uni, uni `PLC.Everywhere` Flat, Flat fun) => CompiledCodeIn uni fun a -> Integer
sizePlc = UPLC.programSize . getPlc

{- Note [Deserializing the AST]
The types suggest that we can fail to deserialize the AST that we embedded in the program.
However, we just did it ourselves, so this should be impossible, and we signal this with an
exception.
-}
newtype ImpossibleDeserialisationFailure = ImpossibleDeserialisationFailure DecodeException
    deriving anyclass (Exception)
instance Show ImpossibleDeserialisationFailure where
    show (ImpossibleDeserialisationFailure e) = "Failed to deserialise our own program! This is a bug, please report it. Caused by: " ++ show e

instance HasErrorCode ImpossibleDeserialisationFailure where
      errorCode ImpossibleDeserialisationFailure {} = ErrorCode 40

-- | Get the actual Plutus Core program out of a 'CompiledCodeIn'.
getPlc
    :: (PLC.Closed uni, uni `PLC.Everywhere` Flat, Flat fun)
    => CompiledCodeIn uni fun a -> UPLC.Program UPLC.NamedDeBruijn uni fun SrcSpans
getPlc wrapper = case wrapper of
    SerializedCode plc _ _ -> case unflat (BSL.fromStrict plc) of
        Left e  -> throw $ ImpossibleDeserialisationFailure e
        Right p -> p
    DeserializedCode plc _ _ -> plc

getPlcNoAnn
    :: (PLC.Closed uni, uni `PLC.Everywhere` Flat, Flat fun)
    => CompiledCodeIn uni fun a -> UPLC.Program UPLC.NamedDeBruijn uni fun ()
getPlcNoAnn = void . getPlc

-- | Get the Plutus IR program, if there is one, out of a 'CompiledCodeIn'.
getPir
    :: (PLC.Closed uni, uni `PLC.Everywhere` Flat, Flat fun)
    => CompiledCodeIn uni fun a -> Maybe (PIR.Program PIR.TyName PIR.Name uni fun SrcSpans)
getPir wrapper = case wrapper of
    SerializedCode _ pir _ -> case pir of
        Just bs -> case unflat (BSL.fromStrict bs) of
            Left e  -> throw $ ImpossibleDeserialisationFailure e
            Right p -> Just p
        Nothing -> Nothing
    DeserializedCode _ pir _ -> pir

getPirNoAnn
    :: (PLC.Closed uni, uni `PLC.Everywhere` Flat, Flat fun)
    => CompiledCodeIn uni fun a -> Maybe (PIR.Program PIR.TyName PIR.Name uni fun ())
getPirNoAnn = fmap void . getPir

getCovIdx :: CompiledCodeIn uni fun a -> CoverageIndex
getCovIdx wrapper = case wrapper of
  SerializedCode _ _ idx   -> idx
  DeserializedCode _ _ idx -> idx
