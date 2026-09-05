// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {IXGeneralVerifier} from "../src/flap/IXGeneralVerifier.sol";

/// Helper que fuerza el stipend de 2300 gas (semántica de transfer())
contract StipendSender {
    function send(address payable to) external payable {
        to.transfer(msg.value); // revierte si el receptor gasta >2300 gas
    }
}

contract SocialFeeEscrowTest is Test {
    // anvil key #0 — attester de los tests
    uint256 constant ATTESTER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address attesterAddr;
    address taxToken = address(0x7A11); // dirección predicha, sin código (a propósito)
    address creator = address(0xC0FFEE);

    function setUp() public {
        attesterAddr = vm.addr(ATTESTER_PK);
    }

    /// El test contract hace de fuente-de-attester (rol de la factory en produccion).
    function attester() external view returns (address) {
        return attesterAddr;
    }

    function _newGithub(uint64 recoveryAfter) internal returns (SocialFeeEscrow) {
        return new SocialFeeEscrow(taxToken, creator, 1, "torvalds", address(0), address(this), address(0), recoveryAfter);
    }

    function _sign(SocialFeeEscrow e, address payout, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, e.bindDigest(payout, deadline));
        return abi.encodePacked(r, s, v);
    }

    // ───────────────────────── Task 2: constructor + receive() ─────────────────────────

    function test_constructor_github_setsFields() public {
        SocialFeeEscrow e = _newGithub(0);
        assertEq(e.taxToken(), taxToken);
        assertEq(e.creator(), creator);
        assertEq(e.identityType(), 1);
        assertEq(e.identityValue(), "torvalds");
        assertEq(e.attester(), attesterAddr);
        assertEq(e.recoveryAfter(), 0);
        assertEq(e.boundWallet(), address(0));
        assertEq(e.bindNonce(), 0);
        assertEq(e.totalPaid(), 0);
    }

    function test_constructor_wallet_bindsImmediately() public {
        address person = address(0xBEEF);
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", person, address(0), address(0), 0);
        assertEq(e.boundWallet(), person);
        assertEq(e.identityType(), 0);
    }

    function test_constructor_wallet_zeroWallet_reverts() public {
        vm.expectRevert();
        new SocialFeeEscrow(taxToken, creator, 0, "", address(0), address(0), address(0), 0);
    }

    function test_constructor_social_zeroAttester_reverts() public {
        vm.expectRevert();
        new SocialFeeEscrow(taxToken, creator, 1, "torvalds", address(0), address(0), address(0), 0);
    }

    function test_constructor_badType_reverts() public {
        vm.expectRevert();
        new SocialFeeEscrow(taxToken, creator, 3, "x", address(0), address(this), address(0), 0);
    }

    /// INVARIANTE DURA: receive() nunca revierte, ni con stipend 2300.
    function test_receive_acceptsPlainCall() public {
        SocialFeeEscrow e = _newGithub(0);
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(e).balance, 1 ether);
    }

    function test_receive_acceptsWith2300Stipend() public {
        SocialFeeEscrow e = _newGithub(0);
        StipendSender s = new StipendSender();
        s.send{value: 0.5 ether}(payable(address(e))); // transfer() = 2300 gas
        assertEq(address(e).balance, 0.5 ether);
    }

    function testFuzz_receive_neverReverts(uint96 amount) public {
        SocialFeeEscrow e = _newGithub(0);
        vm.deal(address(this), amount);
        (bool ok,) = address(e).call{value: amount}("");
        assertTrue(ok);
    }

    /// @dev Rule 005 de Flap: receive() debe quedar bajo 1M de gas (guia de integration test).
    function testReceiveGasUnder1M() public {
        SocialFeeEscrow e = _newGithub(0);
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(e).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok);
        assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
    }

    // ───────────────────────── Task 3: bindDigest + claimAndBind ─────────────────────────

    function test_claimAndBind_paysAndBinds() public {
        SocialFeeEscrow e = _newGithub(0);
        (bool ok,) = address(e).call{value: 2 ether}("");
        assertTrue(ok);
        address payout = makeAddr("torvalds-wallet");
        uint256 deadline = block.timestamp + 15 minutes;

        vm.expectEmit(true, false, false, true, address(e));
        emit SocialFeeEscrow.Bound(payout, 0);
        e.claimAndBind(payout, deadline, _sign(e, payout, deadline));

        assertEq(e.boundWallet(), payout);
        assertEq(e.bindNonce(), 1);
        assertEq(payout.balance, 2 ether);
        assertEq(address(e).balance, 0);
        assertEq(e.totalPaid(), 2 ether);
    }

    function test_claimAndBind_zeroBalance_bindsWithoutPaying() public {
        SocialFeeEscrow e = _newGithub(0);
        address payout = makeAddr("early-bird");
        uint256 deadline = block.timestamp + 15 minutes;
        e.claimAndBind(payout, deadline, _sign(e, payout, deadline)); // no revierte
        assertEq(e.boundWallet(), payout);
        assertEq(e.totalPaid(), 0);
    }

    function test_pendingAmount_tracksBalance() public {
        SocialFeeEscrow e = _newGithub(0);
        assertEq(e.pendingAmount(), 0);
        (bool ok,) = address(e).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(e.pendingAmount(), 3 ether);
    }

    // ───────────────────────── Task 4: matriz adversarial + re-bind ─────────────────────────

    function test_claim_wrongSigner_reverts() public {
        SocialFeeEscrow e = _newGithub(0);
        uint256 deadline = block.timestamp + 15 minutes;
        address payout = makeAddr("p");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, e.bindDigest(payout, deadline)); // otra key
        vm.expectRevert(bytes(unicode"bad attester signature / 认证签名无效"));
        e.claimAndBind(payout, deadline, abi.encodePacked(r, s, v));
    }

    function test_claim_expired_reverts() public {
        SocialFeeEscrow e = _newGithub(0);
        uint256 deadline = block.timestamp + 1;
        address payout = makeAddr("p");
        bytes memory sig = _sign(e, payout, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(bytes(unicode"voucher expired / 凭证已过期"));
        e.claimAndBind(payout, deadline, sig);
    }

    function test_claim_replay_reverts() public {
        SocialFeeEscrow e = _newGithub(0);
        address payout = makeAddr("p");
        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory sig = _sign(e, payout, deadline);
        e.claimAndBind(payout, deadline, sig);
        // mismo voucher otra vez: el nonce ya avanzo -> digest distinto -> firma invalida
        vm.expectRevert(bytes(unicode"bad attester signature / 认证签名无效"));
        e.claimAndBind(payout, deadline, sig);
    }

    function test_claim_voucherDeOtroVault_reverts() public {
        SocialFeeEscrow e1 = _newGithub(0);
        SocialFeeEscrow e2 = _newGithub(0);
        address payout = makeAddr("p");
        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory sigParaE1 = _sign(e1, payout, deadline);
        vm.expectRevert(bytes(unicode"bad attester signature / 认证签名无效"));
        e2.claimAndBind(payout, deadline, sigParaE1); // verifyingContract distinto
    }

    function test_claim_zeroPayout_reverts() public {
        SocialFeeEscrow e = _newGithub(0);
        uint256 deadline = block.timestamp + 15 minutes;
        vm.expectRevert(bytes(unicode"zero payout / 收款地址为空"));
        e.claimAndBind(address(0), deadline, hex"00");
    }

    function test_claim_onWalletType_reverts() public {
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", makeAddr("w"), address(0), address(0), 0);
        vm.expectRevert(bytes(unicode"github identity only / 仅限 github 身份"));
        e.claimAndBind(makeAddr("p"), block.timestamp + 1, hex"00");
    }

    function test_rebind_conVoucherFresco() public {
        SocialFeeEscrow e = _newGithub(0);
        address w1 = makeAddr("w1");
        address w2 = makeAddr("w2");
        uint256 deadline = block.timestamp + 15 minutes;
        e.claimAndBind(w1, deadline, _sign(e, w1, deadline)); // nonce 0 -> 1
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        e.claimAndBind(w2, deadline, _sign(e, w2, deadline)); // _sign lee bindNonce()=1
        assertEq(e.boundWallet(), w2);
        assertEq(w2.balance, 1 ether);
    }

    // ───────────────────────── Task 5: sweep + reentrancia inocua ─────────────────────────

    function test_sweep_walletType_pagaDirecto() public {
        address person = makeAddr("person");
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", person, address(0), address(0), 0);
        (bool ok,) = address(e).call{value: 1.5 ether}("");
        assertTrue(ok);
        vm.prank(makeAddr("cualquiera")); // permissionless
        e.sweep();
        assertEq(person.balance, 1.5 ether);
        assertEq(e.totalPaid(), 1.5 ether);
    }

    function test_sweep_sinBind_reverts() public {
        SocialFeeEscrow e = _newGithub(0);
        vm.expectRevert(bytes(unicode"not bound yet / 尚未绑定"));
        e.sweep();
    }

    function test_sweep_sinBalance_reverts() public {
        address person = makeAddr("person");
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", person, address(0), address(0), 0);
        vm.expectRevert(bytes(unicode"nothing to sweep / 无可领取余额"));
        e.sweep();
    }

    function test_sweep_receptorReentrante_esInocuo() public {
        ReentrantPayout payout = new ReentrantPayout();
        SocialFeeEscrow e = _newGithub(0);
        uint256 deadline = block.timestamp + 15 minutes;
        e.claimAndBind(address(payout), deadline, _sign(e, address(payout), deadline));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        payout.setTarget(e);
        e.sweep(); // el reentrante intenta sweep() anidado; debe fallar el anidado sin robar
        assertEq(address(payout).balance, 1 ether); // cobro exactamente una vez
    }

    // ───────────────────────── Task 6: recoverUnclaimed ─────────────────────────

    function test_recover_deshabilitado_reverts() public {
        SocialFeeEscrow e = _newGithub(0); // recoveryAfter = 0
        vm.prank(creator);
        vm.expectRevert(bytes(unicode"recovery disabled / 回收未启用"));
        e.recoverUnclaimed(creator);
    }

    function test_recover_antesDeTiempo_reverts() public {
        SocialFeeEscrow e = _newGithub(uint64(block.timestamp + 30 days));
        vm.prank(creator);
        vm.expectRevert(bytes(unicode"too early / 未到回收时间"));
        e.recoverUnclaimed(creator);
    }

    function test_recover_despuesDeBind_reverts() public {
        SocialFeeEscrow e = _newGithub(uint64(block.timestamp + 30 days));
        address payout = makeAddr("p");
        uint256 deadline = block.timestamp + 15 minutes;
        e.claimAndBind(payout, deadline, _sign(e, payout, deadline));
        vm.warp(block.timestamp + 31 days);
        vm.prank(creator);
        vm.expectRevert(bytes(unicode"already bound / 已绑定"));
        e.recoverUnclaimed(creator); // una vez bound, JAMAS recuperable por el creator
    }

    function test_recover_happyPath() public {
        SocialFeeEscrow e = _newGithub(uint64(block.timestamp + 30 days));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        vm.warp(block.timestamp + 30 days);
        vm.prank(creator);
        e.recoverUnclaimed(creator); // creator-gated con destino elegible (fix preaudit)
        assertEq(creator.balance, 1 ether);
        assertEq(e.totalPaid(), 1 ether);
    }

    // ───────────────────────── Task 7: description + vaultUISchema ─────────────────────────

    function test_description_reflejaEstado() public {
        SocialFeeEscrow e = _newGithub(0);
        assertTrue(bytes(e.description()).length > 20);
        // pre-bind: menciona la identidad
        assertTrue(_contains(e.description(), "github:torvalds"));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        assertTrue(_contains(e.description(), "1.000")); // 1 ether formateado
    }

    /// Pre-audit propio (doc-vs-code): el schema paso de 4 a 7 metodos (agrega claimByProof y
    /// recoverUnclaimed, que antes violaban el mandate de VaultBaseV2 por quedar sin documentar).
    function test_vaultUISchema_tieneMetodos() public {
        SocialFeeEscrow e = _newGithub(0);
        VaultUISchema memory s = e.vaultUISchema();
        assertEq(s.vaultType, "SocialFeeEscrow");
        assertEq(s.methods.length, 7);
        assertEq(s.methods[0].name, "claimAndBind");
        assertTrue(s.methods[0].isWriteMethod);
        assertEq(s.methods[0].inputs.length, 3);
        assertEq(s.methods[1].name, "claimByProof");
        assertTrue(s.methods[1].isWriteMethod);
        assertEq(s.methods[2].name, "rebindWallet");
        assertEq(s.methods[3].name, "sweep");
        assertEq(s.methods[4].name, "recoverUnclaimed");
        assertTrue(s.methods[4].isWriteMethod);
        assertEq(s.methods[5].name, "pendingAmount");
        assertEq(s.methods[5].outputs[0].decimals, 18);
        assertEq(s.methods[6].name, "boundWallet");
        assertFalse(s.methods[6].isWriteMethod);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
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

    // ───────────────────────── Ruta TWITTER: claimByProof (XGeneralVerifier de Flap) ─────────────────────────

    function _newTwitter(address verifier) internal returns (SocialFeeEscrow) {
        return new SocialFeeEscrow(taxToken, creator, 2, "0xkeezy", address(0), address(0), verifier, 0);
    }

    function _xproof(SocialFeeEscrow e, address payout, string memory handle, uint128 tweetId)
        internal
        view
        returns (IXGeneralVerifier.XGeneralProof memory)
    {
        return IXGeneralVerifier.XGeneralProof({
            tweetId: tweetId,
            xHandle: handle,
            xId: 1,
            substring: e.expectedTweet(payout)
        });
    }

    // NOTA: siempre construir la prueba (_xproof llama e.expectedTweet, una call externa) ANTES
    // de vm.prank/vm.expectRevert, o el cheat se aplica a expectedTweet y no a claimByProof.

    function test_claimByProof_happyPath() public {
        MockXVerifier v = new MockXVerifier();
        SocialFeeEscrow e = _newTwitter(address(v));
        (bool ok,) = address(e).call{value: 2 ether}("");
        assertTrue(ok);
        address payout = makeAddr("keezy-wallet");
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, payout, "0xkeezy", 100);

        vm.prank(payout);
        e.claimByProof(p, hex"aa");

        assertEq(e.boundWallet(), payout);
        assertEq(payout.balance, 2 ether);
        assertEq(e.pendingAmount(), 0);
        assertEq(e.lastTweetId(), 100);
    }

    function test_claimByProof_wrongHandle_reverts() public {
        MockXVerifier v = new MockXVerifier();
        SocialFeeEscrow e = _newTwitter(address(v));
        address payout = makeAddr("p");
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, payout, "impostor", 100);
        vm.prank(payout);
        vm.expectRevert(bytes(unicode"wrong x handle / X 账号不符"));
        e.claimByProof(p, hex"aa");
    }

    function test_claimByProof_wrongSubstring_reverts() public {
        MockXVerifier v = new MockXVerifier();
        SocialFeeEscrow e = _newTwitter(address(v));
        address payout = makeAddr("p");
        // substring armado para OTRA address -> no matchea expectedTweet(msg.sender)
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, makeAddr("otro"), "0xkeezy", 100);
        vm.prank(payout);
        vm.expectRevert(bytes(unicode"substring mismatch / substring 不匹配"));
        e.claimByProof(p, hex"aa");
    }

    function test_claimByProof_badSignature_reverts() public {
        MockXVerifier v = new MockXVerifier();
        v.setResult(false); // el oráculo rechaza
        SocialFeeEscrow e = _newTwitter(address(v));
        address payout = makeAddr("p");
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, payout, "0xkeezy", 100);
        vm.prank(payout);
        vm.expectRevert(bytes(unicode"invalid proof / 证明无效"));
        e.claimByProof(p, hex"aa");
    }

    function test_claimByProof_replay_reverts() public {
        MockXVerifier v = new MockXVerifier();
        SocialFeeEscrow e = _newTwitter(address(v));
        address payout = makeAddr("p");
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, payout, "0xkeezy", 100);
        vm.prank(payout);
        e.claimByProof(p, hex"aa");
        // mismo (o menor) tweetId -> outdated
        vm.prank(payout);
        vm.expectRevert(bytes(unicode"outdated proof / 证明已过期"));
        e.claimByProof(p, hex"aa");
    }

    function test_claimByProof_onGithubType_reverts() public {
        SocialFeeEscrow e = _newGithub(0); // github
        address payout = makeAddr("p");
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, payout, "torvalds", 100);
        vm.prank(payout);
        vm.expectRevert(bytes(unicode"twitter identity only / 仅限 twitter 身份"));
        e.claimByProof(p, hex"aa");
    }

    function test_claimByProof_noVerifierOnChain_reverts() public {
        SocialFeeEscrow e = _newTwitter(address(0)); // xVerifier 0 = Flap aun no lo desplego aca
        address payout = makeAddr("p");
        IXGeneralVerifier.XGeneralProof memory p = _xproof(e, payout, "0xkeezy", 100);
        vm.prank(payout);
        vm.expectRevert(bytes(unicode"x verifier not on this chain yet / 本链暂无 X 验证器"));
        e.claimByProof(p, hex"aa");
    }

    function test_expectedHandle_devuelveElFondeado() public {
        SocialFeeEscrow e = _newTwitter(makeAddr("v"));
        assertEq(e.expectedHandle(makeAddr("anyone")), "0xkeezy");
    }
}

contract MockXVerifier is IXGeneralVerifier {
    bool public result = true;

    function setResult(bool r) external {
        result = r;
    }

    function verify(IXGeneralVerifier.XGeneralProof calldata, bytes calldata) external view returns (bool) {
        return result;
    }

    function oracleKey() external pure returns (address) {
        return address(0);
    }
}

contract ReentrantPayout {
    SocialFeeEscrow target;

    function setTarget(SocialFeeEscrow t) external {
        target = t;
    }

    receive() external payable {
        if (address(target) != address(0) && address(target).balance > 0) {
            try target.sweep() {} catch {} // el anidado ve balance 0 y revierte; lo tragamos
        }
    }
}
