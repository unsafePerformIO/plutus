{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE MonoLocalBinds     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeOperators      #-}
module Plutus.Contracts.ErrorHandling(
    Schema
    , MyError(..)
    , AsMyError(..)
    , contract
    ) where

import           Control.Lens
import           Control.Monad            (void)
import           Control.Monad.Error.Lens
import           Data.Aeson               (FromJSON, ToJSON)
import           Data.Text                (Text)
import           GHC.Generics             (Generic)

import           Data.Default             (Default (def))
import qualified Ledger.TimeSlot          as TimeSlot
import           Plutus.Contract

-- $errorHandling
-- Demonstrates how to deal with errors in Plutus contracts. We define a custom
-- error type 'MyError' with three constructors and use
-- 'Control.Lens.makeClassyPrisms' to generate the 'AsMyError' class. We can
-- then use 'MyError' in our contracts with the combinators from
-- 'Control.Monad.Error.Lens'. The unit tests in 'Spec.ErrorHandling' show how
-- to write tests for error conditions.

type Schema =
        Endpoint "throwError" ()
        .\/ Endpoint "catchError" ()
        .\/ Endpoint "catchContractError" ()

-- | 'MyError' has a constructor for each type of error that our contract
 --   can throw. The 'MyContractError' constructor wraps a 'ContractError'.
data MyError =
    Error1 Text
    | Error2
    | MyContractError ContractError
    deriving stock (Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

makeClassyPrisms ''MyError

instance AsContractError MyError where
    -- 'ContractError' is another error type. It is defined in
    -- 'Plutus.Contract.Request'. By making 'MyError' an
    -- instance of 'AsContractError' we can handle 'ContractError's
    -- thrown by other contracts in our code (see 'catchContractError')
    _ContractError = _MyContractError


-- | Throw an 'Error1', using 'Control.Monad.Error.Lens.throwing' and the
--   prism generated by 'makeClassyPrisms'
throw :: AsMyError e => Contract w s e ()
throw = throwing _Error1 "something went wrong"

-- | Handle the error from 'throw' using 'Control.Monad.Error.Lens.catching'
throwAndCatch :: AsMyError e => Contract w s e ()
throwAndCatch =
    let handleError1 :: Text -> Contract w s e ()
        handleError1 _ = pure ()
    in catching _Error1 throw handleError1

-- | Handle an error from another contract (in this case, 'awaitTime)
catchContractError :: (AsMyError e) => Contract w s e ()
catchContractError =
    catching _MyContractError
        (void $ mapError (review _MyContractError) $ awaitTime $ TimeSlot.slotToBeginPOSIXTime def 10)
        (\_ -> throwing_ _Error2)

contract
    :: ( AsMyError e
       , AsContractError e
       )
    => Contract w Schema e ()
contract =
    (endpoint @"throwError" >> throw)
    `select` (endpoint @"catchError" >> throwAndCatch)
    `select` (endpoint @"catchContractError" >> catchContractError)
