# FLEDGE v1 — Plan A: Contratos (SocialFeeEscrow + Factory) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Contratos inmutables desplegables en Robinhood Chain (4663): un escrow que acumula el tax de un token de Flap para una identidad (wallet/GitHub/Twitter) y solo lo entrega a la wallet que la probó, más la factory permissionless que el VaultPortal invoca al lanzar el token.

**Architecture:** `SocialFeeEscrowFactory` (extiende `VaultFactoryBaseV2` vendored de Flap) valida/normaliza identidad on-chain y despliega `SocialFeeEscrow` con `new` (sin proxy). El escrow extiende `VaultBaseV2` + OZ `EIP712`; verificación de claim = una firma del attester sobre el digest que el propio contrato expone (`bindDigest`). Cero funciones privilegiadas ⇒ el mandato Guardian de Flap se satisface por vacuidad.

**Tech Stack:** Foundry (forge/cast/anvil en `$HOME/.foundry/bin`), Solidity ^0.8.26, OpenZeppelin v5.4.0, interfaces Flap vendored desde `C:\Users\PC\AppleHood\contracts\src\flap\`.

**Spec:** `docs/superpowers/specs/2026-07-10-fledge-social-fee-escrow-design.md` (leerlo ANTES de la Task 1).

## Global Constraints

- **Entorno:** Windows + Git Bash. Foundry NO está en PATH: en cada sesión bash correr `export PATH="$HOME/.foundry/bin:$PATH"`. Node v22 y `npm` disponibles (NO yarn).
- **Working dir de este plan:** `C:\Users\PC\Flap\contracts` (los comandos asumen `cd /c/Users/PC/Flap/contracts` salvo indicación).
- **`receive()` del escrow SIEMPRE con cuerpo vacío** — sin SSTORE, sin eventos, sin require. Invariante de producto (fees se pierden si revierte; posible stipend 2300).
- **Todos los `require` con string literal bilingüe** `unicode"EN / 中文"` (Rule 004 de Flap). Nunca custom errors en escrow/factory (las interfaces vendored pueden mantener los suyos).
- **`taxToken` que llega a `newVault` es una dirección PREDICHA sin código todavía.** Prohibido llamar métodos sobre ella o chequear `code.length`.
- **Ningún owner/pause/upgrade/allowlist** en escrow ni factory. Si un test "necesita" un admin, el test está mal.
- **Direcciones canónicas** (vendored en `src/flap/RobinhoodAddresses.sol`): VaultPortal `0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B`, chain 4663, RPC `https://rpc.mainnet.chain.robinhood.com`. El campo GUARDIAN es placeholder `0xdEaD` y NO debe usarse en ningún path de este proyecto.
- Commits frecuentes con mensajes `feat:/test:/chore:` — nunca `--no-verify`.

## File Structure (resultado final)

```
contracts/
  foundry.toml                    # perfil + rpc_endpoints.robinhood + remappings
  src/
    SocialFeeEscrow.sol           # el escrow (una responsabilidad: custodiar y pagar)
    SocialFeeEscrowFactory.sol    # factory portal-only + normalización + registro
    flap/                         # vendored de AppleHood, NO editar (excepto nota abajo)
      IVaultFactory.sol IVaultPortal.sol IVaultSchemasV1.sol IPortal.sol
      VaultBase.sol VaultBaseV2.sol VaultFactoryBaseV2.sol RobinhoodAddresses.sol
  test/
    SocialFeeEscrow.t.sol         # unit del escrow (Tasks 2-7)
    SocialFeeEscrowFactory.t.sol  # unit de la factory (Tasks 8-9)
    Fork.t.sol                    # e2e contra RPC real (Task 10)
  script/
    Deploy.s.sol                  # deploy factory + gates
  scripts/
    mine-salt.mjs                 # minería de salt vía eth_call contra anvil fork local
```

---

### Task 1: Scaffold Foundry + vendor de interfaces Flap + OZ

**Files:**
- Create: `contracts/foundry.toml`, `contracts/src/flap/*` (copiados), instala `lib/openzeppelin-contracts`
- Delete: los ejemplos `src/Counter.sol`, `test/Counter.t.sol`, `script/Counter.s.sol` que crea `forge init`

**Interfaces:**
- Produces: árbol compilable con `VaultBaseV2`, `VaultFactoryBaseV2`, `IVaultSchemasV1` (structs `VaultUISchema`, `VaultMethodSchema`, `FieldDescriptor`, `ApproveAction`, `VaultDataSchema`, `FactoryPolicy`), `IVaultPortal` (struct `NewTokenV6WithVaultParams`), `RobinhoodAddresses`. Remapping `openzeppelin-contracts/` disponible.

- [ ] **Step 1: Init y limpieza**

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd /c/Users/PC/Flap
forge init --no-git --no-commit contracts 2>/dev/null || forge init --no-git contracts
cd contracts
rm -f src/Counter.sol test/Counter.t.sol script/Counter.s.sol
```

- [ ] **Step 2: Vendorear interfaces Flap desde AppleHood**

```bash
mkdir -p src/flap
cp /c/Users/PC/AppleHood/contracts/src/flap/{IVaultFactory.sol,IVaultPortal.sol,IVaultSchemasV1.sol,IPortal.sol,VaultBase.sol,VaultBaseV2.sol,VaultFactoryBaseV2.sol,RobinhoodAddresses.sol} src/flap/
```

Si alguno importa un archivo hermano no copiado (p.ej. `ITaxProcessor.sol`, `IFlapTaxTokenV3.sol`), copiarlo también desde el mismo origen hasta que `forge build` resuelva todos los imports. NO editar el contenido vendored, con UNA excepción permitida: si `IVaultPortal.sol` no compila standalone por imports de tipos que no usamos, comentar SOLO los miembros no referenciados dejando `NewTokenV6WithVaultParams` y la función `newTokenV6WithVault` intactas.

- [ ] **Step 3: OpenZeppelin + foundry.toml**

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
```

Escribir `contracts/foundry.toml`:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 200
remappings = [
    "openzeppelin-contracts/=lib/openzeppelin-contracts/contracts/",
]

[rpc_endpoints]
robinhood = "https://rpc.mainnet.chain.robinhood.com"
```

- [ ] **Step 4: Verificar build limpio**

Run: `forge build`
Expected: `Compiler run successful` (warnings de los vendored OK, cero errors). Si `VaultBase.sol`/`VaultFactoryBaseV2.sol` traen pragma `^0.8.13`, compilan bien bajo 0.8.26.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "chore(contracts): scaffold foundry + vendor flap interfaces + OZ v5.4.0"
```

---

### Task 2: SocialFeeEscrow — constructor, inmutables y receive() vacío

**Files:**
- Create: `contracts/src/SocialFeeEscrow.sol`
- Create: `contracts/test/SocialFeeEscrow.t.sol`

