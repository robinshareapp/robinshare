// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Flap + chain addresses on Robinhood Chain mainnet (chain id 4663).
///         Sources: docs.flap.sh (llms-full, 2026-07-09) + on-chain verification.
library RobinhoodAddresses {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant PORTAL = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09; // v5.14.15
    address internal constant VAULT_PORTAL = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;
    address internal constant TAX_TOKEN_V3_IMPL = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333;
    address internal constant TAX_TOKEN_HELPER = 0xb10bD2672aE63735d677164A54B573a016f0203C;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant FEED_AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant FEED_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    /// @dev Guardian OFICIAL de Robinhood Chain, del commit 3b7689d8 de flap-sh/FlapVaultExample
    ///      ("add support for Robinhood Chain"). Resuelve el placeholder histórico.
    ///      SI lo usamos — hoy co-gatea/gatea 3 funciones: `SocialFeeEscrow.emergencyWithdrawNative`,
    ///      `SocialFeeEscrow.setRescueForward` (ambas onlyGuardian) y
    ///      `SocialFeeEscrowFactory.rotateAttester` (co-gateada junto al attester vigente,
    ///      Audit v3 finding 5) — todas via `_getGuardian()`, heredado de VaultBase.
    address internal constant GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;
    // XGeneralVerifier oficial de Flap en Robinhood (docs.flap.sh, verificado on-chain 2026-07-16)
    address internal constant X_VERIFIER = 0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17;
}
