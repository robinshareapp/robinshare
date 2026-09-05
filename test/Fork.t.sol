// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {RobinhoodAddresses} from "../src/flap/RobinhoodAddresses.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

/// Corre SOLO con: forge test --match-contract ForkTest --fork-url robinhood -vvv
///
/// HALLAZGO (2026-07-10): el portal exige que el tax token termine en vanity 0x7777.
/// `predictTaxTokenV1Address` es el predictor EQUIVOCADO para la ruta V6.
/// El address real del tax token V6 se deriva:
///   CREATE2(deployer = Portal, salt = raw, initCodeHash = keccak(EIP1167 minimal-proxy(taxTokenV3Impl)))
/// initCodeHash verificado on-chain contra el revert InvalidVanity.
contract ForkTest is Test {
    uint256 constant ATTESTER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // keccak256 del bytecode del minimal-proxy (EIP-1167) que apunta a TAX_TOKEN_V3_IMPL (0x7777..3333)
    bytes32 constant TAX_PROXY_INITCODE_HASH =
        0x6ce33cede557fe3331031c87bf9be28f493a6086cdc8770ac0a4c7dd7320dea7;

    /// Predice el address del tax token V6 para un salt (misma derivacion que el portal).
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

    function _params(address factory, bytes32 salt, bytes memory vaultData)
        internal
        pure
        returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p)
    {
        p.name = "Fledge Pilot";
        p.symbol = "FLEDGE";
        p.meta = "{}";
        p.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        p.salt = salt;
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.quoteToken = address(0);
        p.quoteAmt = 0.01 ether;
        p.permitData = "";
        p.extensionID = bytes32(0);
        p.extensionData = "";
        p.dexId = IPortalTypes.DEXId.DEX0;
        p.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3153600000;
        p.antiFarmerDuration = 3 days;
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
    }

    function test_fork_launchEndToEnd() public {
        // Pre-audit propio (higiene de tests): antes esto era un early-return que forge reportaba
        // como [PASS] sin ejecutar nada (falso verde). vm.skip(true) lo reporta como "skipped",
        // honesto. Repro real: forge test --match-contract ForkTest --fork-url robinhood -vv
        vm.skip(block.chainid != 4663);

        address attester = vm.addr(ATTESTER_PK);
        SocialFeeEscrowFactory factory = new SocialFeeEscrowFactory(attester);
        bytes memory vaultData = abi.encode("github", "0x-keezy", address(0), uint256(0));
        address creator = makeAddr("pilot-creator");
        vm.deal(creator, 1 ether);

        (bytes32 salt, address predicted) = _mineSalt();
        console2.log("salt minado, token predicho (V6):", predicted);
        assertEq(uint256(uint160(predicted)) & 0xffff, 0x7777, "predicho debe terminar en 7777");

        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory), salt, vaultData);
        vm.prank(creator);
        try IVaultPortal(RobinhoodAddresses.VAULT_PORTAL).newTokenV6WithVault{value: p.quoteAmt}(p) returns (
            address token
        ) {
            console2.log("LAUNCH OK. token real:", token);
            assertEq(token, predicted, "token real debe igualar al predicho localmente");
            _afterLaunch(factory, token);
        } catch Error(string memory reason) {
            console2.log("Launch revirtio (string):", reason);
            fail();
        } catch (bytes memory raw) {
            console2.log("Launch revirtio (custom error). selector:");
            console2.logBytes(raw);
            fail();
        }
    }

    function _afterLaunch(SocialFeeEscrowFactory factory, address token) internal {
        bytes32 h = factory.identityHashFor("github", "0x-keezy", address(0));
        address[] memory vaults = factory.getVaults(h);
        assertEq(vaults.length, 1, "el escrow debe estar registrado");
        SocialFeeEscrow escrow = SocialFeeEscrow(payable(vaults[0]));
        assertEq(escrow.taxToken(), token, "el taxToken predicho debe coincidir con el token real");

        // description() y vaultUISchema() (categorias de la guia de integration test de Flap)
        string memory descBefore = escrow.description();
        assertGt(bytes(descBefore).length, 0, "description no vacia");
        VaultUISchema memory schema = escrow.vaultUISchema();
        assertEq(schema.vaultType, "SocialFeeEscrow");
        assertEq(schema.methods.length, 7, "7 metodos en el schema");

        // receive() bajo 1M de gas (Rule 005), en el estado real de RH
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(escrow).call{value: 0.3 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok);
        assertLe(gasUsed, 1_000_000, "receive() supera 1M de gas");
        assertEq(escrow.pendingAmount(), 0.3 ether);

        // claim github (voucher del attester) — libera al payout
        address payout = makeAddr("keezy-payout");
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, escrow.bindDigest(payout, deadline));
        escrow.claimAndBind(payout, deadline, abi.encodePacked(r, s, v));
        assertEq(payout.balance, 0.3 ether);
        assertEq(escrow.boundWallet(), payout);
        assertTrue(keccak256(bytes(escrow.description())) != keccak256(bytes(descBefore)), "description cambia con el estado");

        // fees nuevos post-bind se cobran con sweep (permissionless)
        (bool ok2,) = address(escrow).call{value: 0.1 ether}("");
        assertTrue(ok2);
        escrow.sweep();
        assertEq(payout.balance, 0.4 ether);
        console2.log("E2E fork OK: launch -> tax -> claim(github) -> sweep, + receive<1M + schema/description");
    }
}