**Interfaces:**
- Consumes: `VaultBaseV2` (obliga `description()` y `vaultUISchema()` — en esta task se implementan como stubs mínimos para compilar; la Task 7 los completa), OZ `EIP712`.
- Produces (para Tasks 3-7 y para la factory):
  `constructor(address taxToken_, address creator_, uint8 identityType_, string memory identityValue_, address identityWallet_, address attester_, uint64 recoveryAfter_)`
  `receive() external payable` · getters públicos: `taxToken() creator() identityType() identityValue() attester() recoveryAfter() boundWallet() bindNonce() totalPaid()` · constantes `TYPE_WALLET=0 TYPE_GITHUB=1 TYPE_TWITTER=2`.

- [ ] **Step 1: Test que falla**

`contracts/test/SocialFeeEscrow.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";

/// Helper que fuerza el stipend de 2300 gas (semántica de transfer())
contract StipendSender {
    function send(address payable to) external payable {
        to.transfer(msg.value); // revierte si el receptor gasta >2300 gas
    }
}

contract SocialFeeEscrowTest is Test {
    // anvil key #0 — attester de los tests
    uint256 constant ATTESTER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address attester;
    address taxToken = address(0x7A11); // dirección predicha, sin código (a propósito)
    address creator = address(0xC0FFEE);

    function setUp() public {
        attester = vm.addr(ATTESTER_PK);
    }

    function _newGithub(uint64 recoveryAfter) internal returns (SocialFeeEscrow) {
        return new SocialFeeEscrow(taxToken, creator, 1, "torvalds", address(0), attester, recoveryAfter);
    }

    function test_constructor_github_setsFields() public {
        SocialFeeEscrow e = _newGithub(0);
        assertEq(e.taxToken(), taxToken);
        assertEq(e.creator(), creator);
        assertEq(e.identityType(), 1);
        assertEq(e.identityValue(), "torvalds");
        assertEq(e.attester(), attester);
        assertEq(e.recoveryAfter(), 0);
        assertEq(e.boundWallet(), address(0));
        assertEq(e.bindNonce(), 0);
        assertEq(e.totalPaid(), 0);
    }

    function test_constructor_wallet_bindsImmediately() public {
        address person = address(0xBEEF);
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", person, address(0), 0);
        assertEq(e.boundWallet(), person);
        assertEq(e.identityType(), 0);
    }

    function test_constructor_wallet_zeroWallet_reverts() public {
        vm.expectRevert();
        new SocialFeeEscrow(taxToken, creator, 0, "", address(0), address(0), 0);
    }

    function test_constructor_social_zeroAttester_reverts() public {
        vm.expectRevert();
        new SocialFeeEscrow(taxToken, creator, 1, "torvalds", address(0), address(0), 0);
    }

    function test_constructor_badType_reverts() public {
        vm.expectRevert();
        new SocialFeeEscrow(taxToken, creator, 3, "x", address(0), attester, 0);
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
}
```

- [ ] **Step 2: Verificar que falla**

Run: `export PATH="$HOME/.foundry/bin:$PATH" && cd /c/Users/PC/Flap/contracts && forge test --match-contract SocialFeeEscrowTest -vv`
Expected: FAIL de compilación — `SocialFeeEscrow` no existe.

- [ ] **Step 3: Implementación mínima**

`contracts/src/SocialFeeEscrow.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/utils/cryptography/EIP712.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./flap/IVaultSchemasV1.sol";

/// @title SocialFeeEscrow (FLEDGE)
/// @notice Acumula el tax (ETH nativo) de un token de Flap para UNA identidad
///         (wallet / github / twitter) y solo lo entrega a la wallet que la probó.
///         Inmutable. Sin owner, sin pause, sin upgrade, sin funciones privilegiadas.
contract SocialFeeEscrow is VaultBaseV2, EIP712 {
    uint8 public constant TYPE_WALLET = 0;
    uint8 public constant TYPE_GITHUB = 1;
    uint8 public constant TYPE_TWITTER = 2;

    bytes32 public constant BIND_TYPEHASH =
        keccak256("Bind(address payoutWallet,uint256 nonce,uint256 deadline)");

    address public immutable taxToken;   // direccion PREDICHA del token; puede no tener codigo aun
    address public immutable creator;
    uint8 public immutable identityType;
    address public immutable attester;
    uint64 public immutable recoveryAfter; // 0 = nunca
    string public identityValue;           // normalizada por la factory; vacia para TYPE_WALLET

    address public boundWallet; // 0x0 hasta probar identidad; TYPE_WALLET la fija el constructor
    uint256 public bindNonce;
    uint256 public totalPaid;

    event Bound(address indexed payoutWallet, uint256 nonce);
    event Swept(address indexed to, uint256 amount);
    event Recovered(address indexed to, uint256 amount);

    constructor(
        address taxToken_,
        address creator_,
        uint8 identityType_,
        string memory identityValue_,
        address identityWallet_,
        address attester_,
        uint64 recoveryAfter_
    ) EIP712("SocialFeeEscrow", "1") {
        require(identityType_ <= TYPE_TWITTER, unicode"bad identity type / 身份类型无效");
        taxToken = taxToken_;
        creator = creator_;
        identityType = identityType_;
        identityValue = identityValue_;
        attester = attester_;
        recoveryAfter = recoveryAfter_;
        if (identityType_ == TYPE_WALLET) {
            require(identityWallet_ != address(0), unicode"wallet required / 需要钱包地址");
            boundWallet = identityWallet_;
            emit Bound(identityWallet_, 0);
        } else {
            require(attester_ != address(0), unicode"attester required / 需要认证者地址");
        }
    }

    /// @notice Recibe el tax del TaxProcessor de Flap.
    /// @dev CUERPO VACIO — invariante dura. Sin SSTORE, sin eventos, sin require:
    ///      si esto revierte (p.ej. con stipend de 2300 gas), esa porcion del tax
    ///      va al fee receiver de Flap PARA SIEMPRE, sin retry.
    receive() external payable {}

    // ---- stubs que la Task 7 completa (necesarios para que VaultBaseV2 compile) ----
    function description() external view virtual override returns (string memory) {
        return "FLEDGE fee escrow";
    }

    function vaultUISchema() external view virtual override returns (VaultUISchema memory schema) {
        schema.vaultType = "SocialFeeEscrow";
    }
}
```

Nota para el implementador: si `forge build` marca que las firmas de `description()`/`vaultUISchema()` no matchean las del `VaultBase`/`VaultBaseV2` vendored (p.ej. `public` vs `external`, o falta `virtual` en el base), **ajustar las firmas de ESTE contrato al base vendored** (nunca al revés) y dejar una línea en el PR-notes.

- [ ] **Step 4: Verificar que pasa**

