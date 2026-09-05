// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPons} from "../script/DeployPons.s.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {RobinShareVault} from "../src/RobinShareVault.sol";
import {PonsAddresses} from "../src/pons/PonsAddresses.sol";

/// @title El script de deploy, testeado — porque un cableado mal puesto NO se puede arreglar
/// @notice `feeEscrow`, `ponsFactory` y `xVerifier` son INMUTABLES en la factory, y el vault los
///         copia a sus propios inmutables al crearse. Un error de tipeo en cualquiera de las
///         cinco direcciones no se corrige con una transaccion: hay que redeployar y abandonar
///         todos los vaults ya creados. Por eso el script se testea antes de correrlo, y por eso
///         las direcciones viven en `PonsAddresses` y no en el argumento de un comando.
contract DeployPonsTest is Test {
    DeployPons script;
    address attester = makeAddr("attester");
    address attesterAdmin = makeAddr("attester-admin");

    function setUp() public {
        script = new DeployPons();
    }

    function test_deploy_cableaLasDireccionesCanonicas() public {
        RobinShareVaultFactory f = script.deploy(attester, attesterAdmin);

        assertEq(f.attester(), attester, "attester");
        assertEq(f.attesterAdmin(), attesterAdmin, "attesterAdmin");
        assertEq(f.feeEscrow(), PonsAddresses.FEE_ESCROW, "feeEscrow");
        assertEq(f.ponsFactory(), PonsAddresses.LAUNCH_FACTORY, "ponsFactory");
        assertEq(f.xVerifier(), PonsAddresses.X_VERIFIER_AT_LAUNCH, "xVerifier");
    }

    /// @notice El cableado tiene que llegar hasta el VAULT, no quedarse en la factory.
    /// @dev Es la unica forma de cazar una factory que compila y despliega bien pero produce
    ///      vaults que apuntan al escrow equivocado — o sea, vaults que nunca podran cobrar.
    function test_deploy_losVaultsHeredanElRail() public {
        RobinShareVaultFactory f = script.deploy(attester, attesterAdmin);
        RobinShareVault v = RobinShareVault(payable(f.createVault(1, "torvalds", address(0), 0)));

        assertEq(address(v.feeEscrow()), PonsAddresses.FEE_ESCROW, "el vault cobra del escrow real");
        assertEq(address(v.ponsFactory()), PonsAddresses.LAUNCH_FACTORY, "verifica contra pons real");
        assertEq(v.attesterSource(), address(f), "el attester se lee EN VIVO de la factory");
        assertEq(v.attester(), attester);
    }

    /// @notice EL LANZAMIENTO VA SIN LA RUTA DE X, y esto lo clava.
    ///
    /// @dev Decision de Jose del 2026-08-31 (`PENDIENTES.md` seccion 4). No es una preferencia
    ///      reversible: `xVerifier` es immutable en la factory Y en el vault, y no hay setter en
    ///      ninguno de los dos. Si alguien "arregla" el deploy volviendo a poner el verifier de
    ///      Flap, la unica forma de enterarse es que este test se ponga rojo.
    ///
    ///      El motivo esta en PonsAddresses.X_VERIFIER_AT_LAUNCH: el camino positivo de X nunca
    ///      funciono end-to-end, y el oraculo es infra de un competidor que puede desaparecer
    ///      dejando el ETH de un builder atrapado para siempre.
    function test_deploy_vaSinRutaX() public {
        RobinShareVaultFactory f = script.deploy(attester, attesterAdmin);
        assertEq(f.xVerifier(), address(0), "el deploy tiene que ir con xVerifier = 0");
    }

    /// @notice Y con el verifier en cero, la ruta no existe ni por accidente.
    /// @dev No alcanza con no ofrecer X en la web: cualquiera puede llamar `createVault`
    ///      directamente contra el contrato. El rechazo tiene que estar en la cadena.
    function test_deploy_createVaultDeXRevierte() public {
        RobinShareVaultFactory f = script.deploy(attester, attesterAdmin);
        vm.expectRevert(RobinShareVaultFactory.ZeroAddress.selector);
        f.createVault(2, "0xkeezy", address(0), 0);
    }

    /// @notice GitHub y wallet siguen funcionando: sacar X no rompio las dos rutas que van.
    function test_deploy_githubYWalletSiguenVivos() public {
        RobinShareVaultFactory f = script.deploy(attester, attesterAdmin);
        RobinShareVault g = RobinShareVault(payable(f.createVault(1, "torvalds", address(0), 0)));
        assertEq(g.identityType(), 1);
        assertEq(g.xVerifier(), address(0), "un vault de GitHub no necesita verifier");
        RobinShareVault w = RobinShareVault(payable(f.createVault(0, "", address(0xBEEF), 0)));
        assertEq(w.identityType(), 0);
    }

    /// @notice `attesterAdmin = 0` es una eleccion valida (desactiva el co-gate), no un error.
    /// @dev Es una de las decisiones que quedan abiertas para Jose en PENDIENTES.md: con 0 nadie
    ///      puede rotar el attester salvo el attester mismo, asi que una llave perdida congela
    ///      para siempre el ETH de todos los vaults de GitHub.
    function test_deploy_aceptaAttesterAdminCero() public {
        RobinShareVaultFactory f = script.deploy(attester, address(0));
        assertEq(f.attesterAdmin(), address(0));
    }

    /// @notice El guard de cadena: el script no puede correr fuera de Robinhood Chain.
    function test_run_rechazaOtraCadena() public {
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain (expected 4663)"));
        script.run();
    }

    /// @notice Los args del constructor que van a `forge verify-contract`, calculados por el mismo
    ///         script — para que el runbook no dependa de copiar cinco direcciones a mano.
    function test_constructorArgs_matcheaElConstructorReal() public view {
        bytes memory args = script.constructorArgs(attester, attesterAdmin);
        assertEq(
            args,
            abi.encode(
                attester,
                PonsAddresses.FEE_ESCROW,
                PonsAddresses.LAUNCH_FACTORY,
                PonsAddresses.X_VERIFIER_AT_LAUNCH,
                attesterAdmin
            )
        );
    }
}
