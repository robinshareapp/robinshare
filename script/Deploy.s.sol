// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {RobinhoodAddresses} from "../src/flap/RobinhoodAddresses.sol";

/// forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
contract Deploy is Script {
    function run() external {
        // ⚠️ GUARDA DE RAIL, agregada 2026-08-31.
        //
        // Este script deploya el rail de FLAP, que ya NO es la linea viva. El del rail de pons es
        // `DeployPons.s.sol`. Los dos viven en el mismo repo, con sus dos runbooks, y el comando
        // viejo esta a un copy-paste de distancia: deployar la factory equivocada el dia del
        // launch cuesta gas y, peor, deja al producto conectado a un rail que no es el suyo.
        //
        // Sigue siendo ejecutable a proposito (la rama `flap-rail` y el tag `audited-v3` son la
        // version auditada), pero hay que pedirlo explicitamente.
        require(
            vm.envOr("I_MEAN_THE_FLAP_RAIL", false),
            "Este es el deploy del rail de FLAP. Para pons usa script/DeployPons.s.sol. Si de verdad queres el de Flap: I_MEAN_THE_FLAP_RAIL=true"
        );
        require(block.chainid == RobinhoodAddresses.CHAIN_ID, "wrong chain (expected 4663)");
        // Attester CANONICO de la factory (wallet dedicada del oraculo FLEDGE). Env obligatoria.
        address attester = vm.envAddress("ATTESTER_ADDRESS");
        require(attester != address(0), "set ATTESTER_ADDRESS");
        vm.startBroadcast();
        SocialFeeEscrowFactory factory = new SocialFeeEscrowFactory(attester);
        vm.stopBroadcast();
        console2.log("SocialFeeEscrowFactory:", address(factory));
        console2.log("VaultPortal:", factory.vaultPortal());
        console2.log("Canonical attester:", factory.attester());
    }
}
