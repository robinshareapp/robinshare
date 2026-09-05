// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {RobinShareVault} from "../src/RobinShareVault.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {MockFeeEscrow, MockCurve, MockPonsFactory, MockXVerifier, MockERC20} from "./RobinShare.t.sol";

/// @dev ERC-20 hostil: su `transfer` SIEMPRE revierte. Existe para probar que un token
///      envenenado no puede bloquear el retiro de los demas (spec §5.5).
contract RevertingERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev ERC-20 no estandar: transfiere de verdad pero NO devuelve nada. Es el caso que
///      `SafeERC20` existe para tolerar; sin el, el retiro revertiria por decodificar vacio.
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        // sin `return true` a proposito
    }
}

/// @title Regresiones de la ronda de review adversarial (2026-08-30)
/// @notice Cada test de aca nacio de un hallazgo REPRODUCIDO por un revisor externo sobre el
///         codigo ya escrito. No son tests de diseno: son la prueba de que el agujero se cerro.
contract ReviewRound2Test is Test {
    uint256 constant ATTESTER_PK = 0xA11CE;

    RobinShareVaultFactory factory;
    MockFeeEscrow escrow;
    MockPonsFactory pons;
    MockXVerifier xver;

    address attester;
    address admin;
    address launcher;
    address stranger;

    address constant REAL_TOKEN = address(0x7011);
    address constant SQUAT_TOKEN = address(0xBAD1);

    function setUp() public {
        attester = vm.addr(ATTESTER_PK);
        admin = makeAddr("attesterAdmin");
        launcher = makeAddr("launcher");
        stranger = makeAddr("stranger");
        escrow = new MockFeeEscrow();
        pons = new MockPonsFactory();
        xver = new MockXVerifier();
        factory = new RobinShareVaultFactory(
            attester, address(escrow), address(pons), address(xver), admin
        );
    }

    function _github() internal returns (RobinShareVault v) {
        vm.prank(launcher);
        v = RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 0)));
    }

    // ───────────────── el squat de attachToken ─────────────────

    /// @notice HALLAZGO (HIGH, reproducido con PoC): `attachToken` era permissionless Y de una
    ///         sola vez, y solo verificaba que el launch apuntara a este vault. Un extrano podia
    ///         lanzar SU propia moneda de pons apuntando las creator fees al vault de la victima
    ///         (0,0005 ETH) y atarla ANTES de la tercera transaccion del flujo de `/create`.
    ///         El vault quedaba pegado para siempre a la curva equivocada: la moneda real ya no
    ///         se podia atar nunca, `sweepCurve()` apuntaba a la curva del atacante, y el
    ///         beneficiario probaba su identidad para cobrar CERO.
    ///
    /// @dev El fix mira el campo `deployer` del registro de pons, que es quien LANZO (distinto
    ///      del `creatorFeeRecipient` — eso ya esta probado contra la cadena real en
    ///      `ForkPons.t.sol::test_fork_fullCycle_nativePair`).
    function test_attachToken_rechazaElSquatDeUnExtrano() public {
        RobinShareVault v = _github();
        MockCurve squatCurve = new MockCurve(address(v), escrow);

        // el extrano lanza SU moneda apuntando las fees al vault de la victima
        pons.setLaunchFull(SQUAT_TOKEN, address(squatCurve), address(v), address(0), false);
        pons.setLaunchDeployer(SQUAT_TOKEN, stranger);

        vm.prank(stranger);
        vm.expectRevert(RobinShareVault.LaunchedByStranger.selector);
        v.attachToken(SQUAT_TOKEN);

        assertEq(v.token(), address(0), "el vault no puede quedar pegado a un launch ajeno");
    }

    /// @notice El fix no puede romper el caso normal: la moneda que lanzo el propio launcher.
    function test_attachToken_aceptaElLaunchDelPropioLauncher() public {
        RobinShareVault v = _github();
        MockCurve c = new MockCurve(address(v), escrow);
        pons.setLaunchFull(REAL_TOKEN, address(c), address(v), address(0), false);

        // permissionless: lo manda un tercero cualquiera, no el launcher
        vm.prank(makeAddr("buen-samaritano"));
        v.attachToken(REAL_TOKEN);
        assertEq(v.token(), REAL_TOKEN);
        assertEq(v.curve(), address(c));
    }

    /// @notice Y sigue siendo reparable: tras el intento de squat, la moneda real se ata igual.
    function test_attachToken_elSquatFallidoNoBloqueaLaMonedaReal() public {
        RobinShareVault v = _github();
        MockCurve squatCurve = new MockCurve(address(v), escrow);
        pons.setLaunchFull(SQUAT_TOKEN, address(squatCurve), address(v), address(0), false);
        pons.setLaunchDeployer(SQUAT_TOKEN, stranger);
        vm.prank(stranger);
        vm.expectRevert(RobinShareVault.LaunchedByStranger.selector);
        v.attachToken(SQUAT_TOKEN);

        MockCurve real = new MockCurve(address(v), escrow);
        pons.setLaunchFull(REAL_TOKEN, address(real), address(v), address(0), false);
        v.attachToken(REAL_TOKEN);
        assertEq(v.token(), REAL_TOKEN, "el squat no puede dejar el vault inservible");
    }

    // ───────────────── handles que ninguna persona puede reclamar ─────────────────

    /// @notice HALLAZGO (MEDIUM, reproducido): el charset permitia guiones en cualquier lado,
    ///         pero GitHub PROHIBE el guion inicial, el final y los dobles. Un vault para
    ///         `-torvalds` no lo puede reclamar nadie: el attester nunca va a ver ese login.
    ///         Con `recoveryDays > 0` eso convierte el clawback OPCIONAL del launcher en uno
    ///         GARANTIZADO — el mismo ataque que la validacion de charset existe para impedir,
    ///         entrando por la puerta de al lado.
    function test_normalize_rechazaHandlesDeGithubImposibles() public {
        vm.expectRevert(RobinShareVaultFactory.BadHandleCharset.selector);
        factory.createVault(1, "-torvalds", address(0), 0);

        vm.expectRevert(RobinShareVaultFactory.BadHandleCharset.selector);
        factory.createVault(1, "torvalds-", address(0), 0);

        vm.expectRevert(RobinShareVaultFactory.BadHandleCharset.selector);
        factory.createVault(1, "tor--valds", address(0), 0);
    }

    /// @notice Un guion simple en el medio SI es un handle valido de GitHub. El fix no puede
    ///         volverse mas estricto que GitHub o bloquea usuarios reales (`0x-keezy`, el piloto).
    function test_normalize_aceptaGuionSimpleInterno() public {
        vm.prank(launcher);
        address v = factory.createVault(1, "0x-keezy", address(0), 0);
        assertEq(RobinShareVault(payable(v)).identityValue(), "0x-keezy");
    }

    /// @notice X no comparte la regla: ahi el guion bajo SI puede ir al principio, al final y
    ///         repetido. Aplicarle la regla de GitHub bloquearia handles reales.
    function test_normalize_xAceptaGuionBajoEnLosBordes() public {
        vm.startPrank(launcher);
        assertEq(RobinShareVault(payable(factory.createVault(2, "_keezy", address(0), 0))).identityValue(), "_keezy");
        assertEq(RobinShareVault(payable(factory.createVault(2, "keezy_", address(0), 0))).identityValue(), "keezy_");
        assertEq(RobinShareVault(payable(factory.createVault(2, "ke__zy", address(0), 0))).identityValue(), "ke__zy");
        vm.stopPrank();
    }

    // ───────────────── la verdad sobre el attester ─────────────────

    /// @notice HALLAZGO (HIGH, reproducido por DOS revisores): el test viejo afirmaba que el
    ///         `attesterAdmin` "NO puede tocar fondos: no existe ninguna funcion para eso", y
    ///         solo probaba `withdraw()` — la unica puerta que el admin no necesita.
    ///
    ///         La verdad es esta: rotar el attester y firmarse un voucher ES una ruta a los
    ///         fondos de CUALQUIER vault de GitHub. No es un bug del contrato — en la ruta
    ///         GitHub, "probar la identidad" ES nuestra firma, y eso es inherente a atestiguar
    ///         un OAuth on-chain. Lo que era un bug es DECIR lo contrario, y sobre esa frase
    ///         falsa Jose iba a tomar la decision de custodia (PENDIENTES §2 y §3).
    ///
    ///         Este test existe para que la potestad quede escrita, ejecutable y visible en el
    ///         suite, en vez de negada.
    function test_attesterAdmin_SI_alcanzaLosFondosDeUnVaultGithub() public {
        RobinShareVault v = _github();
        vm.deal(address(v), 5 ether);

        address ladron = makeAddr("ladron");
        uint256 ladronPk = 0xBADBEEF;
        address ladronAttester = vm.addr(ladronPk);

        // 1. el admin rota el attester a una llave que controla
        vm.prank(admin);
        factory.rotateAttester(ladronAttester);

        // 2. se firma su propio voucher y bindea el vault a donde quiera
        uint256 deadline = block.timestamp + 600;
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(ladronPk, v.bindDigest(ladron, deadline));
        v.claimAndBind(ladron, deadline, abi.encodePacked(r, s, sv));

        assertEq(ladron.balance, 5 ether, "la llave del attester ES una ruta a los fondos");
        assertEq(address(v).balance, 0);
    }

    /// @notice El alcance de esa potestad, tambien escrito: NO llega a los vaults de wallet.
    ///         Ahi `boundWallet` se fija en el constructor y solo la identidad puede rotarla.
    function test_attesterAdmin_noAlcanzaLosVaultsDeWallet() public {
        address dueno = makeAddr("dueno-wallet");
        vm.prank(launcher);
        RobinShareVault v =
            RobinShareVault(payable(factory.createVault(0, "", dueno, 0)));
        vm.deal(address(v), 5 ether);

        vm.prank(admin);
        factory.rotateAttester(vm.addr(0xBADBEEF));

        // no hay ruta de attester en un vault de wallet
        vm.expectRevert(RobinShareVault.GithubOnly.selector);
        v.claimAndBind(makeAddr("ladron"), block.timestamp + 600, hex"00");
        assertEq(v.boundWallet(), dueno, "el boundWallet de un vault de wallet no se toca");
    }

    // ───────────────── tokens envenenados ─────────────────

    /// @notice HALLAZGO (MEDIUM): el spec §5.5 exige tolerar tokens no estandar y que un token
    ///         envenenado NO bloquee el retiro de los demas — y el unico mock del suite era un
    ///         ERC-20 bien portado que nunca revierte. Esto es esa prueba.
    function test_withdrawToken_unTokenQueRevierteNoBloqueaALosDemas() public {
        RobinShareVault v = _github();
        address dev = makeAddr("dev");
        uint256 deadline = block.timestamp + 600;
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, v.bindDigest(dev, deadline));
        v.claimAndBind(dev, deadline, abi.encodePacked(r, s, sv));

        RevertingERC20 poison = new RevertingERC20();
        MockERC20 good = new MockERC20();
        poison.mint(address(v), 1e18);
        good.mint(address(v), 7e18);

        // el envenenado revierte, como corresponde...
        vm.prank(dev);
        vm.expectRevert();
        v.withdrawToken(address(poison));

        // ...y el bueno sale igual. El retiro es POR TOKEN, no un barrido de lista.
        vm.prank(dev);
        v.withdrawToken(address(good));
        assertEq(good.balanceOf(dev), 7e18, "un token hostil no puede secuestrar a los demas");
    }

    /// @notice Un ERC-20 que no devuelve nada (el caso que `SafeERC20` existe para tolerar).
    function test_withdrawToken_toleraUnERC20QueNoDevuelveNada() public {
        RobinShareVault v = _github();
        address dev = makeAddr("dev");
        uint256 deadline = block.timestamp + 600;
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, v.bindDigest(dev, deadline));
        v.claimAndBind(dev, deadline, abi.encodePacked(r, s, sv));

        NoReturnERC20 weird = new NoReturnERC20();
        weird.mint(address(v), 3e18);

        vm.prank(dev);
        v.withdrawToken(address(weird));
        assertEq(weird.balanceOf(dev), 3e18);
    }

    /// @notice El fix del squat no puede BRICKEAR un vault legitimo.
    /// @dev Hallazgo de la segunda ronda: si el vault lo crea una wallet y la moneda la lanza
    ///      otra (equipo, multisig, script con otra key, o el orquestador de 1 tx de §4 cuando
    ///      exista), `attachToken` revertia PARA SIEMPRE — `token` solo se escribe ahi, no hay
    ///      setter ni admin — y las fees quedaban en una curva que el vault jamas podria barrer.
    ///      Medido contra la curva real: `sweepFees` solo lo puede llamar el `creatorFeeRecipient`.
    function test_attachToken_elLauncherPuedeBendecirUnLaunchDeOtraWallet() public {
        RobinShareVault v = _github();
        MockCurve c = new MockCurve(address(v), escrow);
        address coLanzador = makeAddr("multisig-del-equipo");
        pons.setLaunchFull(REAL_TOKEN, address(c), address(v), address(0), false);
        pons.setLaunchDeployer(REAL_TOKEN, coLanzador);

        // un tercero sigue sin poder
        vm.prank(stranger);
        vm.expectRevert(RobinShareVault.LaunchedByStranger.selector);
        v.attachToken(REAL_TOKEN);

        // pero el launcher del vault si puede bendecirlo
        vm.prank(launcher);
        v.attachToken(REAL_TOKEN);
        assertEq(v.token(), REAL_TOKEN, "el launcher tiene que poder rescatar su propio vault");
    }

    /// @notice El happy path, con el `deployer` puesto A MANO y no derivado del recipient.
    /// @dev El mock deriva `deployer` del launcher del vault, asi que el test del camino feliz
    ///      era CIRCULAR: el mock construia justo la condicion que el contrato despues chequea.
    ///      Aca el valor se fija explicito.
    function test_attachToken_happyPath_conDeployerExplicito() public {
        RobinShareVault v = _github();
        MockCurve c = new MockCurve(address(v), escrow);
        pons.setLaunchFull(REAL_TOKEN, address(c), address(v), address(0), false);
        pons.setLaunchDeployer(REAL_TOKEN, launcher); // explicito, no derivado
        vm.prank(makeAddr("tercero-cualquiera"));
        v.attachToken(REAL_TOKEN);
        assertEq(v.token(), REAL_TOKEN);
    }
}