Run: `forge test --match-contract SocialFeeEscrowTest -vv`
Expected: PASS los 8 tests (incl. fuzz).

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): SocialFeeEscrow constructor + receive() vacio con tests de stipend"
```

---

### Task 3: bindDigest + claimAndBind (happy path)

**Files:**
- Modify: `contracts/src/SocialFeeEscrow.sol` (agregar funciones)
- Modify: `contracts/test/SocialFeeEscrow.t.sol` (agregar tests + helper de firma)

**Interfaces:**
- Produces:
  `bindDigest(address payoutWallet, uint256 deadline) public view returns (bytes32)` — digest EIP-712 usando el `bindNonce` ACTUAL. **El attester off-chain lee este mismo digest vía eth_call y lo firma** (fuente única de verdad, Plan B Task 13 depende de esta firma exacta).
  `claimAndBind(address payoutWallet, uint256 deadline, bytes calldata signature) external`
  `pendingAmount() public view returns (uint256)`

- [ ] **Step 1: Tests que fallan** (agregar dentro de `SocialFeeEscrowTest`)

```solidity
    function _sign(SocialFeeEscrow e, address payout, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, e.bindDigest(payout, deadline));
        return abi.encodePacked(r, s, v);
    }

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
```

- [ ] **Step 2: Verificar que fallan**

Run: `forge test --match-test test_claimAndBind -vv`
Expected: FAIL de compilación (`bindDigest`/`claimAndBind` no existen).

- [ ] **Step 3: Implementación** (agregar en `SocialFeeEscrow.sol`, debajo de `receive()`)

```solidity
    function pendingAmount() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Digest EIP-712 que el attester debe firmar para autorizar el bind actual.
    /// @dev Usa el bindNonce VIGENTE: el attester lo lee de aca via eth_call y firma
    ///      exactamente este hash — cero re-implementacion del typed-data off-chain.
    function bindDigest(address payoutWallet, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(BIND_TYPEHASH, payoutWallet, bindNonce, deadline))
        );
    }

    /// @notice Prueba la identidad (voucher del attester) y cobra todo el balance.
    ///         Re-llamable con voucher fresco para re-bind (rotar wallet de cobro).
    function claimAndBind(address payoutWallet, uint256 deadline, bytes calldata signature) external {
        require(identityType != TYPE_WALLET, unicode"wallet identity: use sweep / 钱包身份请用 sweep");
        require(payoutWallet != address(0), unicode"zero payout / 收款地址为空");
        require(block.timestamp <= deadline, unicode"voucher expired / 凭证已过期");
        address signer = ECDSA.recover(bindDigest(payoutWallet, deadline), signature);
        require(signer == attester, unicode"bad attester signature / 认证签名无效");

        emit Bound(payoutWallet, bindNonce);
        boundWallet = payoutWallet;
        unchecked { bindNonce++; }

        uint256 amount = address(this).balance;
        if (amount > 0) {
            totalPaid += amount;               // efectos antes de la interaccion (CEI)
            emit Swept(payoutWallet, amount);
            (bool ok,) = payoutWallet.call{value: amount}("");
            require(ok, unicode"payout failed / 支付失败");
        }
    }
```

- [ ] **Step 4: Verificar que pasan**

Run: `forge test --match-contract SocialFeeEscrowTest -vv`
Expected: PASS todo lo acumulado.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): bindDigest EIP-712 + claimAndBind con pago CEI"
```

---

### Task 4: claimAndBind — matriz adversarial + re-bind

**Files:**
- Modify: `contracts/test/SocialFeeEscrow.t.sol` (solo tests — la implementación de la Task 3 ya debe resistirlos; si algo falla, el fix va en `SocialFeeEscrow.sol` respetando las invariantes)

**Interfaces:**
- Consumes: `claimAndBind`, `bindDigest`, `_sign` de Task 3.

- [ ] **Step 1: Tests adversariales**

```solidity
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
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", makeAddr("w"), address(0), 0);
        vm.expectRevert(bytes(unicode"wallet identity: use sweep / 钱包身份请用 sweep"));
        e.claimAndBind(makeAddr("p"), block.timestamp + 1, hex"00");
    }

    function test_rebind_conVoucherFresco() public {
        SocialFeeEscrow e = _newGithub(0);
        address w1 = makeAddr("w1");
        address w2 = makeAddr("w2");
        uint256 deadline = block.timestamp + 15 minutes;
        e.claimAndBind(w1, deadline, _sign(e, w1, deadline));   // nonce 0 -> 1
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        e.claimAndBind(w2, deadline, _sign(e, w2, deadline));   // _sign lee bindNonce()=1
        assertEq(e.boundWallet(), w2);
        assertEq(w2.balance, 1 ether);
    }
```

- [ ] **Step 2: Correr y verificar**

Run: `forge test --match-contract SocialFeeEscrowTest -vv`
Expected: PASS todos. Si `test_claim_replay_reverts` o `test_claim_voucherDeOtroVault_reverts` fallan, hay un bug real de dominio/nonce — arreglar en el contrato, jamás relajar el test.

