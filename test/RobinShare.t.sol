// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobinShareVault} from "../src/RobinShareVault.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {IPonsV2LaunchFactory} from "../src/pons/IPonsV2.sol";
import {IXGeneralVerifier} from "../src/flap/IXGeneralVerifier.sol";

// ───────────────────────── mocks del rail de pons ─────────────────────────

/// @dev Replica lo que importa del V2FeeEscrow real: claim() es ESTRICTAMENTE msg.sender,
///      revierte NoBalance() con saldo cero, y paga con .call reenviando todo el gas.
contract MockFeeEscrow {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public balanceOfToken;

    error NoBalance();
    error TransferFailed();

    function credit(address to) external payable {
        balanceOf[to] += msg.value;
    }

    function creditToken(address to, address erc20, uint256 amount) external {
        balanceOfToken[to][erc20] += amount;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        if (amount == 0) revert NoBalance();
        balanceOf[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function claimToken(address erc20) external returns (uint256 amount) {
        amount = balanceOfToken[msg.sender][erc20];
        if (amount == 0) revert NoBalance();
        balanceOfToken[msg.sender][erc20] = 0;
        MockERC20(erc20).transfer(msg.sender, amount);
    }
}

/// @dev La curva: autoriza al campo `deployer`, que en pons ES el creatorFeeRecipient vigente.
contract MockCurve {
    address public deployer;
    bool public graduated;
    MockFeeEscrow public escrow;
    uint256 public accrued;

    error NotFeeSweepOperator();
    error AlreadyGraduated();

    constructor(address deployer_, MockFeeEscrow escrow_) {
        deployer = deployer_;
        escrow = escrow_;
    }

    function accrue() external payable {
        accrued += msg.value;
    }

    function setGraduated(bool g) external {
        graduated = g;
    }

    function sweepFees(uint256) external {
        if (graduated) revert AlreadyGraduated();
        if (msg.sender != deployer) revert NotFeeSweepOperator();
        uint256 a = accrued;
        accrued = 0;
        escrow.credit{value: a}(deployer);
    }
}

contract MockPonsFactory {
    mapping(address => IPonsV2LaunchFactory.LaunchedToken) internal _info;

    function setLaunch(address token, address curve, address recipient) external {
        setLaunchFull(token, curve, recipient, address(0), false);
    }

    function setLaunchFull(
        address token,
        address curve,
        address recipient,
        address pairToken,
        bool buyback
    ) public {
        IPonsV2LaunchFactory.LaunchedToken memory t;
        t.token = token;
        t.curve = curve;
        t.creatorFeeRecipient = recipient;
        // Por default el `deployer` es el launcher del vault destinatario, que es el caso normal
        // (el mismo que creo el vault lanza la moneda). El squat se arma con `setLaunchDeployer`.
        t.deployer = _launcherOf(recipient);
        t.pairToken = pairToken;
        t.buybackEnabled = buyback;
        t.exists = true;
        _info[token] = t;
    }

    /// @dev Para armar el caso del extrano que lanza apuntando al vault de otro.
    function setLaunchDeployer(address token, address deployer_) external {
        _info[token].deployer = deployer_;
    }

    function _launcherOf(address recipient) internal view returns (address) {
        // El chequeo de `code.length` va ANTES del try: para una llamada de alto nivel a una
        // direccion sin codigo, Solidity inserta un `extcodesize` cuyo revert ocurre en ESTE
        // contexto y NO lo atrapa el `catch`.
        if (recipient.code.length == 0) return address(0);
        try RobinShareVault(payable(recipient)).launcher() returns (address l) {
            return l;
        } catch {
            return address(0);
        }
    }

    function getLaunchedToken(address token)
        external
        view
        returns (IPonsV2LaunchFactory.LaunchedToken memory)
    {
        return _info[token];
    }
}

contract MockXVerifier {
    bool public ok = true;

    function setOk(bool v) external {
        ok = v;
    }

    function verify(IXGeneralVerifier.XGeneralProof calldata, bytes calldata)
        external
        view
        returns (bool)
    {
        return ok;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Wallet que NO puede recibir ETH: prueba que el push best-effort no rompe nada.
contract RejectingWallet {
    receive() external payable {
        revert("nope");
    }

    function callWithdraw(RobinShareVault v) external {
        v.withdraw();
    }
}

// ───────────────────────── tests ─────────────────────────

contract RobinShareTest is Test {
    RobinShareVaultFactory factory;
    MockFeeEscrow escrow;
    MockPonsFactory pons;
    MockXVerifier xver;

    uint256 attesterPk = 0xA11CE;
    address attester;
    address launcher;
    address dev;
    address relayer;
    address admin;
    address TOKEN = address(0x7011);

    function setUp() public {
        attester = vm.addr(attesterPk);
        launcher = makeAddr("launcher");
        dev = makeAddr("dev");
        relayer = makeAddr("relayer");
        escrow = new MockFeeEscrow();
        pons = new MockPonsFactory();
        xver = new MockXVerifier();
        admin = makeAddr("attesterAdmin");
        factory = new RobinShareVaultFactory(
            attester, address(escrow), address(pons), address(xver), admin
        );
        vm.deal(launcher, 100 ether);
        vm.deal(relayer, 10 ether);
    }

    function _github(uint256 recoveryDays) internal returns (RobinShareVault v) {
        vm.prank(launcher);
        v = RobinShareVault(payable(factory.createVault(1, "Torvalds", address(0), recoveryDays)));
    }

    function _attach(RobinShareVault v) internal returns (MockCurve c) {
        c = new MockCurve(address(v), escrow);
        pons.setLaunch(TOKEN, address(c), address(v));
        v.attachToken(TOKEN);
    }

    function _voucher(RobinShareVault v, address payout, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = v.bindDigest(payout, deadline);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(attesterPk, digest);
        return abi.encodePacked(r, s, vv);
    }

    // ── factory ──

    function test_createVault_registraYNormaliza() public {
        RobinShareVault v = _github(0);
        assertTrue(factory.isVault(address(v)), "debe quedar en el registro de procedencia");
        assertEq(v.identityValue(), "torvalds", "handle normalizado a lowercase");
        assertEq(v.launcher(), launcher);
        assertEq(v.recoveryAfter(), 0, "0 = nunca, el default del producto");
        assertEq(factory.allVaultsLength(), 1);
    }

    function test_createVault_normalizaArroba() public {
        vm.prank(launcher);
        address v = factory.createVault(1, "@Torvalds", address(0), 0);
        assertEq(RobinShareVault(payable(v)).identityValue(), "torvalds");
    }

    function test_identityHashFor_coincideConElRegistro() public {
        RobinShareVault v = _github(0);
        bytes32 h = factory.identityHashFor(1, "@TORVALDS", address(0));
        address[] memory vs = factory.getVaults(h);
        assertEq(vs.length, 1);
        assertEq(vs[0], address(v), "el server tiene que poder ubicarlo por identidad");
    }

    function test_recoveryDays_pisoYTope() public {
        vm.prank(launcher);
        vm.expectRevert(RobinShareVaultFactory.RecoveryWindowTooShort.selector);
        factory.createVault(1, "x", address(0), 29);

        vm.prank(launcher);
        vm.expectRevert(RobinShareVaultFactory.RecoveryWindowTooLong.selector);
        factory.createVault(1, "x", address(0), 3651);
    }

    function test_rotateAttester_soloElVigente() public {
        vm.prank(makeAddr("badActor"));
        vm.expectRevert(RobinShareVaultFactory.OnlyAttester.selector);
        factory.rotateAttester(makeAddr("newAttester"));

        vm.prank(attester);
        factory.rotateAttester(makeAddr("newAttester"));
        assertEq(factory.attester(), makeAddr("newAttester"));
    }

    function test_vaultLeeElAttesterEnVivo() public {
        RobinShareVault v = _github(0);
        assertEq(v.attester(), attester);
        vm.prank(attester);
        factory.rotateAttester(makeAddr("newAttester"));
        assertEq(v.attester(), makeAddr("newAttester"), "el vault lee la factory, no una copia inmutable");
    }

    // ── attachToken ──

    function test_attachToken_rechazaUnLaunchAjeno() public {
        RobinShareVault v = _github(0);
        MockCurve c = new MockCurve(address(v), escrow);
        pons.setLaunch(TOKEN, address(c), makeAddr("otherRecipient")); // recipient != vault
        vm.expectRevert(RobinShareVault.NotOurLaunch.selector);
        v.attachToken(TOKEN);
    }

    function test_attachToken_esPermissionlessYUnaSolaVez() public {
        RobinShareVault v = _github(0);
        MockCurve c = new MockCurve(address(v), escrow);
        pons.setLaunch(TOKEN, address(c), address(v));
        vm.prank(makeAddr("anyone")); // cualquiera puede atarlo: la verdad la da la cadena
        v.attachToken(TOKEN);
        assertEq(v.token(), TOKEN);
        assertEq(v.curve(), address(c));
        vm.expectRevert(RobinShareVault.TokenAlreadyAttached.selector);
        v.attachToken(TOKEN);
    }

    // ── camino del dinero ──

    function test_harvest_barreLaCurvaYCobraDelEscrow() public {
        RobinShareVault v = _github(0);
        MockCurve c = _attach(v);
        vm.deal(address(this), 5 ether);
        c.accrue{value: 3 ether}();

        assertEq(v.pendingAmount(), 0, "todavia esta en la curva, fuera del escrow");
        vm.prank(relayer); // PERMISSIONLESS: lo puede disparar cualquiera
        v.harvest();
        assertEq(address(v).balance, 3 ether, "la plata llego al vault");
    }

    function test_pull_conSaldoCeroNoRevierte() public {
        RobinShareVault v = _github(0);
        _attach(v);
        vm.prank(relayer);
        v.harvest(); // sin nada acumulado: no debe revertir (NoBalance seria griefing)
        assertEq(address(v).balance, 0);
    }

    function test_sweepCurve_toleraCurvaGraduada() public {
        RobinShareVault v = _github(0);
        MockCurve c = _attach(v);
        vm.deal(address(this), 1 ether);
        c.accrue{value: 1 ether}();
        c.setGraduated(true);
        v.harvest(); // AlreadyGraduated se ignora, no propaga
        assertEq(address(v).balance, 0);
    }

    function test_pendingAmount_sumaLoAcreditadoEnPons() public {
        RobinShareVault v = _github(0);
        vm.deal(address(this), 2 ether);
        escrow.credit{value: 2 ether}(address(v));
        assertEq(v.pendingAmount(), 2 ether);
    }

    // ── ruta GitHub ──

    function test_claimAndBind_relayadoPagaAlDevSinGas() public {
        RobinShareVault v = _github(0);
        MockCurve c = _attach(v);
        vm.deal(address(this), 4 ether);
        c.accrue{value: 4 ether}();

        bytes memory sig = _voucher(v, dev, block.timestamp + 600);
        vm.prank(relayer); // el RELAYER manda la tx; el dev nunca tuvo ETH
        v.claimAndBind(dev, block.timestamp + 600, sig);

        assertEq(v.boundWallet(), dev);
        assertEq(dev.balance, 4 ether, "el dev cobro sin haber pagado gas");
        assertEq(v.totalPaid(), 4 ether);
    }

    function test_claimAndBind_firmaAjenaRevierte() public {
        RobinShareVault v = _github(0);
        bytes32 digest = v.bindDigest(dev, block.timestamp + 600);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(uint256(0xBADBAD), digest);
        vm.expectRevert(RobinShareVault.BadAttesterSignature.selector);
        v.claimAndBind(dev, block.timestamp + 600, abi.encodePacked(r, s, vv));
    }

    function test_claimAndBind_voucherVencido() public {
        RobinShareVault v = _github(0);
        uint256 dl = block.timestamp + 600;
        bytes memory sig = _voucher(v, dev, dl);
        vm.warp(dl + 1);
        vm.expectRevert(RobinShareVault.VoucherExpired.selector);
        v.claimAndBind(dev, dl, sig);
    }

    function test_voucherViejoNoSirveDespuesDeUnBind() public {
        RobinShareVault v = _github(0);
        uint256 dl = block.timestamp + 600;
        bytes memory sig1 = _voucher(v, dev, dl);
        v.claimAndBind(dev, dl, sig1);
        // el nonce avanzo: el mismo voucher ya no vale
        vm.expectRevert(RobinShareVault.BadAttesterSignature.selector);
        v.claimAndBind(dev, dl, sig1);
    }

    // ── payout: push best-effort + pull ──

    function test_walletQueNoRecibe_noRompeElClaimYCobraDespues() public {
        RobinShareVault v = _github(0);
        MockCurve c = _attach(v);
        vm.deal(address(this), 2 ether);
        c.accrue{value: 2 ether}();

        RejectingWallet rw = new RejectingWallet();
        bytes memory sig = _voucher(v, address(rw), block.timestamp + 600);
        // NO revierte aunque el push falle: el claim relayado no debe romperse por esto
        v.claimAndBind(address(rw), block.timestamp + 600, sig);
        assertEq(address(v).balance, 2 ether, "la plata quedo en el vault");
        assertEq(v.boundWallet(), address(rw));
        // y sigue sin haber ninguna llave de emergencia: el propio bound decide
        vm.expectRevert(); // rw revierte al recibir, asi que withdraw falla — pero nada se perdio
        rw.callWithdraw(v);
        assertEq(address(v).balance, 2 ether);
    }

    function test_withdraw_soloElBoundWallet() public {
        RobinShareVault v = _github(0);
        MockCurve c = _attach(v);
        vm.deal(address(this), 1 ether);
        c.accrue{value: 1 ether}();
        bytes memory sig = _voucher(v, dev, block.timestamp + 600);
        v.claimAndBind(dev, block.timestamp + 600, sig);

        c.accrue{value: 0}(); // nada nuevo
        vm.deal(address(this), 3 ether);
        c.accrue{value: 3 ether}();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RobinShareVault.NotBoundWallet.selector);
        v.withdraw();

        uint256 before = dev.balance;
        vm.prank(dev);
        v.withdraw(); // harvest + payout en una
        assertEq(dev.balance - before, 3 ether);
    }

    function test_withdraw_sinBindRevierte() public {
        RobinShareVault v = _github(0);
        vm.prank(dev);
        vm.expectRevert(RobinShareVault.NotBoundYet.selector);
        v.withdraw();
    }

    function test_withdrawToken_gateadoAlBoundWallet() public {
        RobinShareVault v = _github(0);
        MockERC20 erc = new MockERC20();
        erc.mint(address(v), 1000); // llegada "sin aviso", tipo rescuePoolFees

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RobinShareVault.NotBoundYet.selector);
        v.withdrawToken(address(erc));

        bytes memory sig = _voucher(v, dev, block.timestamp + 600);
        v.claimAndBind(dev, block.timestamp + 600, sig);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RobinShareVault.NotBoundWallet.selector);
        v.withdrawToken(address(erc));

        vm.prank(dev);
        v.withdrawToken(address(erc));
        assertEq(erc.balanceOf(dev), 1000);
    }

    // ── ruta X ──

    function _proof(RobinShareVault v, address payout, uint128 tweetId)
        internal
        view
        returns (IXGeneralVerifier.XGeneralProof memory p)
    {
        p.tweetId = tweetId;
        p.xHandle = "torvalds";
        p.xId = 1;
        p.substring = v.expectedTweet(payout);
    }

    function _twitter() internal returns (RobinShareVault v) {
        vm.prank(launcher);
        v = RobinShareVault(payable(factory.createVault(2, "Torvalds", address(0), 0)));
    }

    function test_claimByProof_esRelayable() public {
        RobinShareVault v = _twitter();
        MockCurve c = _attach(v);
        vm.deal(address(this), 2 ether);
        c.accrue{value: 2 ether}();

        vm.prank(relayer); // el dev NO manda la tx
        v.claimByProof(dev, _proof(v, dev, 100), "");
        assertEq(v.boundWallet(), dev);
        assertEq(dev.balance, 2 ether);
    }

    function test_claimByProof_substringDeOtraWalletRevierte() public {
        RobinShareVault v = _twitter();
        IXGeneralVerifier.XGeneralProof memory p = _proof(v, dev, 100);
        vm.expectRevert(RobinShareVault.SubstringMismatch.selector);
        v.claimByProof(makeAddr("evil"), p, ""); // el substring nombra a `dev`, no al atacante
    }

    function test_claimByProof_handleAjenoRevierte() public {
        RobinShareVault v = _twitter();
        IXGeneralVerifier.XGeneralProof memory p = _proof(v, dev, 100);
        p.xHandle = "impostor";
        vm.expectRevert(RobinShareVault.WrongXHandle.selector);
        v.claimByProof(dev, p, "");
    }

    function test_claimByProof_replayGlobal() public {
        RobinShareVault v = _twitter();
        v.claimByProof(dev, _proof(v, dev, 100), "");
        // un tweet mas viejo, aunque el oraculo lo firme, ya no vale — ni para otra wallet
        address otro = address(0xC0FFEE);
        // el proof se arma ANTES: _proof llama expectedTweet(), que es una llamada externa y se
        // comeria el vm.expectRevert si quedara como argumento.
        IXGeneralVerifier.XGeneralProof memory viejo = _proof(v, otro, 99);
        vm.expectRevert(RobinShareVault.OutdatedProof.selector);
        v.claimByProof(otro, viejo, "");
    }

    function test_claimByProof_oraculoQueRechaza() public {
        RobinShareVault v = _twitter();
        IXGeneralVerifier.XGeneralProof memory p = _proof(v, dev, 100);
        xver.setOk(false);
        vm.expectRevert(RobinShareVault.InvalidProof.selector);
        v.claimByProof(dev, p, "");
    }

    // ── recovery ──

    function test_recovery_deshabilitadoPorDefault() public {
        RobinShareVault v = _github(0);
        vm.prank(launcher);
        vm.expectRevert(RobinShareVault.RecoveryDisabled.selector);
        v.recoverUnclaimed(launcher);
    }

    function test_recovery_soloLauncher_soloDespuesDelPlazo_soloSinBind() public {
        vm.prank(launcher);
        RobinShareVault v =
            RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 30)));
        MockCurve c = _attach(v);
        vm.deal(address(this), 1 ether);
        c.accrue{value: 1 ether}();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RobinShareVault.OnlyLauncher.selector);
        v.recoverUnclaimed(launcher);

        vm.prank(launcher);
        vm.expectRevert(RobinShareVault.TooEarly.selector);
        v.recoverUnclaimed(launcher);

        vm.warp(block.timestamp + 31 days);
        uint256 before = launcher.balance;
        vm.prank(launcher);
        v.recoverUnclaimed(launcher);
        assertEq(launcher.balance - before, 1 ether);
    }

    function test_recovery_imposibleDespuesDeUnBind() public {
        vm.prank(launcher);
        RobinShareVault v =
            RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 30)));
        bytes memory sig = _voucher(v, dev, block.timestamp + 600);
        v.claimAndBind(dev, block.timestamp + 600, sig);
        vm.warp(block.timestamp + 31 days);
        vm.prank(launcher);
        vm.expectRevert(RobinShareVault.AlreadyBound.selector);
        v.recoverUnclaimed(launcher);
    }

    // ── el invariante de marca ──

    function test_invariante_elEthSoloSaleAlBoundWalletOAlRecovery() public {
        RobinShareVault v = _github(0);
        MockCurve c = _attach(v);
        vm.deal(address(this), 5 ether);
        c.accrue{value: 5 ether}();
        v.harvest();

        // nadie puede sacar plata: no hay owner, no hay guardian, no hay funcion de rescate
        vm.prank(launcher);
        vm.expectRevert(RobinShareVault.NotBoundYet.selector);
        v.withdraw();

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(RobinShareVault.NotBoundYet.selector);
        v.withdraw();

        vm.prank(launcher);
        vm.expectRevert(RobinShareVault.RecoveryDisabled.selector);
        v.recoverUnclaimed(launcher);

        assertEq(address(v).balance, 5 ether, "la plata sigue esperando a su dueno");
    }

    // ── regresiones del review adversarial ──

    function test_attachToken_rechazaParERC20() public {
        RobinShareVault v = _github(0);
        MockCurve c = new MockCurve(address(v), escrow);
        MockERC20 pair = new MockERC20();
        pons.setLaunchFull(TOKEN, address(c), address(v), address(pair), false);
        // ~50% de los launches de pons cotizan contra ERC-20: ahi este vault entregaria CERO,
        // asi que se rechazan en vez de atrapar la plata.
        vm.expectRevert(RobinShareVault.PairMustBeNative.selector);
        v.attachToken(TOKEN);
    }

    function test_attachToken_rechazaBuybackActivo() public {
        RobinShareVault v = _github(0);
        MockCurve c = new MockCurve(address(v), escrow);
        pons.setLaunchFull(TOKEN, address(c), address(v), address(0), true);
        // con buyback la curva revierte InternalSwapRequiresOperator y sweepCurve() seria un
        // no-op SILENCIOSO: mejor no dejar atar el launch.
        vm.expectRevert(RobinShareVault.BuybackMustBeDisabled.selector);
        v.attachToken(TOKEN);
    }

    function test_handleHomoglifo_esRechazado() public {
        // "torvalds" con la 'o' cirilica (U+043E): se ve igual en la UI, pero la identidad real
        // nunca podria reclamarlo. Con recovery, eso le regala el clawback al launcher.
        vm.prank(launcher);
        vm.expectRevert(RobinShareVaultFactory.BadHandleCharset.selector);
        factory.createVault(1, unicode"tоrvalds", address(0), 30);
    }

    function test_handleConEspacioOVacio_esRechazado() public {
        vm.prank(launcher);
        vm.expectRevert(RobinShareVaultFactory.BadHandleCharset.selector);
        factory.createVault(1, "tor valds", address(0), 0);

        vm.prank(launcher);
        vm.expectRevert(RobinShareVaultFactory.BadHandleLength.selector);
        factory.createVault(1, "", address(0), 0);
    }

    function test_handleDemasiadoLargo_porTipo() public {
        // twitter: 15 · github: 39
        vm.prank(launcher);
        vm.expectRevert(RobinShareVaultFactory.BadHandleLength.selector);
        factory.createVault(2, "abcdefghijklmnop", address(0), 0); // 16

        vm.prank(launcher);
        address ok = factory.createVault(2, "abcdefghijklmno", address(0), 0); // 15
        assertEq(RobinShareVault(payable(ok)).identityValue(), "abcdefghijklmno");
    }

    function test_attesterAdmin_puedeRotarSiSePierdeLaLlave() public {
        address nuevo = makeAddr("nuevoAttester");
        vm.prank(admin);
        factory.rotateAttester(nuevo);
        assertEq(factory.attester(), nuevo, "sin sucesor, una llave perdida congela todos los vaults github");

        // El admin no tiene NINGUNA funcion que mueva fondos directamente...
        RobinShareVault v = _github(0);
        vm.deal(address(v), 1 ether);
        vm.prank(admin);
        vm.expectRevert(RobinShareVault.NotBoundYet.selector);
        v.withdraw();
        // ...pero eso NO significa que no alcance los fondos: rotando el attester y firmandose
        // un voucher llega igual. Probado en
        // `ReviewRound2.t.sol::test_attesterAdmin_SI_alcanzaLosFondosDeUnVaultGithub`.
        // Esta aclaracion esta aca porque la version anterior de este test afirmaba lo
        // contrario ("no existe ninguna funcion para eso") y dos revisores lo refutaron.
    }

    function test_noSePuedeBindearElPropioVault() public {
        RobinShareVault v = _github(0);
        bytes memory sig = _voucher(v, address(v), block.timestamp + 600);
        vm.expectRevert(RobinShareVault.SelfPayout.selector);
        v.claimAndBind(address(v), block.timestamp + 600, sig);
    }

    function test_recoverUnclaimedToken_rescataUnERC20Atrapado() public {
        vm.prank(launcher);
        RobinShareVault v =
            RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 30)));
        MockERC20 erc = new MockERC20();
        erc.mint(address(v), 500); // llegada sin aviso, y la identidad nunca aparece

        vm.prank(launcher);
        vm.expectRevert(RobinShareVault.TooEarly.selector);
        v.recoverUnclaimedToken(address(erc), launcher);

        vm.warp(block.timestamp + 31 days);
        vm.prank(launcher);
        v.recoverUnclaimedToken(address(erc), launcher);
        assertEq(erc.balanceOf(launcher), 500);
    }
}
