# Fix del attester: firma en blanco sobre un digest ajeno — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el attester deje de firmar digests que le entrega una dirección arbitraria, eliminando el vector por el cual un atacante obtiene una firma válida contra el vault de otra persona.

**Architecture:** Dos capas independientes, cada una suficiente por sí sola. **(1)** El server construye el digest EIP-712 localmente con el dominio scopeado a la dirección recibida, en vez de pedírselo al contrato — así un contrato hostil sólo puede conseguir firmas válidas contra sí mismo. **(2)** El server verifica que la dirección pertenezca a nuestra factory, usando el ABI ya desplegado (`identityHashFor` + `getVaults`), sin cambios de contrato.

**Tech Stack:** Next.js 16 (App Router), TypeScript, viem ^2.55.0, vitest ^4.1.10 (`environment: node`, alias `@` → raíz de `web/`).

**Estado:** ✅ COMPLETADO 2026-08-29 — merge `3b3dc9b` en `main`, cherry-pick `5d5a810` en `flap-rail`. Suite 15 → 26 tests, `tsc` y `next build` limpios en ambas ramas.

**Spec:** `docs/superpowers/specs/2026-08-29-robinshare-pons-port-design.md` §8

## Global Constraints

- **Este fix es independiente del port.** El bug existe en el código auditado y aplica a los dos rails. Se implementa en `main` y **se cherry-pickea a `flap-rail`** al terminar.
- **NO pushear a `origin` hasta que este plan esté completo.** `0x-Keezy/robinshare` es un repo público y el spec documenta la cadena de ataque.
- **No cambiar contratos.** Todo el fix es de backend. La capa 2 usa el ABI ya desplegado.
- **Dominio EIP-712 exacto del vault** (de `SocialFeeEscrow.sol`, `EIP712("SocialFeeEscrow", "1")`): `name: "SocialFeeEscrow"`, `version: "1"`, `chainId: 4663`, `verifyingContract: <vault>`.
- **Typehash exacto** (de `BIND_TYPEHASH`): `Bind(address payoutWallet,uint256 nonce,uint256 deadline)`.
- **No tocar `web/lib/abis.ts`**: `bindDigest` se queda en el ABI (el contrato lo sigue exponiendo); simplemente el server deja de usarlo para firmar.
- Comandos de test: `npx vitest run <archivo>` desde `web/` (no hay script `test` en `package.json`; la Task 1 lo agrega).

---

## File Structure

| Archivo | Responsabilidad | Acción |
|---|---|---|
| `web/lib/bind.ts` | **Nuevo.** Construcción pura del typed-data `Bind` y su digest. Sin I/O, sin env — testeable sin mocks. | Crear |
| `web/lib/attester.ts` | Firma el voucher. Pasa a usar `web/lib/bind.ts` en vez de `readContract("bindDigest")`. | Modificar |
| `web/lib/identity.ts` | Validación de identidad. Suma `assertVaultFromFactory`. | Modificar |
| `web/app/api/attest/github/start/route.ts` | Cablea la verificación de procedencia antes del redirect a GitHub. | Modificar |
| `web/app/api/attest/github/callback/route.ts` | Cablea la verificación de procedencia antes de firmar. | Modificar |
| `web/test/bind.test.ts` | **Nuevo.** Tests del digest local. | Crear |
| `web/test/attester.test.ts` | Reescrito: el test actual **afirma el comportamiento vulnerable**. | Modificar |
| `web/test/identity.test.ts` | **Nuevo.** Tests de procedencia. | Crear |
| `web/package.json` | Agrega el script `test`. | Modificar |

---

## Contexto: el ataque que se está cerrando

Estado actual, verificado leyendo el código:

1. `start/route.ts` llama `assertVaultIdentity(vault, 1)`, que lee `identityType()` e `identityValue()` **de la dirección que llegó por query string** y sólo comprueba que el tipo sea `1`. **No valida procedencia.**
2. `callback/route.ts` revalida el `identityValue` contra el login de GitHub del OAuth.
3. `attester.ts::signBindVoucher` hace `readContract({ address: vault, functionName: "bindDigest" })` **sobre esa misma dirección** y firma el hash crudo con `sign({ hash })`.

