// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";
import {VaultUISchema, VaultDataSchema, FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol";
import {IXGeneralVerifier} from "../src/flap/IXGeneralVerifier.sol";

/// Tests de los 6 fixes del audit v3 de GT (reporte f70e5476, 2026-07-16).
/// Un bloque por finding; cada uno nacio RED contra el codigo pre-fix v3.
contract AuditFixesV3Test is Test {
    address creator = makeAddr("creator");
    address attesterAddr = makeAddr("attester");
    address predictedToken = address(0x7777);

    address constant RH_PORTAL = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B; // VaultPortal Robinhood (4663)
    address constant RH_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000; // Guardian oficial RH

    function setUp() public {
        vm.chainId(4663);
    }

    /// El test contract hace de fuente-de-attester (rol de la factory) para vaults directos.
    function attester() external view returns (address) {
        return attesterAddr;
    }

    function _data(string memory t, string memory v, address w, uint256 days_) internal pure returns (bytes memory) {
        return abi.encode(t, v, w, days_);
    }

    function _freshFactory() internal returns (SocialFeeEscrowFactory) {
        return new SocialFeeEscrowFactory(attesterAddr);
    }

    function _newGithub(uint64 recoveryAfter) internal returns (SocialFeeEscrow) {
        return
            new SocialFeeEscrow(predictedToken, creator, 1, "torvalds", address(0), address(this), address(0), recoveryAfter);
    }

    // ───────────────────────── F1 (High): revert() suelto en _parseType ─────────────────────────

    function test_F1_parseType_tipoInvalido_usaFormaRequire() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        vm.expectRevert(bytes(unicode"identity type must be wallet|github|twitter / 身份类型无效"));
        f.newVault(predictedToken, address(0), creator, _data("foo", "x", address(0), 0));
    }

    // ───────────────────────── F2 (High): views bilingues ─────────────────────────

    function test_F2_description_esBilingue() public {
        SocialFeeEscrow e = _newGithub(0);
        string memory d = e.description();
        assertTrue(_contains(d, " / "), "falta separador bilingue en description()");
        assertTrue(_containsChinese(d), "falta caracter chino en description()");
    }

    function test_F2_vaultUISchema_esBilingue() public {
        SocialFeeEscrow e = _newGithub(0);
        VaultUISchema memory s = e.vaultUISchema();
        assertTrue(_contains(s.description, " / "));
        assertTrue(_containsChinese(s.description));
        for (uint256 i = 0; i < s.methods.length; i++) {
            assertTrue(_contains(s.methods[i].description, " / "), "method description sin separador");
            assertTrue(_containsChinese(s.methods[i].description), "method description sin chino");
            for (uint256 j = 0; j < s.methods[i].inputs.length; j++) {
                assertTrue(_containsChinese(s.methods[i].inputs[j].description), "input description sin chino");
            }
            for (uint256 j = 0; j < s.methods[i].outputs.length; j++) {
                assertTrue(_containsChinese(s.methods[i].outputs[j].description), "output description sin chino");
            }
        }
    }

    function test_F2_factorySchemas_sonBilingues() public {
        SocialFeeEscrowFactory f = _freshFactory();
        VaultDataSchema memory s = f.vaultDataSchema();
        assertTrue(_containsChinese(s.description), "vaultDataSchema description sin chino");
        for (uint256 i = 0; i < s.fields.length; i++) {
            assertTrue(_containsChinese(s.fields[i].description), "campo del schema sin chino");
        }
        FactoryPolicy[] memory p = f.tokenCreationPolicies();
        for (uint256 i = 0; i < p.length; i++) {
            assertTrue(_containsChinese(p[i].description), "policy sin chino");
        }
    }

    // ───────────────────────── F3 (High): recoveryDays con piso de 30 dias ─────────────────────────

    function test_F3_recoveryDays_menorA30_reverts() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        vm.expectRevert(bytes(unicode"recovery window too short / 回收期过短"));
        f.newVault(predictedToken, address(0), creator, _data("github", "a", address(0), 1));
    }

    function test_F3_recoveryDays_cero_siempreOk() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        address v = f.newVault(predictedToken, address(0), creator, _data("github", "a", address(0), 0));
        assertEq(SocialFeeEscrow(payable(v)).recoveryAfter(), 0);
    }

    function test_F3_recoveryDays_treinta_ok() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        address v = f.newVault(predictedToken, address(0), creator, _data("github", "b", address(0), 30));
        assertGt(SocialFeeEscrow(payable(v)).recoveryAfter(), 0);
    }

    function test_F3_recoveryDays_treintaCincuenta_ok() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        address v = f.newVault(predictedToken, address(0), creator, _data("github", "c", address(0), 3650));
        assertGt(SocialFeeEscrow(payable(v)).recoveryAfter(), 0);
    }

    function test_F3_recoveryDays_masDelMax_reverts() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        vm.expectRevert(bytes(unicode"recovery too long / 回收期过长"));
        f.newVault(predictedToken, address(0), creator, _data("github", "d", address(0), 3651));
    }

    // ───────────────────────── F4 (High): forward-switch del Guardian en receive() ─────────────────────────

    function test_F4_receive_sinSwitch_acumulaNormal() public {
        SocialFeeEscrow e = _newGithub(0);
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(e).balance, 1 ether);
        assertFalse(e.rescueForward());
        assertEq(e.rescueTo(), address(0));
    }

    function test_F4_guardian_activaForward_ySeForwardea() public {
        SocialFeeEscrow e = _newGithub(0);
        address rescue = makeAddr("rescue");

        vm.prank(RH_GUARDIAN);
        vm.expectEmit(false, false, false, true, address(e));
        emit SocialFeeEscrow.RescueForwardSet(true, rescue);
        e.setRescueForward(true, rescue);
        assertTrue(e.rescueForward());
        assertEq(e.rescueTo(), rescue);

        vm.expectEmit(true, false, false, true, address(e));
        emit SocialFeeEscrow.Forwarded(rescue, 1 ether);
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(e).balance, 0, "el vault debe quedar en 0 tras el forward");
        assertEq(rescue.balance, 1 ether);
    }

    function test_F4_forwardATargetQueRevierte_receiveNuncaRevierte() public {
        SocialFeeEscrow e = _newGithub(0);
        RevertingReceiverV3 bad = new RevertingReceiverV3();
        vm.prank(RH_GUARDIAN);
        e.setRescueForward(true, address(bad));

        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok, "receive() jamas debe revertir aunque el forward falle");
        assertEq(address(e).balance, 1 ether, "el ETH queda en el vault, rescatable via emergencyWithdrawNative");
        assertEq(address(bad).balance, 0);
    }

    function test_F4_setRescueForward_soloGuardian() public {
        SocialFeeEscrow e = _newGithub(0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes(unicode"only guardian / 仅限 Guardian"));
        e.setRescueForward(true, makeAddr("rescue"));
    }

    function test_F4_setRescueForward_onSinDestino_reverts() public {
        SocialFeeEscrow e = _newGithub(0);
        vm.prank(RH_GUARDIAN);
        vm.expectRevert(bytes(unicode"zero rescue target / 救援地址为空"));
        e.setRescueForward(true, address(0));
    }

    function test_F4_receiveConForward_gasBajo1M() public {
        SocialFeeEscrow e = _newGithub(0);
        address rescue = makeAddr("rescue");
        vm.prank(RH_GUARDIAN);
        e.setRescueForward(true, rescue);
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(e).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok);
        assertLe(gasUsed, 1_000_000, "receive() con forward supera 1M de gas");
    }

    // ───────────────────────── F5 (High): Guardian puede rotar el attester ─────────────────────────

    function test_F5_guardian_puedeRotarAttester() public {
        SocialFeeEscrowFactory f = _freshFactory();
        address newAttester = makeAddr("nuevo-attester");
        vm.prank(RH_GUARDIAN);
        f.rotateAttester(newAttester);
        assertEq(f.attester(), newAttester);
    }

    function test_F5_attesterVigente_siguePudiendoRotar() public {
        SocialFeeEscrowFactory f = _freshFactory();
        address newAttester = makeAddr("nuevo-attester");
        vm.prank(attesterAddr);
        f.rotateAttester(newAttester);
        assertEq(f.attester(), newAttester);
    }

    function test_F5_randomAddress_noPuedeRotar() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(makeAddr("random"));
        vm.expectRevert(bytes(unicode"only attester or guardian / 仅限认证者或 Guardian"));
        f.rotateAttester(makeAddr("random"));
    }

    function test_F5_rotarPorGuardian_vaultsLeenElNuevoEnVivo() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(RH_PORTAL);
        address vAddr = f.newVault(predictedToken, address(0), creator, _data("github", "torvalds", address(0), 0));
        SocialFeeEscrow v = SocialFeeEscrow(payable(vAddr));
        address newAttester = makeAddr("nuevo-attester");
        vm.prank(RH_GUARDIAN);
        f.rotateAttester(newAttester);
        assertEq(v.attester(), newAttester);
    }

    // ───────────────────────── F6 (Low): replay de twitter GLOBAL (no por-claimer) ─────────────────────────

    function _newTwitter(address verifier) internal returns (SocialFeeEscrow) {
        return new SocialFeeEscrow(predictedToken, creator, 2, "0xkeezy", address(0), address(0), verifier, 0);
    }

    function _xproof(SocialFeeEscrow e, address payout, string memory handle, uint128 tweetId)
        internal
        view
        returns (IXGeneralVerifier.XGeneralProof memory)
    {
        return IXGeneralVerifier.XGeneralProof({tweetId: tweetId, xHandle: handle, xId: 1, substring: e.expectedTweet(payout)});
    }

    /// El escenario exacto del finding: B rebindea con un tweet mas nuevo (T2>T1); A intenta
    /// reclamar despues con su viejo T1 (aun oracle-valido) y debe fallar — el guard es GLOBAL.
    function test_F6_replayGlobal_walletViejaNoPuedeRobarTrasRebindMasNuevo() public {
        MockXVerifierV3 verifier = new MockXVerifierV3();
        SocialFeeEscrow e = _newTwitter(address(verifier));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);

        address walletA = makeAddr("wallet-A");
        address walletB = makeAddr("wallet-B");

        IXGeneralVerifier.XGeneralProof memory proofA = _xproof(e, walletA, "0xkeezy", 100);
        vm.prank(walletA);
        e.claimByProof(proofA, hex"aa");
        assertEq(e.boundWallet(), walletA);
        assertEq(walletA.balance, 1 ether);

        (bool ok2,) = address(e).call{value: 2 ether}("");
        assertTrue(ok2);

        // tweet MAS NUEVO nombra a B (T2 > T1); B reclama y rebindea
        IXGeneralVerifier.XGeneralProof memory proofB = _xproof(e, walletB, "0xkeezy", 200);
        vm.prank(walletB);
        e.claimByProof(proofB, hex"aa");
        assertEq(e.boundWallet(), walletB);
        assertEq(walletB.balance, 2 ether);

        (bool ok3,) = address(e).call{value: 0.5 ether}("");
        assertTrue(ok3);

        // A intenta reclamar con su viejo T1 (proof aun oracle-valido, pero superado por T2) -> FALLA
        IXGeneralVerifier.XGeneralProof memory proofAOld = _xproof(e, walletA, "0xkeezy", 100);
        vm.prank(walletA);
        vm.expectRevert(bytes(unicode"outdated proof / 证明已过期"));
        e.claimByProof(proofAOld, hex"aa");

        assertEq(address(e).balance, 0.5 ether, "los 0.5 ETH de B no deben desviarse");
        assertEq(e.boundWallet(), walletB);
    }

    /// Un tweetId estrictamente mayor sigue habilitando el re-bind legitimo (comportamiento sano).
    function test_F6_replayGlobal_tweetIdCrecienteSigueFuncionandoParaRebind() public {
        MockXVerifierV3 verifier = new MockXVerifierV3();
        SocialFeeEscrow e = _newTwitter(address(verifier));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        address walletA = makeAddr("wallet-A");
        IXGeneralVerifier.XGeneralProof memory proofA = _xproof(e, walletA, "0xkeezy", 50);
        vm.prank(walletA);
        e.claimByProof(proofA, hex"aa");
        assertEq(e.lastTweetId(), 50);

        (bool ok2,) = address(e).call{value: 1 ether}("");
        assertTrue(ok2);
        address walletC = makeAddr("wallet-C");
        IXGeneralVerifier.XGeneralProof memory proofC = _xproof(e, walletC, "0xkeezy", 999);
        vm.prank(walletC);
        e.claimByProof(proofC, hex"aa");
        assertEq(e.boundWallet(), walletC);
        assertEq(walletC.balance, 1 ether);
        assertEq(e.lastTweetId(), 999);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }

    /// Heuristica UTF-8: cualquier byte >= 0xE0 arranca un caracter multibyte de 3 bytes (rango CJK).
    function _containsChinese(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (uint8(b[i]) >= 0xE0) return true;
        }
        return false;
    }
}

contract RevertingReceiverV3 {
    receive() external payable {
        revert("nope");
    }
}

contract MockXVerifierV3 is IXGeneralVerifier {
    function verify(IXGeneralVerifier.XGeneralProof calldata, bytes calldata) external pure returns (bool) {
        return true;
    }

    function oracleKey() external pure returns (address) {
        return address(0);
    }
}