- [ ] **Step 3: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "test(contracts): matriz adversarial de claimAndBind + re-bind"
```

---

### Task 5: sweep() + reentrancia inocua + wallet-type end-to-end

**Files:**
- Modify: `contracts/src/SocialFeeEscrow.sol` (agregar `sweep`)
- Modify: `contracts/test/SocialFeeEscrow.t.sol`

**Interfaces:**
- Produces: `sweep() external` — permissionless, paga TODO el balance a `boundWallet`. Es el camino de cobro continuo post-bind y el único para TYPE_WALLET.

- [ ] **Step 1: Tests que fallan**

```solidity
    function test_sweep_walletType_pagaDirecto() public {
        address person = makeAddr("person");
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", person, address(0), 0);
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
        SocialFeeEscrow e = new SocialFeeEscrow(taxToken, creator, 0, "", person, address(0), 0);
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
```

Y el helper al final del archivo (fuera del contrato de test):

```solidity
contract ReentrantPayout {
    SocialFeeEscrow target;
    function setTarget(SocialFeeEscrow t) external { target = t; }
    receive() external payable {
        if (address(target) != address(0) && address(target).balance > 0) {
            try target.sweep() {} catch {} // el anidado ve balance 0 y revierte; lo tragamos
        }
    }
}
```

- [ ] **Step 2: Verificar que fallan** — `forge test --match-test test_sweep -vv` → FAIL (no existe `sweep`).

- [ ] **Step 3: Implementación**

```solidity
    /// @notice Envia todo el balance a la wallet ya probada. Permissionless a proposito:
    ///         cualquiera puede pagar el gas para empujar los fees a su dueno.
    function sweep() external {
        require(boundWallet != address(0), unicode"not bound yet / 尚未绑定");
        uint256 amount = address(this).balance;
        require(amount > 0, unicode"nothing to sweep / 无可领取余额");
        totalPaid += amount;
        emit Swept(boundWallet, amount);
        (bool ok,) = boundWallet.call{value: amount}("");
        require(ok, unicode"payout failed / 支付失败");
    }
```

- [ ] **Step 4: Verificar que pasan** — `forge test --match-contract SocialFeeEscrowTest -vv` → PASS.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): sweep permissionless + test de reentrancia inocua"
```

---

### Task 6: recoverUnclaimed() — la válvula paramétrica

**Files:**
- Modify: `contracts/src/SocialFeeEscrow.sol`
- Modify: `contracts/test/SocialFeeEscrow.t.sol`

**Interfaces:**
- Produces: `recoverUnclaimed() external` — paga al `creator` SOLO si `recoveryAfter != 0`, ya venció, y NUNCA hubo bind.

- [ ] **Step 1: Tests que fallan**

```solidity
    function test_recover_deshabilitado_reverts() public {
        SocialFeeEscrow e = _newGithub(0); // recoveryAfter = 0
        vm.expectRevert(bytes(unicode"recovery disabled / 回收未启用"));
        e.recoverUnclaimed();
    }

    function test_recover_antesDeTiempo_reverts() public {
        SocialFeeEscrow e = _newGithub(uint64(block.timestamp + 30 days));
        vm.expectRevert(bytes(unicode"too early / 未到回收时间"));
        e.recoverUnclaimed();
    }

    function test_recover_despuesDeBind_reverts() public {
        SocialFeeEscrow e = _newGithub(uint64(block.timestamp + 30 days));
        address payout = makeAddr("p");
        uint256 deadline = block.timestamp + 15 minutes;
        e.claimAndBind(payout, deadline, _sign(e, payout, deadline));
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(bytes(unicode"already bound / 已绑定"));
        e.recoverUnclaimed(); // una vez bound, JAMAS recuperable por el creator
    }

    function test_recover_happyPath() public {
        SocialFeeEscrow e = _newGithub(uint64(block.timestamp + 30 days));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        vm.warp(block.timestamp + 30 days);
        e.recoverUnclaimed(); // permissionless; paga al creator
        assertEq(creator.balance, 1 ether);
        assertEq(e.totalPaid(), 1 ether);
    }
```

- [ ] **Step 2: Verificar que fallan** — `forge test --match-test test_recover -vv` → FAIL.

- [ ] **Step 3: Implementación**

```solidity
    /// @notice Si la persona nunca aparecio y el creator fijo un plazo al launch,
    ///         devuelve el balance al creator. Nunca disponible despues de un bind.
    function recoverUnclaimed() external {
        require(recoveryAfter != 0, unicode"recovery disabled / 回收未启用");
        require(boundWallet == address(0), unicode"already bound / 已绑定");
        require(block.timestamp >= recoveryAfter, unicode"too early / 未到回收时间");
        uint256 amount = address(this).balance;
        require(amount > 0, unicode"nothing to recover / 无可回收余额");
        totalPaid += amount;
        emit Recovered(creator, amount);
        (bool ok,) = creator.call{value: amount}("");
        require(ok, unicode"payout failed / 支付失败");
    }
```

- [ ] **Step 4: Verificar orden de requires** — el test `test_recover_despuesDeBind_reverts` exige que `already bound` se chequee ANTES que `too early`… con `warp` a +31d ambos pasarían el tiempo; el orden del código de arriba (disabled → bound → early) es el correcto para los 4 tests. Run: `forge test --match-contract SocialFeeEscrowTest -vv` → PASS.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): recoverUnclaimed parametrico (nunca post-bind)"
```

---

### Task 7: description() + vaultUISchema() reales

**Files:**
- Modify: `contracts/src/SocialFeeEscrow.sol` (reemplazar los stubs de la Task 2; quitar `virtual` si quedó)
- Modify: `contracts/test/SocialFeeEscrow.t.sol`

**Interfaces:**
- Consumes: structs de `IVaultSchemasV1.sol` (`VaultUISchema`, `VaultMethodSchema`, `FieldDescriptor` — orden de campos: name, fieldType, description, decimals).
- Produces: `description()` dinámica y `vaultUISchema()` con 4 métodos (`claimAndBind` write, `sweep` write, `pendingAmount` view, `boundWallet` view) para que flap.sh auto-renderice el vault.

- [ ] **Step 1: Tests que fallan**

```solidity
    function test_description_reflejaEstado() public {
        SocialFeeEscrow e = _newGithub(0);
        assertTrue(bytes(e.description()).length > 20);
        // pre-bind: menciona la identidad
        assertTrue(_contains(e.description(), "github:torvalds"));
        (bool ok,) = address(e).call{value: 1 ether}("");
        assertTrue(ok);
        assertTrue(_contains(e.description(), "1.000")); // 1 ether formateado
    }

    function test_vaultUISchema_tieneMetodos() public {
        SocialFeeEscrow e = _newGithub(0);
        VaultUISchema memory s = e.vaultUISchema();
        assertEq(s.vaultType, "SocialFeeEscrow");
        assertEq(s.methods.length, 4);
        assertEq(s.methods[0].name, "claimAndBind");
        assertTrue(s.methods[0].isWriteMethod);
        assertEq(s.methods[0].inputs.length, 3);
        assertEq(s.methods[1].name, "sweep");
        assertEq(s.methods[2].name, "pendingAmount");
        assertEq(s.methods[2].outputs[0].decimals, 18);
        assertEq(s.methods[3].name, "boundWallet");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack); bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < n.length; j++) if (h[i + j] != n[j]) { m = false; break; }
            if (m) return true;
        }
        return false;
    }
```

Import necesario arriba del test: `import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";`

- [ ] **Step 2: Verificar que fallan** — `forge test --match-test "test_description_reflejaEstado|test_vaultUISchema" -vv` → FAIL (stubs no cumplen).

- [ ] **Step 3: Implementación** (reemplaza ambos stubs)

```solidity
    function description() external view override returns (string memory) {
        string memory id = identityType == TYPE_WALLET
            ? Strings.toHexString(boundWallet)
            : string.concat(identityType == TYPE_GITHUB ? "github:" : "x:", identityValue);
        string memory state;
        if (boundWallet != address(0)) {
            state = string.concat("bound to ", Strings.toHexString(boundWallet));
        } else if (recoveryAfter != 0 && block.timestamp >= recoveryAfter) {
            state = "unclaimed (recoverable by creator)";
        } else {
            state = "waiting for its person";
        }
        return string.concat(
            "FLEDGE fee escrow for ", id, ": ", _fmtEth(address(this).balance),
            " ETH pending, ", _fmtEth(totalPaid), " ETH paid out. Status: ", state, "."
        );
    }

    function _fmtEth(uint256 weiAmount) internal pure returns (string memory) {
        uint256 milli = weiAmount / 1e15; // resolucion 0.001 ETH
        string memory frac = Strings.toString(milli % 1000);
        if (milli % 1000 < 10) frac = string.concat("00", frac);
        else if (milli % 1000 < 100) frac = string.concat("0", frac);
        return string.concat(Strings.toString(milli / 1000), ".", frac);
    }

    function vaultUISchema() external pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "SocialFeeEscrow";
        schema.description =
            "Trading-fee escrow for one identity (wallet, GitHub or X). Funds can only ever go to the wallet that proved the identity.";
        schema.methods = new VaultMethodSchema[](4);

        FieldDescriptor[] memory claimIn = new FieldDescriptor[](3);
        claimIn[0] = FieldDescriptor("payoutWallet", "address", "Wallet that will receive the fees", 0);
        claimIn[1] = FieldDescriptor("deadline", "time", "Voucher expiry (unix seconds)", 0);
        claimIn[2] = FieldDescriptor("signature", "bytes", "Attester voucher signature", 0);
        schema.methods[0] = VaultMethodSchema(
            "claimAndBind", "Prove the identity with an attester voucher, bind the payout wallet and claim all pending ETH.",
            claimIn, new FieldDescriptor[](0), new ApproveAction[](0), false, false, true
        );

        schema.methods[1] = VaultMethodSchema(
            "sweep", "Push all pending ETH to the already-bound wallet. Anyone may pay the gas.",
            new FieldDescriptor[](0), new FieldDescriptor[](0), new ApproveAction[](0), false, false, true
        );

        FieldDescriptor[] memory pendingOut = new FieldDescriptor[](1);
        pendingOut[0] = FieldDescriptor("pending", "uint256", "ETH currently claimable", 18);
        schema.methods[2] = VaultMethodSchema(
            "pendingAmount", "ETH accumulated and not yet paid out.",
            new FieldDescriptor[](0), pendingOut, new ApproveAction[](0), false, false, false
        );

        FieldDescriptor[] memory boundOut = new FieldDescriptor[](1);
        boundOut[0] = FieldDescriptor("wallet", "address", "Wallet bound to the identity (zero until proven)", 0);
        schema.methods[3] = VaultMethodSchema(
            "boundWallet", "The wallet that proved ownership of the identity.",
            new FieldDescriptor[](0), boundOut, new ApproveAction[](0), false, false, false
        );
    }
```

