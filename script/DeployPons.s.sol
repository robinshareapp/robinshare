// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {PonsAddresses} from "../src/pons/PonsAddresses.sol";
import {IPonsV2Launchpad} from "../src/pons/IPonsV2.sol";

/// @title DeployPons — despliega la RobinShareVaultFactory sobre el rail pons v2
///
/// @notice Uso (el runbook completo esta en docs/RUNBOOK-launch-pons.md):
///
///   export PATH="$HOME/.foundry/bin:$PATH"
///   cd contracts
///
///   # 1. ENSAYO — sin --broadcast no firma ni manda nada, solo simula e imprime el preflight
///   ATTESTER_ADDRESS=0x... ATTESTER_ADMIN=0x... \
///     forge script script/DeployPons.s.sol --rpc-url robinhood
///
///   # 2. REAL — recien aca se firma
///   ATTESTER_ADDRESS=0x... ATTESTER_ADMIN=0x... \
///     forge script script/DeployPons.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
///
/// @dev Las cinco direcciones del constructor son INMUTABLES en la factory y los vaults las
///      copian a las suyas. Un error de tipeo no se arregla con una transaccion: obliga a
///      redeployar y a abandonar todos los vaults ya creados. Por eso salen de `PonsAddresses`
///      y no de la linea de comandos, y por eso `test/DeployPons.t.sol` verifica el cableado
///      hasta adentro del vault antes de que esto toque una red.
contract DeployPons is Script {
    function run() external returns (RobinShareVaultFactory factory) {
        require(block.chainid == PonsAddresses.CHAIN_ID, "wrong chain (expected 4663)");

        // Wallet DEDICADA del oraculo de GitHub, sin fondos. Su PK vive solo en el env de Vercel.
        address attester = vm.envAddress("ATTESTER_ADDRESS");
        require(attester != address(0), "set ATTESTER_ADDRESS");

        // Co-gate de emergencia que SOLO puede rotar el attester (no toca fondos, no firma
        // vouchers). `address(0)` lo desactiva a proposito — es una decision abierta de Jose:
        // sin sucesor, una llave de attester perdida congela para siempre el ETH de todos los
        // vaults de GitHub. Ver PENDIENTES.md.
        address attesterAdmin = vm.envOr("ATTESTER_ADMIN", address(0));

        _preflight(attester);

        vm.startBroadcast();
        factory = deploy(attester, attesterAdmin);
        vm.stopBroadcast();

        console2.log("");
        console2.log("RobinShareVaultFactory:", address(factory));
        console2.log("  attester:            ", factory.attester());
        console2.log("  attesterAdmin:       ", factory.attesterAdmin());
        console2.log("  feeEscrow (pons):    ", factory.feeEscrow());
        console2.log("  ponsFactory:         ", factory.ponsFactory());
        console2.log("  xVerifier:           ", factory.xVerifier());
        if (factory.xVerifier() == address(0)) {
            console2.log("    ^ CERO a proposito: el launch va SIN la ruta de X (PENDIENTES seccion 4).");
            console2.log("      `createVault` con identityType=2 va a revertir. Es IRREVERSIBLE:");
            console2.log("      agregar X despues obliga a redeployar la factory.");
        }
        console2.log("");
        console2.log("constructor-args para forge verify-contract:");
        console2.logBytes(constructorArgs(attester, attesterAdmin));
    }

    /// @notice El despliegue en si, SIN broadcast — para que el test lo pueda ejercer sin red.
    function deploy(address attester, address attesterAdmin)
        public
        returns (RobinShareVaultFactory)
    {
        return new RobinShareVaultFactory(
            attester,
            PonsAddresses.FEE_ESCROW,
            PonsAddresses.LAUNCH_FACTORY,
            PonsAddresses.X_VERIFIER_AT_LAUNCH,
            attesterAdmin
        );
    }

    /// @notice Los args del constructor ya encodeados, para `forge verify-contract`.
    /// @dev Los imprime el propio script para que el runbook no dependa de que alguien vuelva a
    ///      tipear cinco direcciones — el modo mas facil de deployar un bytecode que no verifica.
    function constructorArgs(address attester, address attesterAdmin)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(
            attester,
            PonsAddresses.FEE_ESCROW,
            PonsAddresses.LAUNCH_FACTORY,
            PonsAddresses.X_VERIFIER_AT_LAUNCH,
            attesterAdmin
        );
    }

    /// @notice Lee la config VIVA de pons antes de deployar y avisa si se movio.
    /// @dev `launchFee`, `maxCreatorTaxBps` y el set de launch configs son estado mutable del
    ///      owner de pons (un Safe 2-de-3), no constantes del protocolo. Los valores de
    ///      `PonsAddresses` son documentacion de lo medido, no una promesa: esto compara.
    function _preflight(address attester) internal view {
        IPonsV2Launchpad pons = IPonsV2Launchpad(PonsAddresses.LAUNCH_FACTORY);

        console2.log("--- preflight: config viva de pons v2 ---");
        uint256 fee = pons.launchFee();
        uint256 maxTax = pons.maxCreatorTaxBps();
        uint256 configs = pons.launchConfigCount();
        bool open = pons.launchEnabled();

        console2.log("  launchFee (wei):     ", fee);
        console2.log("  maxCreatorTaxBps:    ", maxTax);
        console2.log("  launchConfigCount:   ", configs);
        console2.log("  launchEnabled:       ", open);
        console2.log("  canLaunch(attester): ", pons.canLaunch(attester));

        if (fee != PonsAddresses.LAUNCH_FEE) {
            console2.log("  !! launchFee cambio respecto de lo medido:", PonsAddresses.LAUNCH_FEE);
        }
        if (maxTax != PonsAddresses.MAX_CREATOR_TAX_BPS) {
            console2.log("  !! maxCreatorTaxBps cambio respecto de lo medido:", PonsAddresses.MAX_CREATOR_TAX_BPS);
        }
        if (!open) {
            console2.log("  !! launchEnabled=false: el gate publico esta cerrado, solo whitelist");
        }
        console2.log("-----------------------------------------");
    }
}
