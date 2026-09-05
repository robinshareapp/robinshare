// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {RobinShareVault} from "../src/RobinShareVault.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {PonsAddresses} from "../src/pons/PonsAddresses.sol";
import {IXGeneralVerifier} from "../src/flap/IXGeneralVerifier.sol";
import {
    IPonsV2Launchpad,
    IPonsV2Curve,
    IPonsV2LaunchFactory,
    IV2FeeEscrow,
    PonsSocials,
    PonsTokenParams
} from "../src/pons/IPonsV2.sol";

/// @title ForkPons — el ciclo entero contra los contratos REALES de pons v2
///
/// @notice Esto es LA prueba que los mocks no pueden dar. `RobinShare.t.sol` corre contra un
///         `MockCurve` / `MockFeeEscrow` que hacen exactamente lo que yo creo que hace pons; si mi
///         lectura del protocolo estuviera mal, el suite entero seguiria en verde y el error solo
///         aparecerìa el dia del launch. Aca no hay mocks: se lanza un token de verdad contra
///         `0x7eD5...EC7e`, se tradea de verdad, y la plata la acredita el `V2FeeEscrow` real.
///
///         Corre con:
///           forge test --match-contract ForkPonsTest --fork-url robinhood -vv
///         Sin `--fork-url` los tests se reportan SKIPPED (no PASS: un verde falso es peor que un
///         rojo — es la leccion que ya nos habia costado el `Fork.t.sol` del rail de Flap).
///
/// @dev Eslabon por eslabon, lo que cada test PRUEBA contra la cadena real:
///        1. que `launchToken` acepta un vault como `creatorFeeRecipient`;
///        2. que la curva reconoce a ese vault como su `deployer` — la asuncion central del
///           diseno, y la unica que si estuviera mal tiraria abajo el port entero;
///        3. que el vault (y NO el que lanzo) esta autorizado a `sweepFees`;
///        4. que el escrow real acredita en ETH nativo bajo la clave del vault;
///        5. que `claim()` msg.sender-only entra por el `receive()` del vault;
///        6. que un dev con CERO ETH cobra, con un relayer pagando el gas;
///        7. que `withdraw()` (payout pull) le paga al boundWallet;
///        8. que un launch pareado contra un ERC-20 REAL y aprobado se RECHAZA en `attachToken`.
contract ForkPonsTest is Test {
    /// @dev Attester de prueba. Es la PK 0 de anvil: publica y quemada a proposito — nunca debe
    ///      existir una llave real en el repo.
    uint256 constant ATTESTER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice ERC-20 aprobado como par en pons (medido: `approvedPairTokens(NVDA)` = true,
    ///         18 decimales, `pairTokenEconomics` = 16,64 / 41,60). Se usa para probar el RECHAZO.
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    IPonsV2Launchpad constant PONS = IPonsV2Launchpad(PonsAddresses.LAUNCH_FACTORY);
    IV2FeeEscrow constant ESCROW = IV2FeeEscrow(PonsAddresses.FEE_ESCROW);

    /// @notice Ventana del snipe tax de pons, medida en vivo: `snipeTaxStartBps` 9900 decayendo a
    ///         cero en `snipeTaxSeconds` = 3 s. Todo trade DENTRO de esa ventana paga un take
    ///         brutal que NO representa la economia del producto — ver `_warpPastSnipeWindow`.
    uint256 constant SNIPE_TAX_SECONDS = 3;

    RobinShareVaultFactory factory;
    address attester;
    address launcher;

    /// @dev El fork se saltea si el test no corre sobre Robinhood Chain. `vm.skip` y no un
    ///      `return`: un early-return lo reporta forge como [PASS] sin haber ejecutado nada.
    modifier onlyFork() {
        // `vm.skip` y no un `return`: un early-return lo reporta forge como [PASS] sin haber
        // ejecutado nada. Pero un SKIP tambien deja `forge test` en exit 0, asi que un CI que
        // corra el suite sin `--fork-url` queda verde sin haber probado NADA contra pons.
        // `REQUIRE_FORK=1` convierte ese skip en un fallo, para poder exigirlo en CI.
        if (block.chainid != PonsAddresses.CHAIN_ID) {
            if (vm.envOr("REQUIRE_FORK", false)) {
                fail("REQUIRE_FORK=1 pero no se corrio contra un fork de Robinhood Chain");
            }
            vm.skip(true);
        }
        _;
    }

    function setUp() public {
        if (block.chainid != PonsAddresses.CHAIN_ID) return;
        attester = vm.addr(ATTESTER_PK);
        factory = new RobinShareVaultFactory(
            attester,
            PonsAddresses.FEE_ESCROW,
            PonsAddresses.LAUNCH_FACTORY,
            PonsAddresses.X_GENERAL_VERIFIER,
            address(0) // attesterAdmin: sin co-gate en el fork
        );
        // Direccion FRESCA a proposito. Las cuentas default de anvil estan intervenidas en
        // Robinhood mainnet con delegaciones EIP-7702 de un sweeper (`0x0436...f2d7`): el ETH que
        // reciben desaparece. Documentado en docs/ENSAYO-LAUNCH-2026-07-17.md.
        launcher = makeAddr("robinshare-launcher");
        vm.deal(launcher, 10 ether);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _params(address vault, uint16 taxBps, bool buyback, address pairToken, bytes32 salt)
        internal
        view
        returns (PonsTokenParams memory p)
    {
        p.name = "RobinShare Fork Pilot";
        p.symbol = "RSFORK";
        p.logo = "";
        p.description = "fees routed to a builder's identity";
        p.socials = PonsSocials("", "", "", "", "");
        p.creatorFeeRecipient = vault;
        p.creatorTaxBps = taxBps;
        p.buybackEnabled = buyback;
        // Pin de economia: si el owner de pons re-pegara los terminos entre el quote y el envio,
        // el launch revierte en vez de aterrizar bajo otras reglas.
        p.expectedEconomics = PONS.previewLaunchEconomics(PonsAddresses.LAUNCH_CONFIG_ID, pairToken);
        p.salt = salt;
    }

    /// @dev El flujo del producto, tal cual lo hara `/create`: vault primero (su direccion entra
    ///      en la creation code de la curva, asi que el token no se puede predecir antes), despues
    ///      el launch, despues el link auto-verificable.
    function _createVaultAndLaunch(uint16 taxBps, bytes32 salt)
        internal
        returns (RobinShareVault vault, address token, address curve)
    {
        vm.startPrank(launcher);
        vault = RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 0)));
        (token, curve) = PONS.launchToken{value: PONS.launchFee()}(
            _params(address(vault), taxBps, false, address(0), salt),
            PonsAddresses.LAUNCH_CONFIG_ID,
            address(0)
        );
        vault.attachToken(token);
        vm.stopPrank();
    }

    function _buy(address trader, address curve, uint256 amount) internal {
        vm.deal(trader, amount);
        vm.prank(trader);
        IPonsV2Curve(curve).buy{value: amount}(amount, 0, trader);
    }

    /// @dev SIN ESTO TODOS LOS NUMEROS DE ESTE ARCHIVO MIENTEN.
    ///
    ///      `vm.prank` no adelanta el reloj, asi que sin un warp explicito cada compra del test
    ///      cae en el SEGUNDO DEL LANZAMIENTO, donde el snipe tax de pons esta en su maximo. Y el
    ///      snipe tax **se suma al bucket del creador**: la fuente verificada dice
    ///      `_accrueFees(fee + snipeTax, tax)`, y el sweep reparte ese bucket 30/70 entre
    ///      protocolo y creador.
    ///
    ///      Aritmetica de las dos regimenes, con la config viva (curveFeeBps 100, creatorTaxBps
    ///      1000, protocolFeeShareBps 3000, snipe cap = 10000-100-1000-100 = 8800):
    ///        · dentro de la ventana: (1% + 88%) x 70% + 10% = **72,3%** del volumen
    ///        · en regimen normal:    (1%      ) x 70% + 10% = **10,7%** del volumen
    ///
    ///      Una version anterior de este test media la primera y la publicaba como si fuera la
    ///      segunda — un 7x de diferencia en el numero que justifica el producto entero. Lo cazo
    ///      un revisor externo. `test_fork_feeSplit_dosRegimenes` fija las dos cifras.
    function _warpPastSnipeWindow() internal {
        vm.warp(block.timestamp + SNIPE_TAX_SECONDS + 1);
    }

    // ───────────────────────── el ciclo entero ─────────────────────────

    function test_fork_fullCycle_nativePair() public onlyFork {
        (RobinShareVault vault, address token, address curve) =
            _createVaultAndLaunch(PonsAddresses.MAX_CREATOR_TAX_BPS, keccak256("robinshare/fork/full"));

        // (1) el registro del factory REAL confirma como quedo el launch
        IPonsV2LaunchFactory.LaunchedToken memory info =
            IPonsV2LaunchFactory(PonsAddresses.LAUNCH_FACTORY).getLaunchedToken(token);
        assertTrue(info.exists, "el launch debe existir en el registro de pons");
        assertEq(info.creatorFeeRecipient, address(vault), "las fees deben apuntar al vault");
        assertEq(info.pairToken, address(0), "par nativo");
        assertFalse(info.buybackEnabled, "buyback DEBE quedar apagado");
        assertEq(info.deployer, launcher, "el deployer sigue siendo quien lanzo");
        assertEq(vault.token(), token);
        assertEq(vault.curve(), curve);

        // (2) LA asuncion central del port: `curve.deployer()` NO es quien lanzo, es el
        //     creatorFeeRecipient vigente. Si esto fuera falso el vault no podria barrer nunca.
        assertEq(IPonsV2Curve(curve).deployer(), address(vault), "la curva debe autorizar al vault");

        // (3) trades reales contra la curva real, FUERA de la ventana del snipe tax: lo que se
        //     mide aca es la economia de todos los dias, no el segundo del lanzamiento.
        _warpPastSnipeWindow();
        _buy(makeAddr("trader-a"), curve, 0.4 ether);
        _buy(makeAddr("trader-b"), curve, 0.35 ether);

        // (4) el que LANZO no esta autorizado a barrer — solo el recipient. Es lo que hace que
        //     `sweepCurve()` tenga que vivir en el vault y no en un script del launcher.
        vm.prank(launcher);
        vm.expectRevert(); // NotFeeSweepOperator()
        IPonsV2Curve(curve).sweepFees(0);

        // (5) sweepCurve: de la curva al escrow. Permissionless — lo paga un tercero cualquiera.
        assertEq(ESCROW.balanceOf(address(vault)), 0, "todavia nada acreditado");
        vm.prank(makeAddr("random-keeper"));
        vault.sweepCurve();
        uint256 credited = ESCROW.balanceOf(address(vault));
        assertGt(credited, 0, "el escrow real debe acreditar al vault");
        console2.log("acreditado en el V2FeeEscrow real (wei):", credited);

        // (6) pull: del escrow al vault. `claim()` es msg.sender-only, asi que esto SOLO lo puede
        //     hacer el vault, y el ETH entra por su `receive()` con todo el gas reenviado.
        vm.prank(makeAddr("random-keeper"));
        uint256 pulled = vault.pull();
        assertEq(pulled, credited, "pull() debe traer todo lo acreditado");
        assertEq(address(vault).balance, credited, "el ETH tiene que estar en el vault");
        assertEq(ESCROW.balanceOf(address(vault)), 0, "el ledger de pons queda en cero");

        // (7) el claim RELAYADO: el dev no tiene un wei y aun asi cobra.
        address dev = makeAddr("dev-sin-wallet");
        assertEq(dev.balance, 0, "el dev arranca con CERO ETH");
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, vault.bindDigest(dev, deadline));
        address relayer = makeAddr("relayer");
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        vault.claimAndBind(dev, deadline, abi.encodePacked(r, s, v));
        assertEq(vault.boundWallet(), dev);
        assertEq(dev.balance, credited, "el dev cobro sin haber pagado gas");
        console2.log("cobrado por un dev con 0 ETH (wei):", dev.balance);

        assertEq(credited, 0.75 ether * 107 / 1000, "10,7% del volumen: el regimen normal");

        // (8) payout PULL: mas trades, y el boundWallet retira por su cuenta.
        _buy(makeAddr("trader-c"), curve, 0.3 ether);
        uint256 before = dev.balance;
        vm.prank(dev);
        vault.withdraw(); // hace sweepCurve + pull adentro
        assertGt(dev.balance, before, "withdraw() debe barrer, cobrar y pagar en una sola llamada");
        assertEq(address(vault).balance, 0, "el vault queda vacio");
        console2.log("retirado con withdraw() (wei):", dev.balance - before);
    }

    // ───────────────────────── el rechazo del par ERC-20 ─────────────────────────

    /// @notice El carril que entregaria CERO. `attachToken` lo corta en el contrato, no en la UI.
    /// @dev No es un caso de borde: se midio que ~50% de los launches de pons cotizan contra un
    ///      ERC-20. Con par ERC-20 las fees se acreditan en el ledger POR TOKEN
    ///      (`balanceOfToken`), `pendingAmount()` da 0 y `withdraw()` revierte — y con
    ///      `recoveryDays > 0` la plata quedaba encerrada para siempre. Mejor rechazar el launch.
    function test_fork_rejectsErc20PairedLaunch() public onlyFork {
        assertTrue(PONS.approvedPairTokens(NVDA), "NVDA debe seguir aprobado como par en pons");

        vm.startPrank(launcher);
        RobinShareVault vault = RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 0)));
        (address token,) = PONS.launchToken{value: PONS.launchFee()}(
            _params(address(vault), 500, false, NVDA, keccak256("robinshare/fork/erc20")),
            PonsAddresses.LAUNCH_CONFIG_ID,
            NVDA
        );
        vm.stopPrank();

        // el launch SI existe en pons y apunta al vault: lo que se rechaza es atarlo.
        IPonsV2LaunchFactory.LaunchedToken memory info =
            IPonsV2LaunchFactory(PonsAddresses.LAUNCH_FACTORY).getLaunchedToken(token);
        assertEq(info.pairToken, NVDA, "el launch quedo pareado contra NVDA");
        assertEq(info.creatorFeeRecipient, address(vault));

        vm.expectRevert(RobinShareVault.PairMustBeNative.selector);
        vault.attachToken(token);
        assertEq(vault.token(), address(0), "el vault no se ata a un launch que no puede cobrar");
    }

    /// @notice Gemelo del anterior para el buyback: con buyback activo `buybackBurnBps` se lleva
    ///         la mitad del bucket del creador y la vestea 5 anios.
    function test_fork_rejectsBuybackEnabledLaunch() public onlyFork {
        vm.startPrank(launcher);
        RobinShareVault vault = RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 0)));
        (address token,) = PONS.launchToken{value: PONS.launchFee()}(
            _params(address(vault), 500, true, address(0), keccak256("robinshare/fork/buyback")),
            PonsAddresses.LAUNCH_CONFIG_ID,
            address(0)
        );
        vm.stopPrank();

        vm.expectRevert(RobinShareVault.BuybackMustBeDisabled.selector);
        vault.attachToken(token);
    }

    /// @notice `attachToken` es permissionless pero auto-verificable: la verdad la da la cadena.
    function test_fork_rejectsForeignLaunch() public onlyFork {
        vm.startPrank(launcher);
        RobinShareVault mine = RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 0)));
        // un launch cuyas fees van a otra parte (al propio launcher)
        (address token,) = PONS.launchToken{value: PONS.launchFee()}(
            _params(launcher, 500, false, address(0), keccak256("robinshare/fork/foreign")),
            PonsAddresses.LAUNCH_CONFIG_ID,
            address(0)
        );
        vm.stopPrank();

        vm.expectRevert(RobinShareVault.NotOurLaunch.selector);
        mine.attachToken(token);
    }

    // ───────────────────────── liveness y no-ops ─────────────────────────

    /// @notice Sin nada acumulado, las rutas de cobro NO revierten.
    /// @dev El `claim()` de pons revierte `NoBalance()` con saldo cero. Sin la guarda de balance
    ///      previa, cualquiera podria griefear las rutas de claim llamandolas primero.
    function test_fork_harvestIsNoopWhenEmpty() public onlyFork {
        (RobinShareVault vault,,) =
            _createVaultAndLaunch(300, keccak256("robinshare/fork/empty"));

        assertEq(ESCROW.balanceOf(address(vault)), 0);
        vm.prank(makeAddr("griefer"));
        assertEq(vault.harvest(), 0, "harvest sin saldo debe ser un no-op, no un revert");
        assertEq(vault.pendingAmount(), 0);

        // y el claim sigue funcionando despues del intento de grief
        address dev = makeAddr("dev-sin-fees");
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, vault.bindDigest(dev, deadline));
        vault.claimAndBind(dev, deadline, abi.encodePacked(r, s, v));
        assertEq(vault.boundWallet(), dev);
    }

    /// @notice El `receive()` tiene que aguantar el pago del escrow real sin revertir ni comerse
    ///         el gas: pons paga con `.call` reenviando TODO (sin stipend) y convierte cualquier
    ///         fallo en `TransferFailed()`, lo que dejaria el credito trabado del lado de ellos.
    function test_fork_receiveIsCheapAndInfallible() public onlyFork {
        (RobinShareVault vault,,) = _createVaultAndLaunch(300, keccak256("robinshare/fork/receive"));
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(vault).call{value: 0.25 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok, "receive() no puede fallar");
        assertLt(gasUsed, 50_000, "receive() debe ser barato");
        assertEq(vault.pendingAmount(), 0.25 ether);
    }

    /// @notice El ERC-20 que llega sin aviso sale, y solo al boundWallet.
    /// @dev `rescuePoolFees` del hook de pons (onlyOwner) NO pasa por el escrow: hace
    ///      `safeTransfer` directo al creatorFeeRecipient. Se simula con NVDA real.
    function test_fork_strandedErc20ExitsToBoundWalletOnly() public onlyFork {
        (RobinShareVault vault,,) = _createVaultAndLaunch(300, keccak256("robinshare/fork/erc20-rescue"));

        deal(NVDA, address(vault), 5e18);
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 5e18);

        // sin bind, nadie lo puede sacar
        vm.expectRevert(RobinShareVault.NotBoundYet.selector);
        vault.withdrawToken(NVDA);

        address dev = makeAddr("dev-erc20");
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, vault.bindDigest(dev, deadline));
        vault.claimAndBind(dev, deadline, abi.encodePacked(r, s, v));

        // un tercero tampoco, ni siquiera despues del bind
        vm.prank(makeAddr("ladron"));
        vm.expectRevert(RobinShareVault.NotBoundWallet.selector);
        vault.withdrawToken(NVDA);

        vm.prank(dev);
        vault.withdrawToken(NVDA);
        assertEq(IERC20(NVDA).balanceOf(dev), 5e18, "el ERC-20 sale, y solo al boundWallet");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 0);
    }

    // ───────────────────────── la economia, en sus dos regimenes ─────────────────────────

    /// @notice Fija las DOS cifras del take del creador contra la curva real, para que nadie
    ///         vuelva a publicar una por la otra.
    /// @dev El snipe tax de pons no es un bucket aparte: la fuente verificada hace
    ///      `_accrueFees(fee + snipeTax, tax)`, asi que en la ventana de lanzamiento el creador
    ///      cobra una fortuna que no tiene nada que ver con la economia del producto.
    function test_fork_feeSplit_dosRegimenes() public onlyFork {
        // (a) DENTRO de la ventana del snipe tax (el segundo del lanzamiento)
        (RobinShareVault sniped,, address snipedCurve) =
            _createVaultAndLaunch(PonsAddresses.MAX_CREATOR_TAX_BPS, keccak256("robinshare/fork/snipe"));
        _buy(makeAddr("sniper"), snipedCurve, 1 ether);
        vm.prank(makeAddr("k1"));
        sniped.sweepCurve();
        uint256 inWindow = ESCROW.balanceOf(address(sniped));
        assertEq(inWindow, 0.723 ether, "en la ventana el creador se lleva 72,3% del volumen");

        // (b) FUERA de la ventana: el regimen en el que vive el 99,99% de la vida del token
        (RobinShareVault normal,, address normalCurve) =
            _createVaultAndLaunch(PonsAddresses.MAX_CREATOR_TAX_BPS, keccak256("robinshare/fork/normal"));
        _warpPastSnipeWindow();
        _buy(makeAddr("trader"), normalCurve, 1 ether);
        vm.prank(makeAddr("k2"));
        normal.sweepCurve();
        uint256 steady = ESCROW.balanceOf(address(normal));
        assertEq(steady, 0.107 ether, "en regimen normal el creador se lleva 10,7% del volumen");

        console2.log("take en la ventana del snipe tax (wei por ETH de volumen):", inWindow);
        console2.log("take en regimen normal           (wei por ETH de volumen):", steady);
    }

    // ───────────────────────── el caso post-graduacion ─────────────────────────

    /// @notice El caso que el spec §14 marcaba obligatorio y no existia: que pasa DESPUES de que
    ///         la curva gradua. Se cruza el umbral REAL (4,2 ETH) contra la curva REAL.
    ///
    /// @dev Lo que este test fija, y que antes solo estaba en la cabeza del que lo escribio:
    ///        · `sweepFees` de la curva revierte para siempre una vez graduada;
    ///        · el `try/catch` de `_sweepCurve()` se lo traga, asi que `harvest()` NO revierte
    ///          y las rutas de claim/withdraw siguen vivas;
    ///        · lo ya barrido antes de graduar sigue siendo cobrable con `pull()`;
    ///        · el vault NO tiene ninguna ruta hacia las fees del pool post-graduacion: depende
    ///          del operador de pons. Es una perdida de LIVENESS, no de fondos.
    function test_fork_postGraduation_noRompeElVaultYLoBarridoSigueCobrable() public onlyFork {
        (RobinShareVault vault, address token, address curve) =
            _createVaultAndLaunch(PonsAddresses.MAX_CREATOR_TAX_BPS, keccak256("robinshare/fork/grad"));
        _warpPastSnipeWindow();

        // barrer ANTES de graduar: esta plata tiene que sobrevivir a la graduacion
        _buy(makeAddr("early"), curve, 1 ether);
        vault.sweepCurve();
        uint256 antes = ESCROW.balanceOf(address(vault));
        assertGt(antes, 0);

        // Cruzar el umbral real de graduacion (4,2 ETH).
        //
        // HALLAZGO del fork, que ningun mock daba: la graduacion NO hay que dispararla. La
        // ejecuta el propio `buy()` que cruza el umbral, dentro de la misma transaccion del
        // comprador. Por eso el bucle corta con `graduated()` y no con `readyToGraduate()`:
        // llamar `graduate()` despues revierte, y un `buy()` mas tambien (`CurveGraduated()`).
        for (uint256 i = 0; i < 10 && !IPonsV2Curve(curve).graduated(); i++) {
            _buy(makeAddr(string.concat("whale", vm.toString(i))), curve, 1 ether);
        }
        assertTrue(IPonsV2Curve(curve).graduated(), "la curva graduo de verdad");
        token; // el registro de pons ya la marco; no hace falta llamar graduate() a mano

        // Y la graduacion ACREDITA al vault en el camino: barre las fees pendientes antes de
        // cerrar la curva, asi que no hay nada que se pierda en el borde. Medido en el trace:
        // `credit(vault, 0.3979 ETH)` desde la curva, dentro del mismo buy.
        assertGt(
            ESCROW.balanceOf(address(vault)),
            antes,
            "graduar tiene que barrer lo pendiente hacia el escrow, no tirarlo"
        );

        // 1. la curva ya no se puede barrer, NUNCA
        vm.expectRevert();
        IPonsV2Curve(curve).sweepFees(0);

        // 2. pero el vault no se rompe: el try/catch se lo traga
        vm.prank(makeAddr("keeper"));
        vault.sweepCurve();

        // 3. y todo lo acreditado se cobra igual
        uint256 acreditado = ESCROW.balanceOf(address(vault));
        assertGe(acreditado, antes, "la graduacion no puede evaporar lo ya acreditado");
        vault.pull();
        assertGe(address(vault).balance, antes);
        console2.log("acreditado al vault al graduar (wei):", acreditado);

        // 4. el claim sigue funcionando despues de graduar
        address dev = makeAddr("dev-post-grad");
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(ATTESTER_PK, vault.bindDigest(dev, deadline));
        vm.prank(makeAddr("relayer2"));
        vault.claimAndBind(dev, deadline, abi.encodePacked(r, sg, v));
        assertEq(vault.boundWallet(), dev);
        assertGt(dev.balance, 0, "el dev cobra igual despues de la graduacion");
        console2.log("cobrado post-graduacion (wei):", dev.balance);
    }

    // ───────────────────────── la ruta X contra el verifier REAL ─────────────────────────

    /// @notice El spec §14 senalaba con nombre y apellido que "no existe un solo test que no use
    ///         un mock con un bool seteable". Esto lo cierra a medias: la llamada llega al
    ///         `XGeneralVerifier` REAL de Flap desplegado en 4663.
    ///
    /// @dev LO QUE PRUEBA: que el verifier real esta vivo y tiene codigo, que el vault lo llama
    ///      de verdad, y que NO firma cualquier cosa — una prueba forjada se rechaza.
    ///      LO QUE NO PRUEBA: el camino positivo. Para eso hace falta una firma real del oraculo
    ///      de Flap sobre un tweet real, que no se puede fabricar en un test. Ese eslabon sigue
    ///      SIN PROBAR, y esta declarado como tal en el spec y en PENDIENTES.
    function test_fork_rutaX_llegaAlVerifierRealYRechazaUnaPruebaForjada() public onlyFork {
        assertGt(PonsAddresses.X_GENERAL_VERIFIER.code.length, 0, "el verifier real debe tener codigo");

        vm.prank(launcher);
        RobinShareVault v =
            RobinShareVault(payable(factory.createVault(2, "0xkeezy", address(0), 0)));
        assertEq(v.xVerifier(), PonsAddresses.X_GENERAL_VERIFIER, "el vault apunta al verifier real");

        address dev = makeAddr("dev-x");
        IXGeneralVerifier.XGeneralProof memory proof = IXGeneralVerifier.XGeneralProof({
            tweetId: 1,
            xHandle: "0xkeezy",
            xId: 1,
            substring: v.expectedTweet(dev) // pasa los chequeos (1) y (2)
        });

        // (3) el verifier REAL tiene que rechazar una firma que no es del oraculo.
        //
        //     OJO con la forma de la firma, que es un hallazgo del fork: con bytes malformados
        //     (`hex"deadbeef"`) el verifier NO devuelve false — revierte
        //     "ECDSA: invalid signature length" desde adentro. O sea que `claimByProof` propaga
        //     el error de Flap en vez del nuestro. No es un agujero (igual se rechaza), pero un
        //     integrador que espere `InvalidProof` para TODA firma invalida se equivoca.
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(uint256(0xBADBEEF), keccak256("no soy el oraculo"));
        bytes memory wellFormedButWrong = abi.encodePacked(br, bs, bv);

        assertFalse(
            IXGeneralVerifier(PonsAddresses.X_GENERAL_VERIFIER).verify(proof, wellFormedButWrong),
            "el verifier real no puede aceptar una firma que no es del oraculo"
        );
        vm.expectRevert(RobinShareVault.InvalidProof.selector);
        v.claimByProof(dev, proof, wellFormedButWrong);

        // una firma con la LONGITUD mal revierte adentro del verifier de Flap, no en el nuestro
        vm.expectRevert();
        v.claimByProof(dev, proof, hex"deadbeef");

        // y el handle equivocado ni siquiera llega al verifier
        proof.xHandle = "otro";
        vm.expectRevert(RobinShareVault.WrongXHandle.selector);
        v.claimByProof(dev, proof, wellFormedButWrong);
    }
}