Ajustar el import de la Task 2 si falta algún struct. Si el `vaultUISchema()` del base vendored es `view` (no `pure`), usar `view`.

- [ ] **Step 4: Verificar** — `forge test --match-contract SocialFeeEscrowTest -vv` → PASS completo.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): description dinamica + vaultUISchema para el UI de flap"
```

---

### Task 8: SocialFeeEscrowFactory — newVault + normalización + registro

**Files:**
- Create: `contracts/src/SocialFeeEscrowFactory.sol`
- Create: `contracts/test/SocialFeeEscrowFactory.t.sol`

**Interfaces:**
- Consumes: constructor de `SocialFeeEscrow` (Task 2), `VaultFactoryBaseV2` vendored.
- Produces (Plan B y Task 10 dependen de esto):
  `constructor(address vaultPortal_)`
  `newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData) external returns (address)` — **solo callable por `vaultPortal`**; `vaultData = abi.encode(string identityType, string identityValue, address identityWallet, address attester, uint256 recoveryDays)`
  `getVaults(bytes32 identityHash) external view returns (address[] memory)`
  `identityHashFor(string calldata typeStr, string calldata rawValue, address identityWallet) external pure returns (bytes32)` — el dApp usa ESTA función para lookup (normaliza igual que el registro)
  `event VaultCreated(bytes32 indexed identityHash, uint8 identityType, string identityValue, address indexed vault, address indexed taxToken, address creator, address attester, uint64 recoveryAfter)`

- [ ] **Step 1: Tests que fallan**

`contracts/test/SocialFeeEscrowFactory.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";

contract SocialFeeEscrowFactoryTest is Test {
    SocialFeeEscrowFactory factory;
    address portal = makeAddr("vaultPortal");
    address creator = makeAddr("creator");
    address attester = makeAddr("attester");
    address predictedToken = address(0x7777);

    function setUp() public {
        factory = new SocialFeeEscrowFactory(portal);
    }

    function _data(string memory t, string memory v, address w, uint256 days_) internal view returns (bytes memory) {
        return abi.encode(t, v, w, attester, days_);
    }

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
        address vault = factory.newVault(predictedToken, address(0), creator, _data("github", "@ToRvAlDs", address(0), 0));
        SocialFeeEscrow e = SocialFeeEscrow(payable(vault));
        assertEq(e.identityValue(), "torvalds");          // strip @ + lowercase
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
        vm.startPrank(portal);
        address v1 = factory.newVault(predictedToken, address(0), creator, _data("twitter", "@0xKeezy", address(0), 30));
        address v2 = factory.newVault(predictedToken, address(0), creator, _data("wallet", "", makeAddr("person"), 0));
        vm.stopPrank();
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
        // Propiedad: si un handle pasa la validacion, normalizarlo dos veces = una vez,
        // y el hash del crudo == hash del normalizado (lookup consistente).
        vm.assume(bytes(raw).length > 0 && bytes(raw).length <= 15);
        vm.prank(portal);
        try factory.newVault(predictedToken, address(0), creator, _data("twitter", raw, address(0), 0)) returns (address vault) {
            string memory norm = SocialFeeEscrow(payable(vault)).identityValue();
            assertEq(factory.identityHashFor("twitter", raw, address(0)),
                     factory.identityHashFor("twitter", norm, address(0)));
        } catch {} // los que revierten no interesan a esta propiedad
    }
}
```

- [ ] **Step 2: Verificar que falla** — `forge test --match-contract SocialFeeEscrowFactoryTest -vv` → FAIL (no existe la factory).

- [ ] **Step 3: Implementación completa**

`contracts/src/SocialFeeEscrowFactory.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {SocialFeeEscrow} from "./SocialFeeEscrow.sol";

