// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {RobinhoodAddresses} from "../src/flap/RobinhoodAddresses.sol";

/// @notice Deploy factory (si no se pasa FACTORY) + lanza un token FLEDGE para una
///         identidad (wallet | github | twitter) en un solo broadcast.
///
/// Uso (mainnet):
///   IDENTITY_TYPE=github IDENTITY_VALUE=0x-keezy ATTESTER_ADDRESS=0x<attester> \
///     forge script script/LaunchPilot.s.sol --rpc-url robinhood --broadcast --private-key $WALLET_A_PK
///   # para wallet:  IDENTITY_TYPE=wallet RECIPIENT=0x<wallet-B>  (sin IDENTITY_VALUE)
///
/// Env opcionales: FACTORY (reusar), RECOVERY_DAYS (default 0), DEV_BUY_WEI (default 0.005 ETH),
///                 TOKEN_NAME, TOKEN_SYMBOL.
contract LaunchPilot is Script {
    bytes32 constant TAX_PROXY_INITCODE_HASH =
        0x6ce33cede557fe3331031c87bf9be28f493a6086cdc8770ac0a4c7dd7320dea7;

    function _predictV6(bytes32 salt) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), RobinhoodAddresses.PORTAL, salt, TAX_PROXY_INITCODE_HASH)
                    )
                )
            )
        );
    }

    function _mineSalt() internal pure returns (bytes32 salt, address predicted) {
        for (uint256 i = 1; i < 2_000_000; i++) {
            address a = _predictV6(bytes32(i));
            if (uint256(uint160(a)) & 0xffff == 0x7777) return (bytes32(i), a);
        }
        revert("no salt found");
    }

    function run() external {
        // ⚠️ GUARDA DE RAIL — ver el comentario largo en Deploy.s.sol. Este lanza en el
        // VaultPortal de FLAP; el de pons es `LaunchPons.s.sol`.
        require(
            vm.envOr("I_MEAN_THE_FLAP_RAIL", false),
            "Este es el launch del rail de FLAP. Para pons usa script/LaunchPons.s.sol. Si de verdad queres el de Flap: I_MEAN_THE_FLAP_RAIL=true"
        );
        require(block.chainid == RobinhoodAddresses.CHAIN_ID, "wrong chain (expected 4663)");

        string memory idType = vm.envString("IDENTITY_TYPE"); // wallet | github | twitter
        address attester = vm.envAddress("ATTESTER_ADDRESS");
        require(attester != address(0), "set ATTESTER_ADDRESS");
        bool isWallet = keccak256(bytes(idType)) == keccak256("wallet");
        address recipient = isWallet ? vm.envAddress("RECIPIENT") : address(0);
        string memory idValue = isWallet ? "" : vm.envString("IDENTITY_VALUE");
        uint256 recoveryDays = vm.envOr("RECOVERY_DAYS", uint256(0));
        uint256 devBuy = vm.envOr("DEV_BUY_WEI", uint256(0.005 ether));
        string memory name = vm.envOr("TOKEN_NAME", string("Fledge Gift"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("GIFT"));
        // Opcional: CID de metadata (subí imagen antes con web/api/token-image o el /api/upload de Flap).
        // Sin CID el token sale sin arte; la pagina /create lo arma solo (avatar de github por defecto).
        string memory metaCid = vm.envOr("META_CID", string("{}"));
        address factory = vm.envOr("FACTORY", address(0));
        if (isWallet) require(recipient != address(0), "set RECIPIENT for wallet mode");

        (bytes32 salt, address predicted) = _mineSalt();
        console2.log("Predicted token (ends 7777):", predicted);

        bytes memory vaultData = abi.encode(idType, idValue, recipient, recoveryDays);

        vm.startBroadcast();

        if (factory == address(0)) {
            factory = address(new SocialFeeEscrowFactory(attester));
            console2.log("Factory deployed:", factory);
        } else {
            console2.log("Reusing factory:", factory);
        }

        IVaultPortalTypes.NewTokenV6WithVaultParams memory p;
        p.name = name;
        p.symbol = symbol;
        p.meta = metaCid;
        p.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        p.salt = salt;
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.quoteToken = address(0);
        p.quoteAmt = devBuy;
        p.permitData = "";
        p.extensionID = bytes32(0);
        p.extensionData = "";
        p.dexId = IPortalTypes.DEXId.DEX0;
        p.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3153600000;
        p.antiFarmerDuration = 259200;
        p.mktBps = 10000;
        p.deflationBps = 0;
        p.dividendBps = 0;
        p.lpBps = 0;
        p.minimumShareBalance = 0;
        p.dividendToken = address(0);
        p.commissionReceiver = address(0);
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.vaultFactory = factory;
        p.vaultData = vaultData;

        address token = IVaultPortal(RobinhoodAddresses.VAULT_PORTAL).newTokenV6WithVault{value: devBuy}(p);
        vm.stopBroadcast();

        require(token == predicted, "token != predicho");

        bytes32 idh = SocialFeeEscrowFactory(factory).identityHashFor(idType, idValue, recipient);
        address[] memory vaults = SocialFeeEscrowFactory(factory).getVaults(idh);
        address escrow = vaults[vaults.length - 1];

        console2.log("--------------------------------------------------");
        console2.log("TOKEN:", token);
        console2.log("ESCROW (las fees se acumulan aca):", escrow);
        console2.log("FACTORY (guardar para NEXT_PUBLIC_FACTORY_ADDRESS):", factory);
        console2.log("identity:", idType, idValue);
        console2.log("boundWallet (0x0 = falta claim; wallet-mode ya bindeado):", SocialFeeEscrow(payable(escrow)).boundWallet());
    }
}