Ataque: el atacante despliega `Evil` con `identityType() => 1`, `identityValue() => "<su propio login>"` y `bindDigest(payout, deadline) => IVictim(VICTIM).bindDigest(payout, deadline)`. Llama `/api/attest/github/start?vault=EVIL&payout=<su wallet>`, hace OAuth con su cuenta **real** (el login matchea), y el server firma el digest **de la víctima**. Esa firma vale en `VICTIM.claimAndBind(...)`.

Con la Task 1, el digest se calcula con `verifyingContract = EVIL`, así que la firma sólo sirve contra `EVIL`. Con la Task 2, `EVIL` ni siquiera pasa el primer filtro.

---

### Task 1: El digest se calcula en el server, no se pide al contrato

**Files:**
- Create: `web/lib/bind.ts`
- Create: `web/test/bind.test.ts`
- Modify: `web/lib/attester.ts`
- Modify: `web/test/attester.test.ts`
- Modify: `web/package.json`

**Interfaces:**
- Consumes: `publicClient` de `web/lib/chain.ts`; `escrowAbi` de `web/lib/abis.ts`.
- Produces:
  - `bindTypedData(vault: Address, payout: Address, nonce: bigint, deadline: bigint): TypedDataDefinition`
  - `bindDigestLocal(vault: Address, payout: Address, nonce: bigint, deadline: bigint): Hex`
  - `signBindVoucher(vault: Address, payout: Address): Promise<{ signature: Hex; deadline: string }>` (firma sin cambios)

- [x] **Step 1: Agregar el script de test**

En `web/package.json`, dentro de `"scripts"`, agregar:

```json
"test": "vitest run"
```

- [x] **Step 2: Escribir el test que falla, del digest local**

Crear `web/test/bind.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { hashTypedData } from "viem";
import { bindDigestLocal, bindTypedData } from "@/lib/bind";

const VAULT = "0x1111111111111111111111111111111111111111" as const;
const EVIL = "0x3333333333333333333333333333333333333333" as const;
const PAYOUT = "0x2222222222222222222222222222222222222222" as const;

describe("bindDigestLocal", () => {
  it("usa el dominio EIP-712 exacto del contrato", () => {
    const td = bindTypedData(VAULT, PAYOUT, 0n, 1000n);
    expect(td.domain).toEqual({
      name: "SocialFeeEscrow",
      version: "1",
      chainId: 4663,
      verifyingContract: VAULT,
    });
    expect(td.primaryType).toBe("Bind");
    expect(td.types.Bind).toEqual([
      { name: "payoutWallet", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ]);
  });

  it("coincide con hashTypedData de viem", () => {
    const td = bindTypedData(VAULT, PAYOUT, 7n, 1000n);
    expect(bindDigestLocal(VAULT, PAYOUT, 7n, 1000n)).toBe(hashTypedData(td));
  });

  it("el digest depende del vault: dos vaults nunca comparten digest", () => {
    const a = bindDigestLocal(VAULT, PAYOUT, 7n, 1000n);
    const b = bindDigestLocal(EVIL, PAYOUT, 7n, 1000n);
    expect(a).not.toBe(b);
  });
});
```

- [x] **Step 3: Correr el test y verificar que falla**

Run: `cd web && npx vitest run test/bind.test.ts`
Expected: FAIL — `Failed to resolve import "@/lib/bind"`.

- [x] **Step 4: Implementar `web/lib/bind.ts`**

```ts
import { hashTypedData, type Address, type Hex, type TypedDataDefinition } from "viem";
import { robinhoodChain } from "./chain";

/// Typed-data del voucher de bind. Debe coincidir EXACTAMENTE con el contrato:
///   EIP712("SocialFeeEscrow", "1")
///   BIND_TYPEHASH = keccak256("Bind(address payoutWallet,uint256 nonce,uint256 deadline)")
/// El server lo construye ACA y nunca se lo pide al contrato: si se lo pidiera, un contrato
/// hostil podria devolver el digest de OTRO vault y quedarse con una firma valida contra el.
export function bindTypedData(
  vault: Address,
  payout: Address,
  nonce: bigint,
  deadline: bigint,
): TypedDataDefinition {
  return {
    domain: {
      name: "SocialFeeEscrow",
      version: "1",
      chainId: robinhoodChain.id,
      verifyingContract: vault,
    },
    types: {
      Bind: [
        { name: "payoutWallet", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Bind",
    message: { payoutWallet: payout, nonce, deadline },
  };
}

export function bindDigestLocal(
  vault: Address,
  payout: Address,
  nonce: bigint,
  deadline: bigint,
): Hex {
  return hashTypedData(bindTypedData(vault, payout, nonce, deadline));
}
```

