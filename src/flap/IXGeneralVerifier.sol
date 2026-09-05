// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IXGeneralVerifier — infra OFICIAL de Flap para pruebas de X/Twitter.
/// @notice Verificador on-chain EIP-712 stateless, desplegado y compartido por Flap.
///         El vault llama verify() para validar una prueba firmada por el oráculo de Flap
///         antes de liberar fondos. Guía: integration-guide-latest.md (GT, 2026-07-11).
///         BSC mainnet: 0xcA8DBE6CAC4BFDc41226b0BaF2359fd99989b3E4. Robinhood (4663): desplegado
///         y verificado on-chain (2026-07-16) — ver RobinhoodAddresses.X_VERIFIER.
interface IXGeneralVerifier {
    struct XGeneralProof {
        uint128 tweetId; // tweet Snowflake ID (crece monotónicamente → replay guard)
        string xHandle; // screen name de X en lowercase (enforced)
        uint128 xId; // user id numérico de X
        string substring; // el substring verificado por el oráculo (presente en el tweet)
    }

    /// @notice Verifica una XGeneralProof firmada por el oráculo. STATELESS (no evita replay).
    function verify(XGeneralProof calldata proof, bytes calldata signature) external view returns (bool);

    /// @notice El address firmante del oráculo en el que confía este verifier.
    function oracleKey() external view returns (address);
}