/// @title SocialFeeEscrowFactory (FLEDGE)
/// @notice Factory permissionless para VaultPortal.newTokenV6WithVault: crea un
///         SocialFeeEscrow por token, normaliza la identidad on-chain y mantiene
///         el registro identidad -> vaults. Sin funciones privilegiadas.
contract SocialFeeEscrowFactory is VaultFactoryBaseV2 {
    address public immutable vaultPortal;

    mapping(bytes32 => address[]) internal _vaultsByIdentity;
    address[] public allVaults;

    event VaultCreated(
        bytes32 indexed identityHash,
        uint8 identityType,
        string identityValue,
        address indexed vault,
        address indexed taxToken,
        address creator,
        address attester,
        uint64 recoveryAfter
    );

    constructor(address vaultPortal_) {
        require(vaultPortal_ != address(0), unicode"zero portal / portal 地址为空");
        vaultPortal = vaultPortal_;
    }

    /// @dev taxToken es una direccion PREDICHA: el token NO existe todavia. Solo almacenar.
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        returns (address vault)
    {
        require(msg.sender == vaultPortal, unicode"only vault portal / 仅限 VaultPortal");
        require(quoteToken == address(0), unicode"native quote only / 仅支持原生代币");

        (string memory typeStr, string memory rawValue, address identityWallet, address attester, uint256 recoveryDays)
            = abi.decode(vaultData, (string, string, address, address, uint256));

        uint8 t = _parseType(typeStr);
        require(recoveryDays <= 3650, unicode"recovery too long / 回收期过长");
        uint64 recoveryAfter = recoveryDays == 0 ? 0 : uint64(block.timestamp + recoveryDays * 1 days);

        bytes32 identityHash;
        string memory normalized = "";
        if (t == 0) {
            require(bytes(rawValue).length == 0, unicode"value must be empty for wallet / wallet 类型不需要句柄");
            require(identityWallet != address(0), unicode"wallet required / 需要钱包地址");
            identityHash = keccak256(abi.encode(uint8(0), identityWallet));
        } else {
            normalized = _normalize(t, rawValue);
            identityHash = keccak256(abi.encode(t, normalized));
        }

        vault = address(new SocialFeeEscrow(taxToken, creator, t, normalized, identityWallet, attester, recoveryAfter));
        _vaultsByIdentity[identityHash].push(vault);
        allVaults.push(vault);
        emit VaultCreated(identityHash, t, normalized, vault, taxToken, creator, attester, recoveryAfter);
    }

    function getVaults(bytes32 identityHash) external view returns (address[] memory) {
        return _vaultsByIdentity[identityHash];
    }

    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Hash canonico de una identidad — usa la MISMA normalizacion que el registro.
    ///         El dApp y el attester deben usar esta funcion, nunca re-implementar el hash.
    function identityHashFor(string calldata typeStr, string calldata rawValue, address identityWallet)
        external
        pure
        returns (bytes32)
    {
        uint8 t = _parseType(typeStr);
        if (t == 0) {
            require(identityWallet != address(0), unicode"wallet required / 需要钱包地址");
            return keccak256(abi.encode(uint8(0), identityWallet));
        }
        return keccak256(abi.encode(t, _normalize(t, rawValue)));
    }

    function isQuoteTokenSupported(address quoteToken) external pure returns (bool) {
        return quoteToken == address(0);
    }

    function _parseType(string memory s) internal pure returns (uint8) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("wallet")) return 0;
        if (h == keccak256("github")) return 1;
        if (h == keccak256("twitter")) return 2;
        revert(unicode"identity type must be wallet|github|twitter / 身份类型无效");
    }

    /// @dev strip '@' inicial + lowercase ASCII + charset estricto por tipo.
    ///      twitter: 1-15 de [a-z0-9_] · github: 1-39 de [a-z0-9-]. No-ASCII => revert.
    function _normalize(uint8 t, string memory raw) internal pure returns (string memory) {
        bytes memory b = bytes(raw);
        uint256 start = (b.length > 0 && b[0] == "@") ? 1 : 0;
        uint256 len = b.length - start;
        uint256 max = t == 2 ? 15 : 39;
        require(len >= 1 && len <= max, unicode"bad handle length / 句柄长度无效");
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[start + i];
            if (c >= "A" && c <= "Z") c = bytes1(uint8(c) + 32);
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
                || (t == 2 ? c == bytes1("_") : c == bytes1("-"));
            require(ok, unicode"bad handle charset / 句柄包含非法字符");
            out[i] = c;
        }
        return string(out);
    }

    // ---- stubs que la Task 9 completa ----
    function vaultDataSchema() public pure virtual override returns (VaultDataSchema memory schema) {
        schema.description = "stub";
    }
}
```

- [ ] **Step 4: Verificar que pasan** — `forge test --match-contract SocialFeeEscrowFactoryTest -vv` → PASS (incl. fuzz).

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): factory portal-only con normalizacion on-chain y registro"
```

---

### Task 9: Factory — schema, policies y validación v2.2

**Files:**
- Modify: `contracts/src/SocialFeeEscrowFactory.sol` (reemplazar stub + agregar `_validateBeforeLaunch` y `tokenCreationPolicies`)
- Modify: `contracts/test/SocialFeeEscrowFactory.t.sol`

**Interfaces:**
- Consumes: `LaunchValidationDataV1` de `IVaultFactoryValidationV2` (campos: tokenVersion, quoteToken, buyTaxRate, sellTaxRate, **vaultBps**, deflationBps, dividendBps, lpBps, dividendToken, minimumShareBalance).
- Produces: `vaultDataSchema()` con los 5 campos exactos que el form de flap.sh renderiza; `onBeforeLaunch` heredado que delega en `_validateBeforeLaunch`.

- [ ] **Step 1: Tests que fallan**

```solidity
    function test_vaultDataSchema_cincoCampos() public {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 5);
        assertEq(s.fields[0].name, "identityType");
        assertEq(s.fields[0].fieldType, "string");
        assertEq(s.fields[1].name, "identityValue");
        assertEq(s.fields[2].name, "identityWallet");
        assertEq(s.fields[2].fieldType, "address");
        assertEq(s.fields[3].name, "attester");
        assertEq(s.fields[4].name, "recoveryDays");
        assertEq(s.fields[4].fieldType, "uint256");
        assertFalse(s.isArray);
    }

    function test_onBeforeLaunch_valida() public {
        // payload valido: quote nativo + vaultBps > 0
        bytes memory ok_ = abi.encode(IVaultFactoryValidationV2.LaunchValidationDataV1({
            tokenVersion: IPortalTypes.TokenVersion(uint8(2)), // si el enum vendored difiere, usar el literal que compile
            quoteToken: address(0), buyTaxRate: 300, sellTaxRate: 300,
            vaultBps: 10000, deflationBps: 0, dividendBps: 0, lpBps: 0,
            dividendToken: address(0), minimumShareBalance: 0
        }));
        (bool okFlag, ) = factory.onBeforeLaunch(ok_);
        assertTrue(okFlag);

        // quote no nativo -> rechaza
        bytes memory badQuote = abi.encode(IVaultFactoryValidationV2.LaunchValidationDataV1({
            tokenVersion: IPortalTypes.TokenVersion(uint8(2)),
            quoteToken: address(0xDAD), buyTaxRate: 300, sellTaxRate: 300,
            vaultBps: 10000, deflationBps: 0, dividendBps: 0, lpBps: 0,
            dividendToken: address(0), minimumShareBalance: 0
        }));
        (bool f1, string memory r1) = factory.onBeforeLaunch(badQuote);
        assertFalse(f1);
        assertGt(bytes(r1).length, 0);

        // vaultBps == 0 -> rechaza (escrow quedaria seco para siempre)
        bytes memory badBps = abi.encode(IVaultFactoryValidationV2.LaunchValidationDataV1({
            tokenVersion: IPortalTypes.TokenVersion(uint8(2)),
            quoteToken: address(0), buyTaxRate: 300, sellTaxRate: 300,
            vaultBps: 0, deflationBps: 0, dividendBps: 5000, lpBps: 5000,
            dividendToken: address(0), minimumShareBalance: 0
        }));
        (bool f2, ) = factory.onBeforeLaunch(badBps);
        assertFalse(f2);
    }

    function test_policies_dosReglas() public {
        FactoryPolicy[] memory p = factory.tokenCreationPolicies();
        assertEq(p.length, 2);
        assertEq(p[0].target, "quoteToken");
        assertEq(p[0].operator, "eq");
        assertEq(p[1].target, "mktBps");
        assertEq(p[1].operator, "gte");
    }
```

Imports a agregar arriba del test: `import {VaultDataSchema, FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol"; import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol"; import {IPortalTypes} from "../src/flap/IPortal.sol";`
(Si el nombre del enum `TokenVersion` en el vendored difiere, usar el que exista; el VALOR no importa para estos tests.)

- [ ] **Step 2: Verificar que fallan** — `forge test --match-test "test_vaultDataSchema|test_onBeforeLaunch|test_policies" -vv` → FAIL.

- [ ] **Step 3: Implementación** (reemplaza el stub `vaultDataSchema` y agrega)