- [x] **Step 5: Correr el test y verificar que pasa**

Run: `cd web && npx vitest run test/bind.test.ts`
Expected: PASS (3 tests).

- [x] **Step 6: Escribir el test que falla, del attester**

Reemplazar **todo** `web/test/attester.test.ts` por:

```ts
import { describe, it, expect, vi } from "vitest";
import { recoverAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bindDigestLocal } from "@/lib/bind";

const PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
process.env.ATTESTER_PK = PK;

const EVIL = "0x3333333333333333333333333333333333333333" as const;
const VICTIM = "0x1111111111111111111111111111111111111111" as const;
const PAYOUT = "0x2222222222222222222222222222222222222222" as const;

/// Simula el contrato hostil: su bindNonce es 0, pero su bindDigest REENVIA al de la victima.
const VICTIM_DIGEST = bindDigestLocal(VICTIM, PAYOUT, 0n, 9999999999n);

const readContract = vi.fn(async ({ functionName }: { functionName: string }) => {
  if (functionName === "bindNonce") return 0n;
  if (functionName === "bindDigest") return VICTIM_DIGEST; // el reenvio hostil
  throw new Error(`unexpected read: ${functionName}`);
});
vi.mock("@/lib/chain", async (orig) => ({
  ...(await orig<typeof import("@/lib/chain")>()),
  publicClient: { readContract },
}));

const { signBindVoucher } = await import("@/lib/attester");

describe("signBindVoucher", () => {
  it("firma el digest LOCAL del vault pedido, no el que devuelve el contrato", async () => {
    const { signature, deadline } = await signBindVoucher(EVIL, PAYOUT);
    const expected = bindDigestLocal(EVIL, PAYOUT, 0n, BigInt(deadline));
    const signer = await recoverAddress({ hash: expected, signature });
    expect(signer.toLowerCase()).toBe(privateKeyToAccount(PK).address.toLowerCase());
  });

  it("la firma NO sirve contra el vault de la victima", async () => {
    const { signature } = await signBindVoucher(EVIL, PAYOUT);
    const signer = await recoverAddress({ hash: VICTIM_DIGEST, signature });
    expect(signer.toLowerCase()).not.toBe(privateKeyToAccount(PK).address.toLowerCase());
  });

  it("nunca llama bindDigest en el contrato", async () => {
    readContract.mockClear();
    await signBindVoucher(EVIL, PAYOUT);
    const llamadas = readContract.mock.calls.map((c) => c[0].functionName);
    expect(llamadas).not.toContain("bindDigest");
    expect(llamadas).toContain("bindNonce");
  });

  it("el deadline esta en el futuro", async () => {
    const { deadline } = await signBindVoucher(EVIL, PAYOUT);
    expect(Number(deadline)).toBeGreaterThan(Date.now() / 1000);
  });
});
```

- [x] **Step 7: Correr el test y verificar que falla**

Run: `cd web && npx vitest run test/attester.test.ts`
Expected: FAIL — el test *"la firma NO sirve contra el vault de la victima"* falla porque hoy el attester firma justamente `VICTIM_DIGEST`, y *"nunca llama bindDigest"* falla porque hoy sí lo llama. **Confirmar que fallan por esas razones y no por un import roto.**

- [x] **Step 8: Reescribir `web/lib/attester.ts`**

```ts
import { sign, privateKeyToAccount } from "viem/accounts";
import { serializeSignature, type Address, type Hex } from "viem";
import { publicClient } from "./chain";
import { escrowAbi } from "./abis";
import { bindDigestLocal } from "./bind";

const DEADLINE_S = 15 * 60;

export function attesterAddress(): Address {
  return privateKeyToAccount(process.env.ATTESTER_PK as Hex).address;
}

/// Construye el digest LOCALMENTE (dominio scopeado a `vault`) y lo firma.
/// Del contrato solo se lee `bindNonce`: aunque un contrato hostil mienta con el nonce, el
/// dominio sigue siendo el suyo, asi que la firma no vale contra ningun otro vault.
export async function signBindVoucher(
  vault: Address,
  payout: Address,
): Promise<{ signature: Hex; deadline: string }> {
  const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_S);
  const nonce = (await publicClient.readContract({
    address: vault,
    abi: escrowAbi,
    functionName: "bindNonce",
  })) as bigint;
  const digest = bindDigestLocal(vault, payout, nonce, deadline);
  const sig = await sign({ hash: digest, privateKey: process.env.ATTESTER_PK as Hex });
  return { signature: serializeSignature(sig), deadline: deadline.toString() };
}
```

