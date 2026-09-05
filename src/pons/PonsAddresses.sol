// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PonsAddresses — el UNICO lugar donde viven las direcciones del rail pons v2
/// @notice Fuente canonica para el script de deploy, el fork test y el runbook. Antes de esto las
///         direcciones solo existian en el spec y en la cabeza de quien tipeaba el comando.
///
/// @dev Todos los valores VERIFICADOS on-chain con `cast call` contra
///      https://rpc.mainnet.chain.robinhood.com (chainId 4663) el 2026-08-30, bloque 50.396.351:
///
///        launchEnabled()      -> true      (el gate publico esta abierto: no hace falta whitelist)
///        launchFee()          -> 5e14 wei  (0,0005 ETH)
///        maxCreatorTaxBps()   -> 1000      (10,00%)
///        feeEscrow()          -> 0xd3AF...Ac9e
///        memeHook()           -> 0xE5e7...e044
///        launchDeployer()     -> 0x3711...1A42
///        owner()              -> 0x263e...19Dd  (Safe 2-de-3)
///
///      OJO con `LAUNCH_FEE`, `MAX_CREATOR_TAX_BPS` y `LAUNCH_CONFIG_ID`: son estado MUTABLE del
///      factory de pons (`setLaunchFee`, `setMaxCreatorTaxBps`, `addLaunchConfig`), no constantes
///      del protocolo. Se dejan aca como el valor vigente para documentacion y para los tests; el
///      camino de produccion (la web) los LEE de la cadena antes de lanzar en vez de asumirlos.
library PonsAddresses {
    /// @notice Robinhood Chain (L2 Arbitrum Orbit).
    uint256 internal constant CHAIN_ID = 4663;

    /// @notice PonsV2LaunchFactory — verificado en Blockscout, NO es proxy.
    address internal constant LAUNCH_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    /// @notice V2FeeEscrow — el ledger pull-payment donde se acreditan las creator fees.
    /// @dev Verificado, no es proxy, sin owner y sin `claimFor`: `claim()` es msg.sender-only.
    address internal constant FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    /// @notice PonsV2MemeHook — el hook de Uniswap v4 que cobra post-graduacion.
    address internal constant MEME_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    /// @notice XGeneralVerifier de Flap — oraculo on-chain de la ruta X. NO es de pons.
    /// @dev Proxy upgradeable de un Safe 2-de-5, implementacion no verificada, alimentado por un
    ///      servicio HTTP de Flap sin auth y sin SLA.
    ///
    ///      ESTA DIRECCION QUEDA COMO REGISTRO DE LO MEDIDO, NO COMO ALGO QUE USEMOS.
    ///      El deploy va con `X_VERIFIER_AT_LAUNCH` (= 0). Ver abajo.
    address internal constant X_GENERAL_VERIFIER = 0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17;

    /// @notice El xVerifier con el que se deploya la factory. CERO a proposito.
    ///
    /// @dev DECISION DE JOSE, 2026-08-31 (`PENDIENTES.md` §4): el lanzamiento sale con GitHub y
    ///      wallet, sin la ruta de X. Con `xVerifier = 0`, `createVault` con `identityType = 2`
    ///      revierte `ZeroAddress()`, asi que la ruta no existe ni por accidente.
    ///
    ///      POR QUE. El camino positivo de X nunca funciono de punta a punta, en ningun lado: el
    ///      fork solo prueba que el verifier real rechaza una firma forjada. Y el oraculo es infra
    ///      de un competidor: si lo apagan o cambian la implementacion del proxy, un vault de X
    ///      queda SIN RUTA DE CLAIM PARA SIEMPRE — `xVerifier` es immutable en el vault. Para un
    ///      producto cuya promesa entera es "el builder cobra", dejar viva una ruta que puede
    ///      atrapar el ETH de alguien es peor que no ofrecerla.
    ///
    ///      ES IRREVERSIBLE EN ESTE DEPLOY. `xVerifier` tambien es immutable en la FACTORY y no
    ///      tiene setter: agregar X despues obliga a redeployar la factory entera.
    address internal constant X_VERIFIER_AT_LAUNCH = address(0);

    /// @notice Valor vigente de `launchFee()`. MUTABLE por el owner de pons — leer en vivo.
    uint256 internal constant LAUNCH_FEE = 0.0005 ether;

    /// @notice Unico launch config habilitado hoy. MUTABLE — el factory acepta agregar mas.
    uint256 internal constant LAUNCH_CONFIG_ID = 0;

    /// @notice Valor vigente de `maxCreatorTaxBps()`. MUTABLE por el owner de pons.
    uint16 internal constant MAX_CREATOR_TAX_BPS = 1000;
}
