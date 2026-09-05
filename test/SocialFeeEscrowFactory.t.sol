// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";
import {VaultDataSchema, FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";

contract SocialFeeEscrowFactoryTest is Test {
    SocialFeeEscrowFactory factory;
    // Gate hardcodeado (fix preaudit): los tests corren en 4663 y prankean el portal REAL.
    address constant portal = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B; // VaultPortal Robinhood
    address constant BSC_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // VaultPortal BSC
    address creator = makeAddr("creator");
    address attester = makeAddr("attester");
    address predictedToken = address(0x7777);

    function setUp() public {
        vm.chainId(4663);
        factory = new SocialFeeEscrowFactory(attester);
    }

    function _data(string memory t, string memory v, address w, uint256 days_) internal pure returns (bytes memory) {
        return abi.encode(t, v, w, days_);
    }

    function test_constructor_zeroAttester_reverts() public {
        vm.expectRevert(bytes(unicode"zero attester / 认证者地址为空"));
        new SocialFeeEscrowFactory(address(0));
    }

    function test_attester_esCanonico_noElegibleporCreator() public {
        // El vaultData ya no lleva attester: todo escrow social usa el canonico de la factory.
        vm.prank(portal);
        address vault = factory.newVault(predictedToken, address(0), creator, _data("github", "torvalds", address(0), 0));
        assertEq(SocialFeeEscrow(payable(vault)).attester(), factory.attester());
        assertEq(factory.attester(), attester);
    }

    // ───────────────────────── Task 8: newVault + normalización + registro ─────────────────────────

    function test_soloPortal() public {
        vm.expectRevert(bytes(unicode"only vault portal / 仅限 VaultPortal"));
        factory.newVault(predictedToken, address(0), creator, _data("github", "torvalds", address(0), 0));
    }

    function test_quoteDebeSerNativo() public {
        vm.prank(portal);
        vm.expectRevert(bytes(unicode"native quote only / 仅支持原生代币"));
        factory.newVault(predictedToken, address(0xDAD), creator, _data("github", "torvalds", address(0), 0));
    }

    function test_creaEscrowGithub_normalizado() public {
        vm.prank(portal);
        address vault =
            factory.newVault(predictedToken, address(0), creator, _data("github", "@ToRvAlDs", address(0), 0));
        SocialFeeEscrow e = SocialFeeEscrow(payable(vault));
        assertEq(e.identityValue(), "torvalds"); // strip @ + lowercase
        assertEq(e.identityType(), 1);
        assertEq(e.taxToken(), predictedToken);
        assertEq(e.creator(), creator);
        assertEq(e.attester(), attester);
        // registro consultable con el hash normalizado
        bytes32 h = factory.identityHashFor("github", "Torvalds", address(0));
        address[] memory vaults = factory.getVaults(h);
        assertEq(vaults.length, 1);
        assertEq(vaults[0], vault);
    }

    function test_creaEscrowTwitter_y_wallet() public {
        // twitter exige el XGeneralVerifier vivo → BSC (56) con SU portal; wallet en 4663.
        vm.chainId(56);
        vm.prank(BSC_PORTAL);
        address v1 = factory.newVault(predictedToken, address(0), creator, _data("twitter", "@0xKeezy", address(0), 30));
        vm.chainId(4663);
        vm.prank(portal);
        address v2 =
            factory.newVault(predictedToken, address(0), creator, _data("wallet", "", makeAddr("person"), 0));
        assertEq(SocialFeeEscrow(payable(v1)).identityValue(), "0xkeezy");
        assertGt(SocialFeeEscrow(payable(v1)).recoveryAfter(), 0);
        assertEq(SocialFeeEscrow(payable(v2)).identityType(), 0);
        assertEq(SocialFeeEscrow(payable(v2)).boundWallet(), makeAddr("person"));
    }

    function test_charset_rechazaInvalidos() public {
        vm.startPrank(portal);
        vm.expectRevert(bytes(unicode"bad handle charset / 句柄包含非法字符"));
        factory.newVault(predictedToken, address(0), creator, _data("twitter", "bad-handle", address(0), 0)); // '-' no valido en twitter
        vm.expectRevert(bytes(unicode"bad handle charset / 句柄包含非法字符"));
        factory.newVault(predictedToken, address(0), creator, _data("github", "under_score", address(0), 0)); // '_' no valido en github
        vm.expectRevert(bytes(unicode"bad handle charset / 句柄包含非法字符"));
        factory.newVault(predictedToken, address(0), creator, _data("twitter", unicode"tòrvalds", address(0), 0)); // no-ASCII
        vm.stopPrank();
    }

    function test_longitudes() public {
        vm.startPrank(portal);
        vm.expectRevert(bytes(unicode"bad handle length / 句柄长度无效"));
        factory.newVault(predictedToken, address(0), creator, _data("twitter", "esto_es_demasiado_largo", address(0), 0)); // >15
        vm.expectRevert(bytes(unicode"bad handle length / 句柄长度无效"));
        factory.newVault(predictedToken, address(0), creator, _data("github", "", address(0), 0)); // vacio
        vm.stopPrank();
    }

    function test_walletType_exigeCamposCoherentes() public {
        vm.startPrank(portal);
        vm.expectRevert(bytes(unicode"value must be empty for wallet / wallet 类型不需要句柄"));
        factory.newVault(predictedToken, address(0), creator, _data("wallet", "algo", makeAddr("w"), 0));
        vm.expectRevert(bytes(unicode"wallet required / 需要钱包地址"));
        factory.newVault(predictedToken, address(0), creator, _data("wallet", "", address(0), 0));
        vm.stopPrank();
    }

    function test_tipoInvalido_y_recoveryCap() public {
        vm.startPrank(portal);
        vm.expectRevert(bytes(unicode"identity type must be wallet|github|twitter / 身份类型无效"));
        factory.newVault(predictedToken, address(0), creator, _data("telegram", "x", address(0), 0));
        vm.expectRevert(bytes(unicode"recovery too long / 回收期过长"));
        factory.newVault(predictedToken, address(0), creator, _data("github", "ok", address(0), 3651));
        vm.stopPrank();
    }

    function testFuzz_normalizacionIdempotente(string memory raw) public {
        // Propiedad: si un handle pasa la validacion, el hash del crudo == hash del normalizado.
        vm.assume(bytes(raw).length > 0 && bytes(raw).length <= 15);
        vm.chainId(56); // twitter exige verifier vivo; sin esto la propiedad seria vacua
        vm.prank(BSC_PORTAL);
        try factory.newVault(predictedToken, address(0), creator, _data("twitter", raw, address(0), 0)) returns (
            address vault
        ) {
            string memory norm = SocialFeeEscrow(payable(vault)).identityValue();
            assertEq(
                factory.identityHashFor("twitter", raw, address(0)),
                factory.identityHashFor("twitter", norm, address(0))
            );
        } catch {} // los que revierten no interesan a esta propiedad
    }

    // ───────────────────────── Task 9: schema + policies + validación v2.2 ─────────────────────────

    function test_vaultDataSchema_cuatroCampos() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        // 4 campos: el attester ya NO lo pone el creator (es canonico de la factory).
        assertEq(s.fields.length, 4);
        assertEq(s.fields[0].name, "identityType");
        assertEq(s.fields[0].fieldType, "string");
        assertEq(s.fields[1].name, "identityValue");
        assertEq(s.fields[2].name, "identityWallet");
        assertEq(s.fields[2].fieldType, "address");
        assertEq(s.fields[3].name, "recoveryDays");
        assertEq(s.fields[3].fieldType, "uint256");
        assertFalse(s.isArray);
    }

    function _launch(address quote, uint16 vaultBps, uint16 dividendBps, uint16 lpBps)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            IVaultFactoryValidationV2.LaunchValidationDataV1({
                tokenVersion: IPortalTypes.TokenVersion.TOKEN_TAXED_V3,
                quoteToken: quote,
                buyTaxRate: 300,
                sellTaxRate: 300,
                vaultBps: vaultBps,
                deflationBps: 0,
                dividendBps: dividendBps,
                lpBps: lpBps,
                dividendToken: address(0),
                minimumShareBalance: 0
            })
        );
    }

    function test_onBeforeLaunch_valida() public view {
        (bool okFlag,) = factory.onBeforeLaunch(_launch(address(0), 10000, 0, 0));
        assertTrue(okFlag);

        (bool f1, string memory r1) = factory.onBeforeLaunch(_launch(address(0xDAD), 10000, 0, 0));
        assertFalse(f1);
        assertGt(bytes(r1).length, 0);

        (bool f2,) = factory.onBeforeLaunch(_launch(address(0), 0, 5000, 5000));
        assertFalse(f2);
    }

    function test_policies_dosReglas() public view {
        FactoryPolicy[] memory p = factory.tokenCreationPolicies();
        assertEq(p.length, 2);
        assertEq(p[0].target, "quoteToken");
        assertEq(p[0].operator, "eq");
        assertEq(p[1].target, "mktBps");
        assertEq(p[1].operator, "gte");
    }
}