- [x] **Step 9: Correr los tests y verificar que pasan**

Run: `cd web && npx vitest run test/bind.test.ts test/attester.test.ts`
Expected: PASS (7 tests).

- [x] **Step 10: Verificar que no rompimos tipos**

Run: `cd web && npx tsc --noEmit`
Expected: sin errores nuevos respecto de la línea base.

- [x] **Step 11: Commit**

```bash
git add web/lib/bind.ts web/lib/attester.ts web/test/bind.test.ts web/test/attester.test.ts web/package.json
git commit -m "fix(attester): construir el digest EIP-712 en el server en vez de pedirselo al contrato

Un contrato hostil que reenviaba bindDigest() al vault de otra persona conseguia una firma
valida contra ese vault. Ahora el digest se arma localmente con verifyingContract = la
direccion pedida, asi que una firma solo puede valer contra esa direccion."
```

---

### Task 2: Verificar que el vault salió de nuestra factory

**Files:**
- Modify: `web/lib/identity.ts`
- Create: `web/test/identity.test.ts`

**Interfaces:**
- Consumes: `publicClient` y `factoryAddress()` de `web/lib/chain.ts`; `factoryAbi` de `web/lib/abis.ts` (`identityHashFor(string,string,address) → bytes32`, `getVaults(bytes32) → address[]`).
- Produces: `assertVaultFromFactory(vault: Address, identityType: 1 | 2, identityValue: string): Promise<void>` — resuelve si el vault está registrado, lanza si no.

**Nota sobre el tipo:** la factory mapea `1 → "github"` y `2 → "twitter"`. El `identityValue` on-chain ya viene normalizado y `identityHashFor` vuelve a normalizar; la normalización es idempotente (lowercase + strip `@`), así que el hash coincide.

- [x] **Step 1: Escribir el test que falla**

Crear `web/test/identity.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";

const FACTORY = "0x9999999999999999999999999999999999999999" as const;
const GOOD = "0x1111111111111111111111111111111111111111" as const;
const EVIL = "0x3333333333333333333333333333333333333333" as const;
const HASH = "0xabc0000000000000000000000000000000000000000000000000000000000001" as const;

const readContract = vi.fn(async ({ functionName }: { functionName: string }) => {
  if (functionName === "identityHashFor") return HASH;
  if (functionName === "getVaults") return [GOOD];
  throw new Error(`unexpected read: ${functionName}`);
});

vi.mock("@/lib/chain", async (orig) => ({
  ...(await orig<typeof import("@/lib/chain")>()),
  publicClient: { readContract },
  factoryAddress: () => FACTORY,
}));

const { assertVaultFromFactory } = await import("@/lib/identity");

describe("assertVaultFromFactory", () => {
  beforeEach(() => readContract.mockClear());

  it("acepta un vault registrado en la factory", async () => {
    await expect(assertVaultFromFactory(GOOD, 1, "torvalds")).resolves.toBeUndefined();
  });

  it("rechaza una direccion que no salio de la factory", async () => {
    await expect(assertVaultFromFactory(EVIL, 1, "torvalds")).rejects.toThrow(/not from factory/i);
  });

  it("compara sin distinguir mayusculas (checksum vs lowercase)", async () => {
    await expect(
      assertVaultFromFactory(GOOD.toUpperCase().replace("0X", "0x") as `0x${string}`, 1, "torvalds"),
    ).resolves.toBeUndefined();
  });

  it("usa el typeStr correcto segun el tipo de identidad", async () => {
    await assertVaultFromFactory(GOOD, 1, "torvalds");
    const call = readContract.mock.calls.find((c) => c[0].functionName === "identityHashFor");
    expect(call![0].args[0]).toBe("github");
  });
});
```

- [x] **Step 2: Correr el test y verificar que falla**

Run: `cd web && npx vitest run test/identity.test.ts`
Expected: FAIL — `assertVaultFromFactory is not a function`.

- [x] **Step 3: Implementar `assertVaultFromFactory`**

En `web/lib/identity.ts`, **reemplazar las lineas 2-3** (los imports actuales son
`import { publicClient } from "./chain";` y `import { escrowAbi } from "./abis";`) por los dos
imports de abajo, y **agregar la funcion al final del archivo**. El resto del archivo
(`assertVaultIdentity`, `handleMatches`) no se toca:

