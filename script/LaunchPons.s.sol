// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RobinShareVault} from "../src/RobinShareVault.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {PonsAddresses} from "../src/pons/PonsAddresses.sol";
import {
    IPonsV2Launchpad,
    IPonsV2Curve,
    IPonsV2LaunchFactory,
    PonsSocials,
    PonsTokenParams
} from "../src/pons/IPonsV2.sol";

/// @title LaunchPons — las TRES transacciones del launch, en un solo comando
///
/// @notice Reemplaza la Opcion B del runbook (tres `cast send` a mano). No es comodidad: el
///         launch es la UNICA transaccion irreversible del producto, y el comando escrito a mano
///         ya fallo DOS veces por comillas del shell — una en el review y otra corriendolo de
///         verdad contra un fork. Un `cast send` que no parsea es barato; uno que parsea MAL y
///         manda 0,0005 ETH con los campos corridos, no.
///
///         Aca los parametros son tipados, el orden lo pone el compilador, y todo lo que se puede
///         chequear se chequea ANTES de gastar un wei.
///
/// @dev USO — primero SIN --broadcast (simula y no manda nada):
///
///   export FACTORY=0x...            # la RobinShareVaultFactory ya deployada
///   export NAME="RobinShare Pilot"
///   export SYMBOL=RSHARE
///   export IDENTITY_TYPE=1          # 0 wallet · 1 github · 2 x
///   export IDENTITY_VALUE=0x-keezy  # vacio si es wallet
///   export IDENTITY_WALLET=0x0000000000000000000000000000000000000000
///   export RECOVERY_DAYS=0          # 0 = nunca (el default del producto)
///   export CREATOR_TAX_BPS=1000     # 10,00%
///   export LOGO=https://github.com/0x-keezy.png
///   export DESCRIPTION="fees routed to a builder"
///
///   forge script script/LaunchPons.s.sol --rpc-url robinhood --compute-units-per-second 40
///   # y recien despues, con --broadcast --private-key $DEPLOYER_PK
contract LaunchPons is Script {
    function run() external {
        require(block.chainid == PonsAddresses.CHAIN_ID, "wrong chain (expected 4663)");

        // Modo verify-only: no lanza nada, solo verifica un launch que YA ocurrio, contra la
        // cadena real. Es la contraparte honesta del `_verify` de la simulacion.
        address vv = vm.envOr("VERIFY_VAULT", address(0));
        if (vv != address(0)) {
            address vt = vm.envAddress("VERIFY_TOKEN");
            RobinShareVault vc = RobinShareVault(payable(vv));
            _verify(vv, vt, vc.curve(), vc.recoveryAfter() == 0 ? 0 : 30, _taxOf(vt));
            return;
        }

        RobinShareVaultFactory factory = RobinShareVaultFactory(vm.envAddress("FACTORY"));
        IPonsV2Launchpad pons = IPonsV2Launchpad(PonsAddresses.LAUNCH_FACTORY);

        // Los rangos se validan ANTES del cast. `uint16(vm.envUint(...))` trunca en SILENCIO:
        // `CREATOR_TAX_BPS=66036` pasaba como 500 (5%, no 10%) y el launch quedaba con la mitad
        // del take del creador para siempre, con el checklist post-launch en verde.
        uint256 rawType = vm.envUint("IDENTITY_TYPE");
        require(rawType <= 2, "IDENTITY_TYPE tiene que ser 0, 1 o 2");
        uint256 rawTax = vm.envUint("CREATOR_TAX_BPS");
        require(rawTax <= type(uint16).max, "CREATOR_TAX_BPS fuera de rango");

        uint8 identityType = uint8(rawType);
        string memory identityValue = vm.envOr("IDENTITY_VALUE", string(""));
        address identityWallet = vm.envOr("IDENTITY_WALLET", address(0));
        uint256 recoveryDays = vm.envOr("RECOVERY_DAYS", uint256(0));
        uint16 creatorTaxBps = uint16(rawTax);
        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");

        // ── DE QUE FASE ES ESTA CORRIDA ────────────────────────────────────────
        //
        // El vault NO se predice: se LEE de la cadena. Antes este script hacia las tres
        // transacciones de un saque y tomaba la direccion del vault del RETORNO de
        // `factory.createVault(...)` — pero en `forge script` ese retorno sale de la SIMULACION, y
        // `vm.startBroadcast()` solo graba las llamadas con la calldata ya encodeada. La direccion
        // de un vault es CREATE(factory, nonce_de_la_factory) —`createVault` hace `new
        // RobinShareVault(...)`, sin CREATE2— asi que cualquier `createVault` ajeno que se mine en
        // la ventana entre simular e incluir corre el nonce y desplaza la direccion.
        //
        // Lo que pasaba entonces era lo peor posible: el `creatorFeeRecipient` que viaja adentro
        // de `launchToken` apuntaba al vault del EXTRANO. Ese launch es definitivo y esta pago; el
        // extrano podia llamar `attachToken` (su `launcher` es el mismo que llama) y quedarse con
        // las fees de nuestra moneda, mientras nuestra tx 3 revertia `LaunchedByStranger`. Y no
        // hay vuelta atras: `transferCreatorFeeRecipient` de pons existe, pero esta gateado al
        // recipient VIGENTE — o sea, al extrano.
        //
        // La ventana no era teorica: LANZAR.md publicaba `/create` (Paso 3) ANTES del piloto
        // (Paso 4), asi que cualquiera podia correr el nonce apretando un boton.
        //
        // Ahora son dos corridas del MISMO comando:
        //   1a corrida -> no hay vault para esta identidad -> solo `createVault`, y para.
        //   2a corrida -> lo encuentra en la cadena (`getVaults`), lo verifica, y lanza.
        // La direccion que entra en la calldata de la 2a corrida se leyo del estado real.
        bytes32 idHash = factory.identityHashFor(identityType, identityValue, identityWallet);
        address[] memory yaExisten = factory.getVaults(idHash);
        address vaultOverride = vm.envOr("VAULT", address(0));
        bool forzarOtro = vm.envOr("ALLOW_SECOND_VAULT", false);

        address vault;
        if (vaultOverride != address(0)) {
            vault = vaultOverride;
        } else if (forzarOtro || yaExisten.length == 0) {
            _preflight(factory, pons, identityType, identityValue, identityWallet, creatorTaxBps, recoveryDays);
            _fase1(factory, identityType, identityValue, identityWallet, recoveryDays, yaExisten.length);
            return;
        } else if (yaExisten.length == 1) {
            vault = yaExisten[0];
        } else {
            console2.log("Hay", yaExisten.length, "vaults para esta identidad:");
            for (uint256 i = 0; i < yaExisten.length; i++) console2.log("   ", yaExisten[i]);
            revert("Mas de un vault para esta identidad: elegi cual con VAULT=0x...");
        }

        _assertVaultUsable(factory, vault, idHash, recoveryDays);
        _preflight(factory, pons, identityType, identityValue, identityWallet, creatorTaxBps, recoveryDays);

        uint256 fee = pons.launchFee();
        // El pin de la economia se lee JUSTO antes de lanzar: si el owner de pons re-pegara los
        // terminos entre esta lectura y el envio, el launch revierte en vez de aterrizar bajo
        // otras reglas.
        bytes32 economics =
            pons.previewLaunchEconomics(PonsAddresses.LAUNCH_CONFIG_ID, address(0));

        vm.startBroadcast();

        // ── 1/2 · el launch ─────────────────────────────────────────────────────
        // El vault ya existe y ya se verifico contra la cadena; su direccion NO se predice.
        PonsTokenParams memory p;
        p.name = name;
        p.symbol = symbol;
        p.logo = vm.envOr("LOGO", string(""));
        p.description = vm.envOr("DESCRIPTION", string(""));
        // Socials. La via "recomendada" lanzaba el token MAS PELADO de las tres —sin website,
        // sin twitter— mientras la opcion a mano del runbook si mandaba el github del dev. Para
        // una moneda cuyo pitch es "las fees van a este builder", la pagina de pons sin un solo
        // link es un defecto de producto, y `TokenParams` se congela en el launch.
        string memory website = vm.envOr("WEBSITE", string(""));
        if (bytes(website).length == 0 && identityType == 1 && bytes(identityValue).length > 0) {
            website = string.concat("https://github.com/", identityValue);
        }
        string memory twitter = vm.envOr("TWITTER", string(""));
        if (bytes(twitter).length == 0 && identityType == 2 && bytes(identityValue).length > 0) {
            twitter = string.concat("https://x.com/", identityValue);
        }
        p.socials = PonsSocials(twitter, vm.envOr("TELEGRAM", string("")), "", website, "");
        p.creatorFeeRecipient = vault;
        p.creatorTaxBps = creatorTaxBps;
        p.buybackEnabled = false; // NUNCA true: `attachToken` lo rechaza y el launch quedaria huerfano
        p.expectedEconomics = economics;
        // Salt: pons lo namespacea por cuenta, asi que solo tiene que ser un valor que esta
        // wallet no haya usado. No hay vanity que minar.
        p.salt = keccak256(abi.encode(vault, block.timestamp, name, symbol));

        (address token, address curve) =
            pons.launchToken{value: fee}(p, PonsAddresses.LAUNCH_CONFIG_ID, address(0));
        console2.log("1/2  token:", token);
        console2.log("     curve:", curve);

        // ── 2/2 · atar vault <-> token ──────────────────────────────────────────
        //
        // `token` SI viene de la simulacion, y eso esta bien: pons lo deriva por CREATE2 del
        // `salt` que viaja en la calldata, y el `creatorFeeRecipient` de ese salt es NUESTRO vault
        // ya verificado. Si aun asi la direccion difiriera, esta tx revierte y no se pierde nada
        // irreversible: el token quedaria lanzado apuntando igual a nuestro vault, y `attachToken`
        // se puede llamar despues a mano. Es un riesgo recuperable, a diferencia del del vault.
        RobinShareVault(payable(vault)).attachToken(token);
        console2.log("2/2  atado");

        vm.stopBroadcast();

        _verify(vault, token, curve, recoveryDays, creatorTaxBps);
    }

    /// @dev FASE 1 — crear el vault y NADA MAS.
    ///
    ///      Se corta aca a proposito. La direccion que devuelve `createVault` en la simulacion no
    ///      es de fiar (ver el comentario largo en `run`), asi que no se usa para nada: la 2a
    ///      corrida la lee del estado real con `getVaults`.
    function _fase1(
        RobinShareVaultFactory factory,
        uint8 identityType,
        string memory identityValue,
        address identityWallet,
        uint256 recoveryDays,
        uint256 yaHabia
    ) internal {
        vm.startBroadcast();
        address predicha = factory.createVault(identityType, identityValue, identityWallet, recoveryDays);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== FASE 1 de 2 - vault creado ===");
        console2.log("  (direccion predicha en simulacion, NO la uses:", predicha, ")");
        if (yaHabia > 0) console2.log("  ATENCION: ya habia", yaHabia, "vault(s); creaste otro por ALLOW_SECOND_VAULT");
        console2.log("");
        console2.log("  Ahora corre EL MISMO comando otra vez (sin ALLOW_SECOND_VAULT).");
        console2.log("  La 2a corrida lee el vault real de la cadena, lo verifica, y lanza la moneda.");
        console2.log("");
    }

    /// @dev Todo lo que hay que ser cierto del vault ANTES de pagar un launch irreversible.
    ///      Corre pre-broadcast, o sea contra el estado REAL de la cadena.
    function _assertVaultUsable(
        RobinShareVaultFactory factory,
        address vault,
        bytes32 idHash,
        uint256 recoveryDays
    ) internal view {
        require(vault.code.length > 0, "VAULT no tiene codigo en esta red");
        require(factory.isVault(vault), "VAULT no salio de esta factory");

        // Pertenencia al indice de la identidad: prueba que el vault es de ESTA identidad y no de
        // otra. Cubre el caso de un VAULT=0x... pegado a mano de otro launch.
        address[] memory vs = factory.getVaults(idHash);
        bool esta;
        for (uint256 i = 0; i < vs.length; i++) {
            if (vs[i] == vault) {
                esta = true;
                break;
            }
        }
        require(esta, "VAULT no corresponde a la identidad de IDENTITY_TYPE/IDENTITY_VALUE");

        RobinShareVault v = RobinShareVault(payable(vault));
        require(v.token() == address(0), "ese vault YA tiene una moneda atada: lanzarle otra la dejaria huerfana");
        require(
            v.launcher() == msg.sender,
            "ese vault lo creo OTRA wallet: `attachToken` revertiria despues de pagar el launch. (En el ensayo pasa `--sender <tu address>`)"
        );

        // Coherencia con el env: el recovery se fijo al CREAR el vault, asi que cambiar
        // RECOVERY_DAYS entre las dos corridas no hace nada y el checklist final mentiria.
        if (recoveryDays == 0) {
            require(v.recoveryAfter() == 0, "el vault se creo CON recovery pero RECOVERY_DAYS=0");
        } else {
            require(v.recoveryAfter() != 0, "el vault se creo SIN recovery pero RECOVERY_DAYS>0");
        }

        _logVault(vault);
    }

    /// @dev Separado de `_assertVaultUsable` solo por el stack: juntos daban "stack too deep".
    function _logVault(address vault) internal view {
        RobinShareVault v = RobinShareVault(payable(vault));
        console2.log("--- fase 2: vault verificado contra la cadena ---");
        console2.log("  vault:          ", vault);
        console2.log("  launcher:       ", v.launcher());
        // Dos logs y no uno: `console2.log(string,string)` con una string de storage hacia
        // "stack too deep" en esta funcion.
        console2.log("  identityValue:");
        console2.log(v.identityValue());
        console2.log("-----------------");
    }

    /// @dev El creatorTaxBps que quedo registrado, para que el modo verify-only se compare
    ///      contra la cadena y no contra un env que puede haber cambiado.
    function _taxOf(address token) internal view returns (uint16) {
        return IPonsV2LaunchFactory(PonsAddresses.LAUNCH_FACTORY).getLaunchedToken(token).creatorTaxBps;
    }

    /// @dev Todo lo que se puede saber ANTES de gastar. Cada `require` de aca es un launch que no
    ///      se hizo mal.
    function _preflight(
        RobinShareVaultFactory factory,
        IPonsV2Launchpad pons,
        uint8 identityType,
        string memory identityValue,
        address identityWallet,
        uint16 creatorTaxBps,
        uint256 recoveryDays
    ) internal view {
        console2.log("--- preflight ---");

        require(address(factory).code.length > 0, "FACTORY no tiene codigo en esta red");

        // El try/catch no es decorativo: apuntar FACTORY a la direccion equivocada (la de pons,
        // por ejemplo) es un error plausible el dia del launch, y sin esto el script moria con un
        // "EvmError: Revert" pelado que no dice nada. Se niega igual — pero ahora se entiende.
        address att;
        try factory.attester() returns (address a) {
            att = a;
        } catch {
            revert("FACTORY no responde attester(): no es una RobinShareVaultFactory");
        }
        require(att != address(0), "la factory no tiene attester");
        console2.log("  factory:        ", address(factory));
        console2.log("  attester:       ", att);
        require(
            factory.feeEscrow() == PonsAddresses.FEE_ESCROW
                && factory.ponsFactory() == PonsAddresses.LAUNCH_FACTORY,
            "la factory apunta a OTRO rail: no es la del launch de pons"
        );

        // La guarda anti-duplicados ya NO vive aca: la estructura de dos fases la absorbio, y
        // mejor. Antes se contaban los vaults de la identidad y se exigia ALLOW_SECOND_VAULT si
        // habia alguno — pero ese contador tambien se dispara en la 2a corrida legitima, donde
        // encontrar el vault es justamente el punto.
        //
        // Ahora el caso que se queria atajar (el RPC devuelve HTML de Cloudflare mientras forge
        // espera un recibo, el operador ve un error y reintenta, y salen DOS $RSHARE "para
        // 0x-keezy") lo corta `_assertVaultUsable` con `token() == address(0)`, que es una guarda
        // ESTRICTAMENTE mas precisa: no pregunta "¿ya hay un vault?" sino "¿este vault ya tiene
        // una moneda?", que es la condicion que realmente importa.

        require(pons.launchEnabled(), "pons tiene el launch publico CERRADO ahora mismo");
        require(creatorTaxBps <= pons.maxCreatorTaxBps(), "CREATOR_TAX_BPS por encima del tope de pons");
        require(
            recoveryDays == 0 || (recoveryDays >= 30 && recoveryDays <= 3650),
            "RECOVERY_DAYS: 0 (nunca) o entre 30 y 3650"
        );

        console2.log("  launchFee:      ", pons.launchFee());
        console2.log("  maxCreatorTax:  ", pons.maxCreatorTaxBps());
        console2.log("  creatorTaxBps:  ", creatorTaxBps);
        console2.log("  recoveryDays:   ", recoveryDays);
        if (recoveryDays != 0) {
            console2.log("  !! con recovery > 0 el launcher puede recuperar el saldo si nadie");
            console2.log("     prueba la identidad. Verifica que el handle EXISTA de verdad.");
        }
        console2.log("-----------------");
    }

    /// @dev Los chequeos post-launch que el runbook pedia hacer a mano, en el mismo comando.
    ///
    ///      ⚠️ OJO CON LO QUE ESTO ES Y NO ES. En `forge script`, `run()` corre UNA vez en el EVM
    ///      de simulacion; `vm.startBroadcast()` solo GRABA las llamadas para mandarlas despues.
    ///      O sea que esto verifica el estado SIMULADO, y se imprime ANTES de que exista la
    ///      primera transaccion real. La simulacion corre contra estado fresco de la cadena y
    ///      forge aborta el broadcast entero si `run()` revierte, asi que cubre casi todo — pero
    ///      NO cubre una divergencia entre la simulacion y la inclusion (ej: el owner de pons
    ///      re-pega la fee en el medio). Foundry no tiene hook post-broadcast.
    ///
    ///      Para verificar contra la cadena DE VERDAD, despues del broadcast:
    ///        VERIFY_VAULT=0x... VERIFY_TOKEN=0x... forge script script/LaunchPons.s.sol --rpc-url robinhood
    function _verify(
        address vault,
        address token,
        address curve,
        uint256 recoveryDays,
        uint16 creatorTaxBps
    ) internal view {
        console2.log("--- verificacion post-launch ---");

        IPonsV2LaunchFactory.LaunchedToken memory info =
            IPonsV2LaunchFactory(PonsAddresses.LAUNCH_FACTORY).getLaunchedToken(token);

        require(info.exists, "pons no registro el launch");
        require(info.creatorFeeRecipient == vault, "las fees NO apuntan al vault");
        require(info.pairToken == address(0), "el launch quedo pareado contra un ERC-20");
        require(!info.buybackEnabled, "el buyback quedo prendido");
        // El unico parametro economico que eligio el operador, y no se verificaba: un
        // `CREATOR_TAX_BPS` truncado dejaba el launch con la mitad del take y todo en verde.
        require(info.creatorTaxBps == creatorTaxBps, "el creatorTaxBps registrado NO es el que pediste");

        // El que de verdad importa: si la curva no reconoce al vault, `sweepCurve()` revierte
        // para siempre y las fees quedan fuera de alcance.
        require(IPonsV2Curve(curve).deployer() == vault, "la curva NO autoriza al vault a barrer");

        RobinShareVault v = RobinShareVault(payable(vault));
        require(v.token() == token, "el vault no quedo atado al token");
        require(v.curve() == curve, "el vault no quedo atado a la curva");
        require((recoveryDays == 0) == (v.recoveryAfter() == 0), "recoveryAfter no coincide");
        console2.log("  recoveryAfter:  ", v.recoveryAfter());

        // La identidad NORMALIZADA, que es la que va a tener que probar el builder. `_normalize`
        // strippea el `@` y baja a minusculas: si quedo distinta de lo que el operador creia,
        // este es el unico lugar donde se ve antes de compartir el link.
        console2.log("  identidad:      ", v.identityValue());
        console2.log("  creatorTaxBps:  ", info.creatorTaxBps);
        console2.log("  fees -> vault:   OK");
        console2.log("  par nativo:      OK");
        console2.log("  buyback off:     OK");
        console2.log("  curva autoriza:  OK");
        console2.log("  vault atado:     OK");
        console2.log("");
        console2.log("LISTO. La pagina de claim del builder:");
        console2.log("  /claim/%s", vm.toString(vault));
        console2.log("recoveryAfter:", v.recoveryAfter());
    }
}