```solidity
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Escrows 100% of the vault share of trading fees for ONE identity. "
            "identityType is 'wallet', 'github' or 'twitter'. For wallet: set identityWallet and leave identityValue empty. "
            "For github/twitter: set identityValue to the handle (no @ needed) and attester to the voucher signer. "
            "recoveryDays: 0 = funds wait forever; N = creator can recover if unclaimed after N days.";
        schema.fields = new FieldDescriptor[](5);
        schema.fields[0] = FieldDescriptor("identityType", "string", "wallet | github | twitter", 0);
        schema.fields[1] = FieldDescriptor("identityValue", "string", "Handle for github/twitter (empty for wallet)", 0);
        schema.fields[2] = FieldDescriptor("identityWallet", "address", "Recipient wallet (only for identityType=wallet, else 0x0)", 0);
        schema.fields[3] = FieldDescriptor("attester", "address", "Voucher signer for github/twitter (0x0 for wallet)", 0);
        schema.fields[4] = FieldDescriptor("recoveryDays", "uint256", "Days until creator may recover unclaimed funds (0 = never)", 0);
        schema.isArray = false;
    }

    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, unicode"quote token must be native / 仅支持原生代币");
        }
        if (data.vaultBps == 0) {
            return (false, unicode"vault share (mktBps) must be > 0 or the escrow never receives fees / 金库份额必须大于 0");
        }
        return (true, "");
    }

    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](2);
        policies[0] = FactoryPolicy("quoteToken", "eq", abi.encode(address(0)),
            "Quote token must be the native token (ETH).");
        policies[1] = FactoryPolicy("mktBps", "gte", abi.encode(uint256(1)),
            "Vault share of the tax must be greater than zero.");
    }
```

Si `_validateBeforeLaunch` en el base vendored es `view` (no `pure`), matchear `view`.

- [ ] **Step 4: Verificar** — `forge test -vv` → PASS TODO el suite (escrow + factory).

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): vaultDataSchema + validacion v2.2 + policies"
```

---

### Task 10: Fork test — launch real end-to-end contra Robinhood Chain

**Files:**
- Create: `contracts/test/Fork.t.sol`

**Interfaces:**
- Consumes: `IVaultPortal` vendored (struct `NewTokenV6WithVaultParams` — orden de campos EXACTO extraído del bundle de flap.sh, ya presente en el vendored: name, symbol, meta, dexThresh, salt, migratorType, quoteToken, quoteAmt, permitData, extensionID, extensionData, dexId, lpFeeProfile, buyTaxRate, sellTaxRate, taxDuration, antiFarmerDuration, mktBps, deflationBps, dividendBps, lpBps, minimumShareBalance, dividendToken, commissionReceiver, tokenVersion, vaultFactory, vaultData).
- Produces: certeza empírica sobre (a) launch permissionless funciona con nuestra factory, (b) si el salt necesita vanity `7777`, (c) valores válidos de `dexId`/`lpFeeProfile`. **Anotar los hallazgos en `contracts/README.md`** — el runbook (Plan B Task 17) los consume.

- [ ] **Step 1: Escribir el fork test**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {SocialFeeEscrow} from "../src/SocialFeeEscrow.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {RobinhoodAddresses} from "../src/flap/RobinhoodAddresses.sol";

/// Corre SOLO con: forge test --match-contract ForkTest --fork-url robinhood -vvv
contract ForkTest is Test {
    uint256 constant ATTESTER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function setUp() public {
        // guard: solo en fork de la chain correcta
        if (block.chainid != 4663) return;
    }

    function _params(address factory, bytes32 salt, bytes memory vaultData)
        internal pure returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p)
    {
        p.name = "Fledge Pilot";
        p.symbol = "FLEDGE";
        p.meta = "{}";
        p.dexThresh = /* DexThreshType */ 1;
        p.salt = salt;
        p.migratorType = /* MigratorType */ 1;
        p.quoteToken = address(0);
        p.quoteAmt = 0.01 ether;
        p.permitData = "";
        p.extensionID = bytes32(0);
        p.extensionData = "";
        p.dexId = 0;          // hipotesis; si revierte probar 1, 2 y anotar el valido
        p.lpFeeProfile = 0;
        p.buyTaxRate = 300;   // 3%
        p.sellTaxRate = 300;  // 3%
        p.taxDuration = 3153600000; // ~100 anos
        p.antiFarmerDuration = 3 days;
        p.mktBps = 10000;     // 100% del tax al escrow
        p.deflationBps = 0;
        p.dividendBps = 0;
        p.lpBps = 0;
        p.minimumShareBalance = 0;
        p.dividendToken = address(0);
        p.commissionReceiver = address(0);
        p.tokenVersion = /* TokenVersion V6 */ 2; // si el enum vendored difiere, usar el miembro V6
        p.vaultFactory = factory;
        p.vaultData = vaultData;
    }

    function test_fork_launchEndToEnd() public {
        if (block.chainid != 4663) { console2.log("SKIP: correr con --fork-url robinhood"); return; }

        address attester = vm.addr(ATTESTER_PK);
        SocialFeeEscrowFactory factory = new SocialFeeEscrowFactory(RobinhoodAddresses.VAULT_PORTAL);

        bytes memory vaultData = abi.encode("github", "0x-keezy", address(0), attester, uint256(0));
        address creator = makeAddr("pilot-creator");
        vm.deal(creator, 1 ether);

        // (a) hipotesis del salt: probar salt arbitrario primero
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory), bytes32(uint256(1)), vaultData);
        vm.prank(creator);
        try IVaultPortal(RobinhoodAddresses.VAULT_PORTAL).newTokenV6WithVault{value: p.quoteAmt}(p) returns (address token) {
            console2.log("LAUNCH OK con salt arbitrario. token:", token);
            _afterLaunch(factory, token, attester);
        } catch Error(string memory reason) {
            console2.log("Launch revirtio (string):", reason);
            console2.log("=> El portal exige salt/vanity o params distintos. Anotar y probar dexId 1/2 o mine-salt (Task 11).");
            // No fallamos el test: el resultado ES el dato. Marcar hallazgo en README.
        } catch (bytes memory raw) {
            console2.log("Launch revirtio (custom error), selector:");
            console2.logBytes4(bytes4(raw));
        }
    }

    function _afterLaunch(SocialFeeEscrowFactory factory, address token, address attester) internal {
        // el escrow quedo registrado
        bytes32 h = factory.identityHashFor("github", "0x-keezy", address(0));
        address[] memory vaults = factory.getVaults(h);
        assertEq(vaults.length, 1);
        SocialFeeEscrow escrow = SocialFeeEscrow(payable(vaults[0]));
        assertEq(escrow.taxToken(), token, "el taxToken predicho debe coincidir con el token real");

        // (b) simular dispatch del TaxProcessor: ETH nativo directo al escrow
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(escrow).call{value: 0.3 ether}("");
        assertTrue(ok);
        assertEq(escrow.pendingAmount(), 0.3 ether);

        // (c) claim completo en fork
        address payout = makeAddr("keezy-payout");
        uint256 deadline = block.timestamp + 15 minutes;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, escrow.bindDigest(payout, deadline));
        escrow.claimAndBind(payout, deadline, abi.encodePacked(r, s, v));
        assertEq(payout.balance, 0.3 ether);
        console2.log("E2E fork OK: launch -> tax -> claim");
    }
}
```