```ts
import { publicClient, factoryAddress } from "./chain";
import { escrowAbi, factoryAbi } from "./abis";

const TYPE_STR: Record<1 | 2, string> = { 1: "github", 2: "twitter" };

/// Verifica que la direccion sea un vault EMITIDO POR NUESTRA FACTORY.
/// Sin esto, cualquiera despliega un contrato que finge ser un vault y se lleva una firma.
export async function assertVaultFromFactory(
  vault: Address,
  identityType: 1 | 2,
  identityValue: string,
): Promise<void> {
  const factory = factoryAddress();
  if (!factory) throw new Error("factory address not configured");

  const identityHash = (await publicClient.readContract({
    address: factory,
    abi: factoryAbi,
    functionName: "identityHashFor",
    args: [TYPE_STR[identityType], identityValue, "0x0000000000000000000000000000000000000000"],
  })) as `0x${string}`;

  const vaults = (await publicClient.readContract({
    address: factory,
    abi: factoryAbi,
    functionName: "getVaults",
    args: [identityHash],
  })) as readonly Address[];

  const target = vault.toLowerCase();
  if (!vaults.some((v) => v.toLowerCase() === target)) {
    throw new Error(`vault ${vault} not from factory`);
  }
}
```

- [x] **Step 4: Correr el test y verificar que pasa**

Run: `cd web && npx vitest run test/identity.test.ts`
Expected: PASS (4 tests).

- [x] **Step 5: Commit**

```bash
git add web/lib/identity.ts web/test/identity.test.ts
git commit -m "feat(attester): verificar que el vault salio de nuestra factory (identityHashFor + getVaults)"
```

---

### Task 3: Cablear la verificación en las dos rutas

**Files:**
- Modify: `web/app/api/attest/github/start/route.ts`
- Modify: `web/app/api/attest/github/callback/route.ts`
- Modify: `web/test/routes.test.ts`

**Interfaces:**
- Consumes: `assertVaultIdentity` y `assertVaultFromFactory` de `web/lib/identity.ts`.
- Produces: nada nuevo; ambas rutas rechazan direcciones ajenas antes de mandar a GitHub y antes de firmar.

- [x] **Step 1: Extender el mock de `@/lib/chain` en `web/test/routes.test.ts`**

⚠️ **Sin este paso, los tests que hoy PASAN se rompen.** El mock actual devuelve `0` para toda
funcion desconocida, y `factoryAddress()` real leeria env vacia y devolveria `null` — con la
verificacion cableada, los 3 tests existentes darian 403.

Reemplazar el bloque `vi.mock("@/lib/chain", ...)` (lineas 17-26) por:

```ts
const FACTORY = "0x9999999999999999999999999999999999999999";
const IDENTITY_HASH = "0x" + "cd".repeat(32);
let mockVaults: string[] = [VAULT];
vi.mock("@/lib/chain", () => ({
  publicClient: {
    readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === "identityType") return mockType;
      if (functionName === "identityValue") return mockValue;
      if (functionName === "identityHashFor") return IDENTITY_HASH;
      if (functionName === "getVaults") return mockVaults;
      if (functionName === "bindNonce") return 0n;
      if (functionName === "bindDigest") return "0x" + "ab".repeat(32);
      return 0;
    }),
  },
  factoryAddress: () => FACTORY,
}));
```

Y en el `beforeEach`, junto a `mockType = 1;` y `mockValue = "torvalds";`, agregar:

```ts
  mockVaults = [VAULT];
```

- [x] **Step 2: Escribir el test que falla**

Agregar dentro del `describe("github callback", ...)` existente, como cuarto test:

```ts
  it("vault que no salio de la factory -> 403 sin voucher", async () => {
    (globalThis as Record<string, unknown>).__ghLogin = "torvalds";
    mockVaults = ["0x4444444444444444444444444444444444444444"]; // VAULT no esta en la lista
    const st = encodeState({ vault: VAULT as `0x${string}`, payout: PAYOUT as `0x${string}` });
    const res = await ghCallback(new NextRequest(`https://fledge.test/cb?code=abc&state=${encodeURIComponent(st)}`));
    expect(res.status).toBe(403);
  });
