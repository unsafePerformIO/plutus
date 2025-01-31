{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE TemplateHaskell #-}

module PlutusCore.Version (
  Version(..)
  , versionMajor
  , versionMinor
  , versionPatch
  , defaultVersion) where

import PlutusPrelude

import Control.Lens
import Data.Hashable
import Instances.TH.Lift ()

{- |
The version of Plutus Core used by this program.

The intention is to convey different levels of backwards compatibility for existing scripts:
- Major version changes are backwards-incompatible
- Minor version changes are backwards-compatible
- Patch version changes should be entirely invisible (and we will likely not use this level)

The version used should be changed only when the /language itself/ changes.
For example, adding a new kind of term to the language would require a minor
version bump; removing a kind of term would require a major version bump.

Similarly, changing the semantics of the language will require a version bump,
typically a major one. This is the main reason why the version is actually
tracked in the AST: we can have two language versions with identical ASTs but
different semantics, so we need to track the version explicitly.

Compatibility is about compatibility for specific scripts, not about e.g. tools which consume
scripts. Adding a new kind of term does not change how existing scripts behave, but does
change what tools would need to do to process scripts.
-}
data Version
    = Version { _versionMajor :: Natural, _versionMinor :: Natural, _versionPatch :: Natural }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (NFData, Hashable)

makeLenses ''Version

-- This is probably what the derived version would do, but better to be explicit since it's
-- important
instance Ord Version where
  compare (Version major1 minor1 patch1) (Version major2 minor2 patch2) =
    compare major1 major2 <> compare minor1 minor2 <> compare patch1 patch2

-- | The default version of Plutus Core supported by this library.
defaultVersion :: Version
defaultVersion = Version 1 0 0