Nota: si el vendored `IVaultPortal.sol` usa enums tipados para `dexThresh`/`migratorType`/`tokenVersion`, castear: `IPortalCommonTypes.DexThreshType(1)`, etc. El literal correcto de `tokenVersion` es el miembro **V6** del enum — verificar en el vendored y usar ese.

- [ ] **Step 2: Correr contra el fork**

Run: `forge test --match-contract ForkTest --fork-url robinhood -vvv`
Expected: `LAUNCH OK...` con las 3 fases E2E, O un log claro del revert (string o selector). **Ambos resultados son éxito de la task** — lo obligatorio es saber cuál es y documentarlo.

- [ ] **Step 3: Documentar hallazgos**

Crear/actualizar `contracts/README.md` sección `## Hallazgos de fork test` con: ¿salt arbitrario funcionó?, ¿qué dexId/lpFeeProfile valieron?, ¿el token real coincidió con el predicho?, gas del launch. Si el launch revirtió: registrar selector/razón y marcar que el runbook DEBE usar `scripts/mine-salt.mjs` (Task 11) y/o ajustar el param señalado.

- [ ] **Step 4: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "test(contracts): fork e2e launch->tax->claim contra Robinhood Chain + hallazgos"
```

---

### Task 11: Deploy script + mine-salt + README

**Files:**
- Create: `contracts/script/Deploy.s.sol`
- Create: `contracts/scripts/mine-salt.mjs`
- Modify: `contracts/README.md`

**Interfaces:**
- Consumes: hallazgos de Task 10.
- Produces: `Deploy.s.sol` (deploya la factory apuntando al VaultPortal canónico, con gate anti-error), `mine-salt.mjs` (encuentra salt cuyo token predicho termina en `7777`, usando el PORTAL MISMO como oráculo vía eth_call — sin re-implementar el CREATE2 de Flap).

- [ ] **Step 1: Deploy script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SocialFeeEscrowFactory} from "../src/SocialFeeEscrowFactory.sol";
import {RobinhoodAddresses} from "../src/flap/RobinhoodAddresses.sol";

/// forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
contract Deploy is Script {
    function run() external {
        require(block.chainid == RobinhoodAddresses.CHAIN_ID, "wrong chain");
        vm.startBroadcast();
        SocialFeeEscrowFactory factory = new SocialFeeEscrowFactory(RobinhoodAddresses.VAULT_PORTAL);
        vm.stopBroadcast();
        console2.log("SocialFeeEscrowFactory:", address(factory));
        console2.log("VaultPortal:", factory.vaultPortal());
    }
}
```

- [ ] **Step 2: mine-salt.mjs** (solo necesario si Task 10 mostró que el portal exige vanity; útil igual por estética de CA)

```js
// contracts/scripts/mine-salt.mjs
// Mineria de salt usando el PORTAL como oraculo (eth_call de newTokenV6WithVault
// contra un fork LOCAL de anvil) — no re-implementa el CREATE2 de Flap.
// Uso:
//   1) anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8545
//   2) node scripts/mine-salt.mjs '<json de params SIN salt>' <factoryAddr> [sufijo]
// El JSON de params: mismos campos que el fork test, valores en strings decimales.
import { createPublicClient, http, encodeFunctionData, decodeFunctionResult, numberToHex } from "viem";

const PORTAL = "0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B";
const SUFFIX = (process.argv[4] ?? "7777").toLowerCase();
const ABI = [{
  type: "function", name: "newTokenV6WithVault", stateMutability: "payable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "name", type: "string" }, { name: "symbol", type: "string" }, { name: "meta", type: "string" },
    { name: "dexThresh", type: "uint8" }, { name: "salt", type: "bytes32" }, { name: "migratorType", type: "uint8" },
    { name: "quoteToken", type: "address" }, { name: "quoteAmt", type: "uint256" }, { name: "permitData", type: "bytes" },
    { name: "extensionID", type: "bytes32" }, { name: "extensionData", type: "bytes" }, { name: "dexId", type: "uint8" },
    { name: "lpFeeProfile", type: "uint8" }, { name: "buyTaxRate", type: "uint16" }, { name: "sellTaxRate", type: "uint16" },
    { name: "taxDuration", type: "uint64" }, { name: "antiFarmerDuration", type: "uint64" }, { name: "mktBps", type: "uint16" },
    { name: "deflationBps", type: "uint16" }, { name: "dividendBps", type: "uint16" }, { name: "lpBps", type: "uint16" },
    { name: "minimumShareBalance", type: "uint256" }, { name: "dividendToken", type: "address" },
    { name: "commissionReceiver", type: "address" }, { name: "tokenVersion", type: "uint8" },
    { name: "vaultFactory", type: "address" }, { name: "vaultData", type: "bytes" },
  ]}],
  outputs: [{ name: "token", type: "address" }],
}];

const base = JSON.parse(process.argv[2]);
base.vaultFactory = process.argv[3];
const client = createPublicClient({ transport: http("http://127.0.0.1:8545") });
const from = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // anvil #0, con balance en el fork

for (let i = 0n; ; i++) {
  const salt = numberToHex(i, { size: 32 });
  const data = encodeFunctionData({ abi: ABI, functionName: "newTokenV6WithVault", args: [{ ...base, salt }] });
  try {
    const res = await client.call({ to: PORTAL, data, value: BigInt(base.quoteAmt), account: from });
    const token = decodeFunctionResult({ abi: ABI, functionName: "newTokenV6WithVault", data: res.data });
    if (token.toLowerCase().endsWith(SUFFIX)) {
      console.log(JSON.stringify({ salt, token }));
      break;
    }
  } catch { /* salt invalido para el portal: seguir */ }
  if (i % 500n === 0n) console.error(`probados ${i}...`);
}
```

Instalar viem para scripts: `cd /c/Users/PC/Flap/contracts && npm init -y >/dev/null 2>&1 && npm install viem@2` (crea `package.json` local de contracts/scripts; agregar `"type": "module"` al package.json).

- [ ] **Step 3: Smoke del script** (sin minar de verdad): `node scripts/mine-salt.mjs --help 2>&1 || true` — basta verificar que parsea sin SyntaxError con `node --check scripts/mine-salt.mjs`.
Expected: sin errores de sintaxis.

- [ ] **Step 4: README de contracts** — escribir `contracts/README.md`: qué es cada contrato, invariantes (§5-6 del spec), cómo correr unit/fork tests, cómo deployar, hallazgos de la Task 10, y la advertencia GUARDIAN-placeholder.

- [ ] **Step 5: Verificación final del plan A**

Run: `forge build && forge test -vv`
Expected: build limpio + suite completa PASS (fork test skipea sin `--fork-url`).

- [ ] **Step 6: Commit**

```bash
cd /c/Users/PC/Flap && git add contracts && git commit -m "feat(contracts): deploy script + mine-salt via eth_call + README"
```

---

## Gate de cierre del Plan A

Antes de pasar al Plan B: `forge test -vv` todo verde; fork test corrido al menos una vez con `--fork-url robinhood` y hallazgos anotados en `contracts/README.md`; `git log` muestra ~10 commits atómicos. Invocar la skill superpowers:requesting-code-review sobre el diff acumulado de contratos con foco en las invariantes de §5-§6 del spec.