```

Correr: `cd web && npx vitest run test/routes.test.ts`
Expected: FAIL — devuelve `307` (el redirect con el voucher) porque la ruta todavia no verifica
procedencia. Los otros 3 tests deben seguir en PASS.

- [x] **Step 3: Cablear `start/route.ts`**

Reemplazar el bloque de validación (la línea `await assertVaultIdentity(vault, 1);`) por:

```ts
  try {
    const { identityValue } = await assertVaultIdentity(vault, 1);
    await assertVaultFromFactory(vault, 1, identityValue);
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 403 });
  }
```

Y actualizar el import:

```ts
import { assertVaultIdentity, assertVaultFromFactory } from "@/lib/identity";
```

- [x] **Step 4: Cablear `callback/route.ts`**

Reemplazar:

```ts
  const { identityValue } = await assertVaultIdentity(state.vault, 1);
```

por:

```ts
  let identityValue: string;
  try {
    ({ identityValue } = await assertVaultIdentity(state.vault, 1));
    await assertVaultFromFactory(state.vault, 1, identityValue);
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 403 });
  }
```

Y actualizar el import:

```ts
import { assertVaultIdentity, assertVaultFromFactory, handleMatches } from "@/lib/identity";
```

- [x] **Step 5: Correr toda la suite**

Run: `cd web && npx vitest run`
Expected: PASS — todos los tests, incluidos los preexistentes.

- [x] **Step 6: Verificar tipos y build**

Run: `cd web && npx tsc --noEmit && npx next build`
Expected: sin errores.

- [x] **Step 7: Commit**

```bash
git add web/app/api/attest/github/start/route.ts web/app/api/attest/github/callback/route.ts web/test/routes.test.ts
git commit -m "fix(attester): rechazar con 403 las direcciones que no salieron de nuestra factory"
```

---

### Task 4: Portar el fix a `flap-rail` y documentarlo

**Files:**
- Modify: rama `flap-rail` (mismos archivos de las Tasks 1-3)
- Modify: `docs/superpowers/specs/2026-08-29-robinshare-pons-port-design.md:§8`

**Interfaces:**
- Consumes: los commits de las Tasks 1-3.
- Produces: `flap-rail` con el fix aplicado; §8 del spec marcado como resuelto.

- [x] **Step 1: Cherry-pickear a `flap-rail`**

```bash
git log --oneline main -3
git checkout flap-rail
git cherry-pick <sha-task1> <sha-task2> <sha-task3>
```

- [x] **Step 2: Correr la suite en `flap-rail`**

Run: `cd web && npx vitest run`
Expected: PASS. Si algún test falla por diferencias entre ramas, arreglarlo **en `flap-rail`** sin tocar `main`.

- [x] **Step 3: Volver a `main`**

```bash
git checkout main
```

- [x] **Step 4: Marcar el fix como resuelto en el spec**

En `docs/superpowers/specs/2026-08-29-robinshare-pons-port-design.md`, al inicio de §8, agregar:

```markdown
> **RESUELTO 2026-08-29** — plan `docs/superpowers/plans/2026-08-29-attester-blind-signature-fix.md`,
> aplicado en `main` y `flap-rail`. El server ya no pide el digest al contrato y valida procedencia.
```

- [x] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-29-robinshare-pons-port-design.md
git commit -m "docs(spec): marcar el fix del attester como resuelto en ambas ramas"
```

- [x] **Step 6: Avisar que el push queda habilitado**

Con el fix en las dos ramas, la restricción de no pushear (Global Constraints) **deja de aplicar**. El push a `origin` sigue siendo decisión de Jose, no del ejecutor del plan.

---

## Notas para quien implemente

- **La capa 1 sola ya cierra el agujero.** La capa 2 existe porque el atacante no debería ni llegar al OAuth, y porque protege contra variantes que hoy no vemos. No saltear ninguna.
- **`NEXT_PUBLIC_FACTORY_ADDRESS` hoy está sin setear** (`/api/health` devuelve 503). `assertVaultFromFactory` lanza `factory address not configured`, lo que en producción da 403 — **fail-closed, que es lo correcto**. No agregar un bypass "si no hay factory, dejá pasar".
- **No cambiar `bindDigest` en el contrato ni sacarlo del ABI.** Sigue siendo la fuente de verdad *on-chain* para `claimAndBind`; lo único que cambia es que el server no la usa para decidir qué firma.
- **La ruta X (`claimByProof`) no está en el alcance de este plan.** Su verificación la hace el oráculo de Flap, no nuestro attester.
