// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobinShareVault} from "../src/RobinShareVault.sol";
import {RobinShareVaultFactory} from "../src/RobinShareVaultFactory.sol";
import {MockFeeEscrow, MockPonsFactory, MockXVerifier} from "./RobinShare.t.sol";

/// @title El vector que cose las DOS implementaciones del digest de bind
///
/// @notice Hay dos calculos del mismo digest EIP-712, en dos lenguajes distintos:
///
///           · Solidity — `RobinShareVault.bindDigest()`, que es lo que el contrato VERIFICA;
///           · TypeScript — `web/lib/bind.ts::bindDigestLocal()`, que es con lo que el attester
///             FIRMA, y ahora tambien con lo que el relayer decide si relaya.
///
///         Si divergen aunque sea en un byte —el nombre del dominio, la version, el typehash, el
///         orden de los campos, el chainId— el attester firma algo que el contrato rechaza y
///         **TODO claim de GitHub falla en cadena**. Sin ruido: la firma simplemente no valida.
///
/// @dev Y los tests de cada lado NO lo cazaban, porque cada uno se compara contra si mismo:
///      `web/test/bind.test.ts` verificaba `bindDigestLocal` contra `hashTypedData` del MISMO
///      objeto que acababa de construir, con el dominio hardcodeado a mano. Es el caso de
///      libro de dos puntas con tests verdes y la costura sin probar.
///
///      Este test genera el vector desde la FUENTE DE VERDAD (el contrato) y lo escribe a un
///      fixture commiteado. El test de la web lo lee y tiene que reproducirlo. Si cualquiera de
///      los dos lados se mueve, uno de los dos se pone rojo.
///
///      Regenerar: `forge test --match-contract BindVectorTest`
contract BindVectorTest is Test {
    /// @dev Direcciones y valores FIJOS: el vector tiene que ser reproducible.
    address constant PAYOUT = 0x2222222222222222222222222222222222222222;
    uint256 constant DEADLINE = 1_800_000_000;

    function test_escribeElVectorDelDigest() public {
        // El chainId entra en el dominio EIP-712, asi que el vector tiene que generarse en la
        // cadena real del producto, no en el 31337 default de forge.
        vm.chainId(4663);

        MockFeeEscrow escrow = new MockFeeEscrow();
        MockPonsFactory pons = new MockPonsFactory();
        MockXVerifier xver = new MockXVerifier();
        RobinShareVaultFactory factory = new RobinShareVaultFactory(
            address(0xA11CE), address(escrow), address(pons), address(xver), address(0)
        );
        RobinShareVault vault =
            RobinShareVault(payable(factory.createVault(1, "torvalds", address(0), 0)));

        uint256 nonce = vault.bindNonce();
        bytes32 digest = vault.bindDigest(PAYOUT, DEADLINE);

        string memory json = string.concat(
            '{\n',
            '  "_comment": "GENERADO POR contracts/test/BindVector.t.sol - no editar a mano. Lo lee web/test/bind.test.ts para verificar que la implementacion TS del digest coincide con la del contrato.",\n',
            '  "chainId": 4663,\n',
            '  "vault": "', vm.toString(address(vault)), '",\n',
            '  "payout": "', vm.toString(PAYOUT), '",\n',
            '  "nonce": ', vm.toString(nonce), ',\n',
            '  "deadline": ', vm.toString(DEADLINE), ',\n',
            '  "digest": "', vm.toString(digest), '"\n',
            '}\n'
        );
        vm.writeFile("test/fixtures/bind-vector.json", json);

        // sanity: el digest no puede ser cero ni depender de un vault sin direccion
        assertTrue(digest != bytes32(0));
        assertTrue(address(vault) != address(0));
    }
}
