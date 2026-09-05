// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";

/// Tests de los fixes del preaudit de Flap (2026-07-15, David Zhang + audithelper).
/// Un bloque por finding; cada uno nacio RED contra el codigo pre-fix.
contract AuditFixesTest is Test {
    address creator = makeAddr("creator");
    address attesterAddr = makeAddr("attester");
    address predictedToken = address(0x7777);

    address constant BSC_X_VERIFIER = 0xcA8DBE6CAC4BFDc41226b0BaF2359fd99989b3E4;
    address constant RH_X_VERIFIER = 0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17; // XGeneralVerifier Robinhood (4663)
    address constant RH_PORTAL = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B; // VaultPortal Robinhood (4663)
    address constant BSC_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // VaultPortal BSC (56)
    address constant BSC_TESTNET_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f; // VaultPortal BSC Testnet (97)

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

    // ───────── Preaudit High #2: vaults twitter brickeados sin XGeneralVerifier ─────────

    /// Post-v3: Robinhood (4663) YA tiene el XGeneralVerifier oficial de Flap desplegado y
    /// verificado (ver test_xVerifier_robinhood_*), asi que el escenario "sin verifier" ya no
    /// ocurre ahi. Lo probamos en BSC Testnet (97, chain soportada por _getVaultPortal pero sin
    /// entrada en _getXVerifier) para preservar la cobertura del gate anti-brickeo.
    function test_twitter_sinVerifier_rechazadoAlCrear() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(97);
        vm.prank(BSC_TESTNET_PORTAL);
        vm.expectRevert(bytes(unicode"x verifier not deployed on this chain / 本链暂无 X 验证器"));
        f.newVault(predictedToken, address(0), creator, _data("twitter", "someone", address(0), 0));
    }

    /// El charset invalido sigue reventando ANTES que el check del verifier (mismo orden de errores),
    /// sin importar si la chain tiene o no verifier — mismo motivo, se prueba en 97.
    function test_twitter_sinVerifier_charsetRevientaPrimero() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(97);
        vm.prank(BSC_TESTNET_PORTAL);
        vm.expectRevert(bytes(unicode"bad handle charset / 句柄包含非法字符"));
        f.newVault(predictedToken, address(0), creator, _data("twitter", "bad-handle", address(0), 0));
    }

    /// En BSC (verifier vivo) la creacion twitter sigue funcionando y el vault lo hereda.
    function test_twitter_conVerifier_creaEnBSC() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(56);
        vm.prank(BSC_PORTAL);
        address v = f.newVault(predictedToken, address(0), creator, _data("twitter", "@0xKeezy", address(0), 0));
        assertEq(SocialFeeEscrow(payable(v)).xVerifier(), BSC_X_VERIFIER);
    }

    // ───────── Post-v3: XGeneralVerifier oficial de Flap desplegado en Robinhood (4663) ─────────

    /// Flap desplego su XGeneralVerifier oficial en Robinhood Chain y Jose lo verifico
    /// on-chain (2026-07-16): la factory ahora debe devolverlo para 4663, no address(0).
    function test_xVerifier_robinhood_devuelveLaDireccionOficial() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(4663);
        assertEq(f.xVerifier(), RH_X_VERIFIER);
    }

    /// El cableo de Robinhood no debe pisar el de BSC (56), que sigue siendo el suyo.
    function test_xVerifier_bsc_sigueSiendoElDeBSC() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(56);
        assertEq(f.xVerifier(), BSC_X_VERIFIER);
    }

    /// Con el verifier oficial ya cableado, la ruta twitter deja de estar bloqueada en
    /// Robinhood: la factory crea el vault y este bakea el verifier oficial como immutable.
    function test_twitterVault_enRobinhood_bakeaElVerifier() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(4663);
        vm.prank(RH_PORTAL);
        address v = f.newVault(predictedToken, address(0), creator, _data("twitter", "@0xKeezy", address(0), 0));
        assertEq(SocialFeeEscrow(payable(v)).xVerifier(), RH_X_VERIFIER);
    }

    // ───────── Preaudit Critical: TYPE_WALLET sin recovery si la wallet no recibe ETH ─────────

    function _newWalletVault(address identityWallet_) internal returns (SocialFeeEscrow) {
        return new SocialFeeEscrow(predictedToken, creator, 0, "", identityWallet_, address(0), address(0), 0);
    }

    /// El escenario exacto del preaudit: la identidad es un contrato sin receive() (multisig mal
    /// configurado). sweep() revierte siempre — pero la identidad PUEDE ejecutar calls, asi que
    /// se auto-rescata rotando la wallet de cobro a una EOA.
    function test_rebindWallet_rescataWalletRota() public {
        BrokenReceiver broken = new BrokenReceiver();
        SocialFeeEscrow e = _newWalletVault(address(broken));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);

        vm.expectRevert(bytes(unicode"payout failed / 支付失败"));
        e.sweep(); // el destino no puede recibir ETH

        address rescue = makeAddr("rescue");
        broken.doRebind(e, rescue); // la IDENTIDAD rota su payout
        assertEq(e.identityWallet(), address(broken)); // la identidad original no muta
        assertEq(e.boundWallet(), rescue);

        e.sweep();
        assertEq(rescue.balance, 1 ether);
    }

    function test_rebindWallet_soloLaIdentidad() public {
        SocialFeeEscrow e = _newWalletVault(makeAddr("person"));
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes(unicode"only identity wallet / 仅限身份钱包"));
        e.rebindWallet(makeAddr("attacker"));
    }

    function test_rebindWallet_soloTipoWallet() public {
        SocialFeeEscrow e =
            new SocialFeeEscrow(predictedToken, creator, 1, "torvalds", address(0), address(this), address(0), 0);
        vm.expectRevert(bytes(unicode"wallet identity only / 仅限 wallet 身份"));
        e.rebindWallet(makeAddr("x"));
    }

    function test_rebindWallet_zeroPayout_reverts() public {
        address person = makeAddr("person");
        SocialFeeEscrow e = _newWalletVault(person);
        vm.prank(person);
        vm.expectRevert(bytes(unicode"zero payout / 收款地址为空"));
        e.rebindWallet(address(0));
    }

    // ───────── Preaudit High: recoverUnclaimed push-only al creator (posible lock) ─────────

    function _newGithubRecoverable() internal returns (SocialFeeEscrow) {
        SocialFeeEscrow e = new SocialFeeEscrow(
            predictedToken, creator, 1, "torvalds", address(0), address(this), address(0), uint64(block.timestamp + 30 days)
        );
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        vm.warp(block.timestamp + 30 days);
        return e;
    }

    /// El creator elige el destino: si SU address resulto ser un contrato que no recibe ETH,
    /// recupera hacia una wallet que si pueda (cierra el lock del preaudit).
    function test_recover_conDestinoElegible() public {
        SocialFeeEscrow e = _newGithubRecoverable();
        address cold = makeAddr("cold");
        vm.prank(creator);
        e.recoverUnclaimed(cold);
        assertEq(cold.balance, 1 ether);
        assertEq(e.totalPaid(), 1 ether);
    }

    /// Con destino elegible la funcion deja de ser permissionless: solo el creator decide adonde.
    function test_recover_soloCreator() public {
        SocialFeeEscrow e = _newGithubRecoverable();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes(unicode"only creator / 仅限创建者"));
        e.recoverUnclaimed(makeAddr("attacker"));
    }

    function test_recover_zeroDestino_reverts() public {
        SocialFeeEscrow e = _newGithubRecoverable();
        vm.prank(creator);
        vm.expectRevert(bytes(unicode"zero recipient / 接收地址为空"));
        e.recoverUnclaimed(address(0));
    }

    // ───────── Option A del auditor (decision de producto de Jose): hatch del Guardian ─────────

    address constant RH_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;

    /// El Guardian oficial de Flap (per-chain, heredado de VaultBase) puede rescatar el balance
    /// hacia una address elegida — el "que pasa si TODO lo demas fallo" que pidio el preaudit.
    function test_emergencyWithdraw_guardianRescata() public {
        SocialFeeEscrow e = _newWalletVault(makeAddr("person"));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        vm.chainId(4663);
        address rescue = makeAddr("rescue");
        vm.prank(RH_GUARDIAN);
        e.emergencyWithdrawNative(rescue);
        assertEq(rescue.balance, 1 ether);
        assertEq(e.totalPaid(), 0); // NO es un payout de identidad: no ensucia la contabilidad
    }

    function test_emergencyWithdraw_soloGuardian() public {
        SocialFeeEscrow e = _newWalletVault(makeAddr("person"));
        vm.chainId(4663);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        e.emergencyWithdrawNative(makeAddr("attacker"));
    }

    function test_emergencyWithdraw_zeroTo_reverts() public {
        SocialFeeEscrow e = _newWalletVault(makeAddr("person"));
        vm.chainId(4663);
        vm.prank(RH_GUARDIAN);
        vm.expectRevert(bytes(unicode"zero recipient / 接收地址为空"));
        e.emergencyWithdrawNative(address(0));
    }

    // ───────── Preaudit High #1 (obligatorio): gate del VaultPortal hardcodeado ─────────

    /// El gate ya no es un constructor param: sale de _getVaultPortal() (per-chain, heredado
    /// de VaultFactoryBaseV2). Un deploy equivocado NO puede apuntar el gate a otra address.
    function test_portalGate_esElHardcodeadoDeLaChain() public {
        vm.chainId(4663);
        SocialFeeEscrowFactory f = new SocialFeeEscrowFactory(attesterAddr);
        assertEq(f.vaultPortal(), RH_PORTAL);
        vm.prank(RH_PORTAL);
        address v = f.newVault(predictedToken, address(0), creator, _data("github", "torvalds", address(0), 0));
        assertEq(SocialFeeEscrow(payable(v)).attester(), attesterAddr);
    }

    function test_portalGate_rechazaCualquierOtroCaller() public {
        vm.chainId(4663);
        SocialFeeEscrowFactory f = new SocialFeeEscrowFactory(attesterAddr);
        vm.prank(makeAddr("would-be portal"));
        vm.expectRevert(bytes(unicode"only vault portal / 仅限 VaultPortal"));
        f.newVault(predictedToken, address(0), creator, _data("github", "torvalds", address(0), 0));
    }

    /// El view expone el portal correcto por chain (verificable por cualquiera post-deploy).
    function test_portalGate_view_porChain() public {
        SocialFeeEscrowFactory f = new SocialFeeEscrowFactory(attesterAddr);
        vm.chainId(56);
        assertEq(f.vaultPortal(), BSC_PORTAL);
        vm.chainId(4663);
        assertEq(f.vaultPortal(), RH_PORTAL);
    }

    // ───────── Preaudit High nuevo: attester rotable (decision de producto de Jose) ─────────

    function _sigWith(SocialFeeEscrow e, uint256 pk, address payout, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, e.bindDigest(payout, deadline));
        return abi.encodePacked(r, s, v);
    }

    /// El flujo completo del finding: rotar mata los vouchers de la key vieja en vaults
    /// EXISTENTES (no solo futuros) y la key nueva firma con normalidad.
    function test_rotateAttester_voucherViejoMuere_nuevoFirma() public {
        uint256 pkOld = 0xA11CE;
        uint256 pkNew = 0xB0B00;
        vm.chainId(4663);
        SocialFeeEscrowFactory f = new SocialFeeEscrowFactory(vm.addr(pkOld));
        vm.prank(RH_PORTAL);
        address vAddr = f.newVault(predictedToken, address(0), creator, _data("github", "torvalds", address(0), 0));
        SocialFeeEscrow v = SocialFeeEscrow(payable(vAddr));
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);

        // rota el attester VIGENTE (self-gated: ni admin ni Guardian)
        vm.prank(vm.addr(pkOld));
        f.rotateAttester(vm.addr(pkNew));
        assertEq(f.attester(), vm.addr(pkNew));
        assertEq(v.attester(), vm.addr(pkNew)); // el vault existente sigue a la factory EN VIVO

        address payout = makeAddr("payout");
        uint256 deadline = block.timestamp + 15 minutes;
        bytes memory oldSig = _sigWith(v, pkOld, payout, deadline);
        vm.expectRevert(bytes(unicode"bad attester signature / 认证签名无效"));
        v.claimAndBind(payout, deadline, oldSig);

        v.claimAndBind(payout, deadline, _sigWith(v, pkNew, payout, deadline));
        assertEq(payout.balance, 1 ether);
    }

    /// Audit v3 (High, finding 5): rotateAttester ya no es self-gated — ahora tambien acepta al
    /// Guardian (ver AuditFixesV3Test.test_F5_*). Un caller random (ni attester ni Guardian) sigue
    /// revirtiendo, con el mensaje actualizado. Necesita chain soportada porque _getGuardian() se
    /// evalua como parte del OR, igual que en emergencyWithdrawNative.
    function test_rotateAttester_soloElVigente() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.chainId(4663);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes(unicode"only attester or guardian / 仅限认证者或 Guardian"));
        f.rotateAttester(makeAddr("attacker"));
    }

    function test_rotateAttester_zero_reverts() public {
        SocialFeeEscrowFactory f = _freshFactory();
        vm.prank(attesterAddr);
        vm.expectRevert(bytes(unicode"zero attester / 认证者地址为空"));
        f.rotateAttester(address(0));
    }
}

/// Sin receive() ni fallback: no puede recibir ETH, pero SI puede ejecutar calls
/// (como un multisig con la config de pagos rota pero la de ejecucion viva).
contract BrokenReceiver {
    function doRebind(SocialFeeEscrow vault, address newPayout) external {
        vault.rebindWallet(newPayout);
    }
}
