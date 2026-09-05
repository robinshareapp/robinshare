# FLEDGE v1 — Plan B: Web (Attester + dApp de claim + Launch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App Next.js (una sola, deploy Vercel) que contiene el attester (API routes que verifican GitHub/Twitter y firman vouchers) y el dApp de claim (lookup de vaults, prueba de identidad, cobro), más el runbook operativo del launch del token piloto.

**Architecture:** El attester NUNCA re-implementa el typed-data: lee `bindDigest(payout, deadline)` del vault vía `eth_call` y firma ese hash crudo con `ATTESTER_PK` (fuente única de verdad on-chain). GitHub = OAuth con `state` HMAC stateless. Twitter = Reclaim client-side flow (config generada server-side con el secret; el proof vuelve al server para `verifyProof` + match + firma). El dApp usa wagmi/viem con chain 4663 custom.

**Tech Stack:** Next.js (App Router, TS), wagmi v2 + viem, `@reclaimprotocol/js-sdk`, `react-qr-code`, vitest. npm (NO yarn).

**Prerequisito:** Plan A completado (necesita ABIs de `contracts/out/` y las direcciones del deploy para producción; para dev alcanza anvil).

**Spec:** `docs/superpowers/specs/2026-07-10-fledge-social-fee-escrow-design.md` (§7 attester, §8 dApp, §9 runbook, §13 llaves).

## Global Constraints

- Entorno Windows + Git Bash; `npm`; working dir `C:\Users\PC\Flap\web` salvo indicación.
- **El attester lee TODO del vault on-chain** (`identityType`, `identityValue`, `bindDigest`): jamás recibir esos valores del cliente como verdad.
- **Nunca loguear ni exponer `ATTESTER_PK` / secrets.** `.env.local` en `.gitignore`; `.env.example` versionado.
- Deadline de vouchers: **15 minutos**.
- Nombres exactos de métodos del SDK de Reclaim: los server-side están verificados (`ReclaimProofRequest.init`, `toJsonString`, `verifyProof(proof, providerVersion)`, `data[0].extractedParameters.username`); los client-side (`fromJsonString`, `getRequestUrl`, `startSession`) **confirmarlos contra el README del paquete instalado** en la Task 14 y ajustar si difieren — sin cambiar la arquitectura.
- Direcciones: chain 4663, RPC `https://rpc.mainnet.chain.robinhood.com`, explorer `https://robinhoodchain.blockscout.com`. Factory address llega por env `NEXT_PUBLIC_FACTORY_ADDRESS`.

## File Structure (resultado final)

```
web/
  package.json  next.config.ts  tsconfig.json  .env.example  vitest.config.ts
  lib/
    chain.ts          # defineChain 4663 + publicClient
    abis.ts           # ABIs minimos de escrow + factory (hardcoded del out/ de contracts)
    state.ts          # HMAC state stateless {vault, payout, exp}
    attester.ts       # signBindVoucher: eth_call bindDigest -> sign(hash)
    identity.ts       # gates: assertVaultIdentity(vault, expectedType) + matchers
  app/
    api/attest/github/start/route.ts
    api/attest/github/callback/route.ts
    api/attest/twitter/init/route.ts
    api/attest/twitter/verify/route.ts
    page.tsx                       # lookup por identidad/token
    claim/[vault]/page.tsx         # flujo de claim por tipo
    providers.tsx  layout.tsx
  scripts/attest-manual.mjs        # escape hatch CLI del piloto
  test/ (vitest: state, attester, identity, rutas con mocks)
docs/RUNBOOK-launch.md
```

---

### Task 12: Scaffold Next.js + chain 4663 + ABIs + providers wagmi

**Files:**
- Create: `web/` (create-next-app), `web/lib/chain.ts`, `web/lib/abis.ts`, `web/app/providers.tsx`, `web/.env.example`, `web/vitest.config.ts`

**Interfaces:**
- Produces: `robinhoodChain` (viem Chain), `publicClient`, `escrowAbi`, `factoryAbi`, `<Providers>` con WagmiProvider+QueryClient. Todas las tasks siguientes importan de acá.

- [ ] **Step 1: Scaffold**

```bash
cd /c/Users/PC/Flap
npx --yes create-next-app@latest web --ts --app --tailwind --eslint --no-src-dir --import-alias "@/*" --no-turbopack --use-npm
cd web
npm install wagmi viem @tanstack/react-query @reclaimprotocol/js-sdk react-qr-code
npm install -D vitest
```

- [ ] **Step 2: `web/lib/chain.ts`**

```ts
import { createPublicClient, defineChain, http } from "viem";

export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

export const publicClient = createPublicClient({
  chain: robinhoodChain,
  transport: http(process.env.NEXT_PUBLIC_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com"),
});
```

- [ ] **Step 3: `web/lib/abis.ts`** — ABIs mínimos tipados (`as const`). Extraer las firmas del `contracts/out/SocialFeeEscrow.sol/SocialFeeEscrow.json` generado en el Plan A; deben quedar EXACTAMENTE estas entradas:

```ts
export const escrowAbi = [
  { type: "function", name: "identityType", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "identityValue", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "attester", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "boundWallet", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "bindNonce", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "pendingAmount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalPaid", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "taxToken", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "recoveryAfter", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "description", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "bindDigest", stateMutability: "view",
    inputs: [{ name: "payoutWallet", type: "address" }, { name: "deadline", type: "uint256" }],
    outputs: [{ type: "bytes32" }] },
  { type: "function", name: "claimAndBind", stateMutability: "nonpayable",
    inputs: [{ name: "payoutWallet", type: "address" }, { name: "deadline", type: "uint256" }, { name: "signature", type: "bytes" }],
    outputs: [] },
  { type: "function", name: "sweep", stateMutability: "nonpayable", inputs: [], outputs: [] },
] as const;

export const factoryAbi = [
  { type: "function", name: "identityHashFor", stateMutability: "pure",
    inputs: [{ name: "typeStr", type: "string" }, { name: "rawValue", type: "string" }, { name: "identityWallet", type: "address" }],
    outputs: [{ type: "bytes32" }] },
  { type: "function", name: "getVaults", stateMutability: "view",
    inputs: [{ name: "identityHash", type: "bytes32" }], outputs: [{ type: "address[]" }] },
] as const;
```

- [ ] **Step 4: `web/app/providers.tsx`** (client component: WagmiProvider con `createConfig({ chains: [robinhoodChain], connectors: [injected()], transports: { [robinhoodChain.id]: http() } })` + QueryClientProvider) y envolver `children` en `layout.tsx`.

- [ ] **Step 5: `.env.example`**

```bash
NEXT_PUBLIC_FACTORY_ADDRESS=0x
NEXT_PUBLIC_RPC_URL=https://rpc.mainnet.chain.robinhood.com
ATTESTER_PK=0x
ATTESTER_STATE_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
RECLAIM_APP_ID=
RECLAIM_APP_SECRET=
RECLAIM_PROVIDER_ID_TWITTER=
APP_BASE_URL=http://localhost:3000
```

- [ ] **Step 6: Verificar** — `npm run build` → build OK. **Commit:** `git add web && git commit -m "feat(web): scaffold next + chain 4663 + abis + providers"`

---

### Task 13: Attester core — state HMAC + firma de vouchers + gates de identidad

**Files:**
- Create: `web/lib/state.ts`, `web/lib/attester.ts`, `web/lib/identity.ts`
- Create: `web/test/state.test.ts`, `web/test/attester.test.ts`
- Create: `web/vitest.config.ts`

**Interfaces:**
- Consumes: `publicClient`, `escrowAbi` (Task 12); `bindDigest`/`bindNonce` del contrato (Plan A Task 3).
- Produces:
  `encodeState(p: {vault: Address, payout: Address}): string` / `decodeState(s: string): {vault, payout} | null` (HMAC-SHA256, exp 20 min)
  `signBindVoucher(vault: Address, payout: Address): Promise<{ signature: Hex, deadline: string }>`
  `assertVaultIdentity(vault: Address, expectedType: 1 | 2): Promise<{ identityValue: string }>` — lanza si el tipo no coincide
  `handleMatches(onChainValue: string, provider: string): boolean` — lowercase + strip `@`

- [ ] **Step 1: Tests que fallan** (`web/test/state.test.ts`, `web/test/attester.test.ts`)

```ts
// state.test.ts
import { describe, it, expect, vi } from "vitest";
process.env.ATTESTER_STATE_SECRET = "test-secret";
const { encodeState, decodeState } = await import("../lib/state");

describe("state HMAC", () => {
  const p = { vault: "0x1111111111111111111111111111111111111111", payout: "0x2222222222222222222222222222222222222222" } as const;
  it("roundtrip", () => { expect(decodeState(encodeState(p))).toMatchObject(p); });
  it("rechaza tampering", () => {
    const s = encodeState(p);
    const tampered = s.slice(0, -4) + "AAAA";
    expect(decodeState(tampered)).toBeNull();
  });
  it("expira", () => {
    vi.useFakeTimers();
    const s = encodeState(p);
    vi.advanceTimersByTime(21 * 60 * 1000);
    expect(decodeState(s)).toBeNull();
    vi.useRealTimers();
  });
});
```

```ts
// attester.test.ts — la firma debe recuperar al attester sobre el digest EXACTO del contrato
import { describe, it, expect, vi } from "vitest";
import { recoverAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
process.env.ATTESTER_PK = PK;
const DIGEST = "0x59d9f24d2917efc17a4b3849d0a8a2f54e534b129d8f8bbc2b78fdbf120c863b" as const; // arbitrario fijo

vi.mock("../lib/chain", () => ({
  publicClient: { readContract: vi.fn(async () => DIGEST) },
}));
const { signBindVoucher } = await import("../lib/attester");

describe("signBindVoucher", () => {
  it("firma el digest leido on-chain y el signer es el attester", async () => {
    const { signature, deadline } = await signBindVoucher("0x1111111111111111111111111111111111111111", "0x2222222222222222222222222222222222222222");
    const signer = await recoverAddress({ hash: DIGEST, signature });
    expect(signer.toLowerCase()).toBe(privateKeyToAccount(PK).address.toLowerCase());
    expect(Number(deadline)).toBeGreaterThan(Date.now() / 1000);
  });
});
```

Run: `cd /c/Users/PC/Flap/web && npx vitest run` → FAIL (módulos no existen).

- [ ] **Step 2: Implementación**

`web/lib/state.ts`:

```ts
import { createHmac, timingSafeEqual } from "node:crypto";
import type { Address } from "viem";

const EXP_MS = 20 * 60 * 1000;
const secret = () => {
  const s = process.env.ATTESTER_STATE_SECRET;
  if (!s) throw new Error("ATTESTER_STATE_SECRET missing");
  return s;
};
const mac = (body: string) => createHmac("sha256", secret()).update(body).digest("base64url");

export function encodeState(p: { vault: Address; payout: Address }): string {
  const body = Buffer.from(JSON.stringify({ ...p, exp: Date.now() + EXP_MS })).toString("base64url");
  return `${body}.${mac(body)}`;
}

export function decodeState(s: string): { vault: Address; payout: Address } | null {
  const [body, tag] = s.split(".");
  if (!body || !tag) return null;
  const expected = mac(body);
  const a = Buffer.from(tag); const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  const parsed = JSON.parse(Buffer.from(body, "base64url").toString());
  if (typeof parsed.exp !== "number" || Date.now() > parsed.exp) return null;
  return { vault: parsed.vault, payout: parsed.payout };
}
```

`web/lib/attester.ts`:

```ts
import { sign, serializeSignature, privateKeyToAccount } from "viem/accounts";
import type { Address, Hex } from "viem";
import { publicClient } from "./chain";
import { escrowAbi } from "./abis";

const DEADLINE_S = 15 * 60;

export function attesterAddress(): Address {
  return privateKeyToAccount(process.env.ATTESTER_PK as Hex).address;
}

/// Lee bindDigest del PROPIO vault (fuente unica de verdad del typed-data) y firma el hash.
export async function signBindVoucher(vault: Address, payout: Address): Promise<{ signature: Hex; deadline: string }> {
  const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_S);
  const digest = (await publicClient.readContract({
    address: vault, abi: escrowAbi, functionName: "bindDigest", args: [payout, deadline],
  })) as Hex;
  const sig = await sign({ hash: digest, privateKey: process.env.ATTESTER_PK as Hex });
  return { signature: serializeSignature(sig), deadline: deadline.toString() };
}
```

`web/lib/identity.ts`:

```ts
import type { Address } from "viem";
import { publicClient } from "./chain";
import { escrowAbi } from "./abis";

export async function assertVaultIdentity(vault: Address, expectedType: 1 | 2): Promise<{ identityValue: string }> {
  const [t, v] = await Promise.all([
    publicClient.readContract({ address: vault, abi: escrowAbi, functionName: "identityType" }),
    publicClient.readContract({ address: vault, abi: escrowAbi, functionName: "identityValue" }),
  ]);
  if (Number(t) !== expectedType) throw new Error(`vault identityType ${t} != expected ${expectedType}`);
  return { identityValue: (v as string).toLowerCase() };
}

export function handleMatches(onChainValue: string, provider: string): boolean {
  const norm = (s: string) => s.trim().replace(/^@/, "").toLowerCase();
  return norm(onChainValue) === norm(provider);
}
```

`web/vitest.config.ts`: `export default { test: { environment: "node" } }` (via `defineConfig` de vitest/config).

- [ ] **Step 3: Verificar** — `npx vitest run` → PASS. **Commit:** `git add web && git commit -m "feat(web): attester core (state HMAC + firma sobre bindDigest on-chain)"`

---

### Task 14: Rutas GitHub OAuth + Twitter Reclaim

**Files:**
- Create: `web/app/api/attest/github/start/route.ts`, `web/app/api/attest/github/callback/route.ts`
- Create: `web/app/api/attest/twitter/init/route.ts`, `web/app/api/attest/twitter/verify/route.ts`
- Create: `web/test/routes.test.ts`

**Interfaces:**
- Consumes: Task 13 completa.
- Produces (el dApp de la Task 15 llama exactamente esto):
  `GET /api/attest/github/start?vault=0x..&payout=0x..` → 302 a GitHub
  `GET /api/attest/github/callback?code=..&state=..` → HTML/JSON `{ signature, deadline, payout, vault }`
  `POST /api/attest/twitter/init {vault, payout}` → `{ reclaimConfigJson, state }`
  `POST /api/attest/twitter/verify {proof, state}` → `{ signature, deadline, payout, vault }`

- [ ] **Step 1: Tests con mocks** (`web/test/routes.test.ts`) — mockear `fetch` global (GitHub) y `@reclaimprotocol/js-sdk` (`verifyProof`), y `../lib/chain`. Casos mínimos: (1) callback GitHub con `login` que matchea → 200 con signature; (2) `login` distinto → 403 sin signature; (3) twitter verify con `extractedParameters.username` que matchea → 200; (4) proof `isVerified:false` → 403; (5) state inválido → 400. Estructura igual a los mocks de la Task 13.

- [ ] **Step 2: Implementación GitHub**

`start/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { encodeState } from "@/lib/state";
import { assertVaultIdentity } from "@/lib/identity";
import type { Address } from "viem";

export async function GET(req: NextRequest) {
  const vault = req.nextUrl.searchParams.get("vault") as Address | null;
  const payout = req.nextUrl.searchParams.get("payout") as Address | null;
  if (!vault || !payout) return NextResponse.json({ error: "vault & payout required" }, { status: 400 });
  await assertVaultIdentity(vault, 1); // valida ANTES de mandar a GitHub
  const url = new URL("https://github.com/login/oauth/authorize");
  url.searchParams.set("client_id", process.env.GITHUB_CLIENT_ID!);
  url.searchParams.set("redirect_uri", `${process.env.APP_BASE_URL}/api/attest/github/callback`);
  url.searchParams.set("state", encodeState({ vault, payout }));
  return NextResponse.redirect(url); // scope vacio: solo identidad publica
}
```

`callback/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { decodeState } from "@/lib/state";
import { assertVaultIdentity, handleMatches } from "@/lib/identity";
import { signBindVoucher } from "@/lib/attester";

export async function GET(req: NextRequest) {
  const code = req.nextUrl.searchParams.get("code");
  const state = decodeState(req.nextUrl.searchParams.get("state") ?? "");
  if (!code || !state) return NextResponse.json({ error: "bad state" }, { status: 400 });

  const tokenRes = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({
      client_id: process.env.GITHUB_CLIENT_ID,
      client_secret: process.env.GITHUB_CLIENT_SECRET,
      code,
    }),
  });
  const { access_token } = await tokenRes.json();
  if (!access_token) return NextResponse.json({ error: "oauth exchange failed" }, { status: 502 });

  const userRes = await fetch("https://api.github.com/user", {
    headers: { Authorization: `Bearer ${access_token}`, "User-Agent": "fledge-attester" },
  });
  const { login } = await userRes.json();

  const { identityValue } = await assertVaultIdentity(state.vault, 1);
  if (!login || !handleMatches(identityValue, login)) {
    return NextResponse.json({ error: `github login does not match vault identity` }, { status: 403 });
  }
  const voucher = await signBindVoucher(state.vault, state.payout);
  // redirect de vuelta al claim con el voucher en el fragment (no toca logs del server)
  const back = new URL(`${process.env.APP_BASE_URL}/claim/${state.vault}`);
  back.hash = new URLSearchParams({ ...voucher, payout: state.payout }).toString();
  return NextResponse.redirect(back);
}
```

- [ ] **Step 3: Implementación Twitter (Reclaim)**

`init/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { ReclaimProofRequest } from "@reclaimprotocol/js-sdk";
import { encodeState } from "@/lib/state";
import { assertVaultIdentity } from "@/lib/identity";

export async function POST(req: NextRequest) {
  const { vault, payout } = await req.json();
  if (!vault || !payout) return NextResponse.json({ error: "vault & payout required" }, { status: 400 });
  await assertVaultIdentity(vault, 2);
  const r = await ReclaimProofRequest.init(
    process.env.RECLAIM_APP_ID!, process.env.RECLAIM_APP_SECRET!, process.env.RECLAIM_PROVIDER_ID_TWITTER!,
  );
  return NextResponse.json({ reclaimConfigJson: r.toJsonString(), state: encodeState({ vault, payout }) });
}
```

`verify/route.ts`:

```ts
import { NextRequest, NextResponse } from "next/server";
import { verifyProof } from "@reclaimprotocol/js-sdk";
import { decodeState } from "@/lib/state";
import { assertVaultIdentity, handleMatches } from "@/lib/identity";
import { signBindVoucher } from "@/lib/attester";

export async function POST(req: NextRequest) {
  const { proof, state: rawState } = await req.json();
  const state = decodeState(rawState ?? "");
  if (!proof || !state) return NextResponse.json({ error: "bad state" }, { status: 400 });

  // verifyProof(proof) — segun README v5 acepta (proof, providerVersion?); usar la firma del paquete instalado
  const result: any = await verifyProof(proof);
  const isVerified = result === true || result?.isVerified === true;
  if (!isVerified) return NextResponse.json({ error: "invalid proof" }, { status: 403 });

  const params = result?.data?.[0]?.extractedParameters
    ?? JSON.parse(proof?.claimData?.context ?? "{}")?.extractedParameters ?? {};
  const username: string | undefined = params.username ?? params.screen_name;

  const { identityValue } = await assertVaultIdentity(state.vault, 2);
  if (!username || !handleMatches(identityValue, username)) {
    return NextResponse.json({ error: "x username does not match vault identity" }, { status: 403 });
  }
  const voucher = await signBindVoucher(state.vault, state.payout);
  return NextResponse.json({ ...voucher, payout: state.payout, vault: state.vault });
}
```

**Nota obligatoria de esta task:** abrir `web/node_modules/@reclaimprotocol/js-sdk/README.md` del paquete INSTALADO y confirmar: firma exacta de `verifyProof` (con/sin providerVersion, shape del retorno) y dónde viven los parámetros extraídos. Ajustar `verify/route.ts` a lo real manteniendo los gates (isVerified + username match). Dejar el hallazgo anotado en un comentario del archivo.

- [ ] **Step 4: Verificar** — `npx vitest run` → PASS los 5 casos; `npm run build` → OK. **Commit:** `git add web && git commit -m "feat(web): attester github oauth + twitter reclaim (verify + match + voucher)"`

---

### Task 15: dApp de claim — lookup + flujo por tipo

**Files:**
- Create: `web/app/page.tsx` (lookup), `web/app/claim/[vault]/page.tsx` + `web/app/claim/[vault]/ClaimClient.tsx`
- Modify: `web/app/layout.tsx` (título FLEDGE, Providers)

**Interfaces:**
- Consumes: rutas de Task 14, `factoryAbi.identityHashFor/getVaults`, `escrowAbi` completo.

- [ ] **Step 1: `app/page.tsx`** (client) — form: select tipo (wallet/github/twitter) + input handle o address → `readContract identityHashFor` → `getVaults` → lista con links `/claim/[vault]` y `pendingAmount` (formatEther) por vault. Estado vacío: "No vaults yet for this identity". Manejar factory address ausente con banner de config.

- [ ] **Step 2: `app/claim/[vault]/ClaimClient.tsx`** (client) — lee del escrow: `identityType/identityValue/pendingAmount/boundWallet/totalPaid/description`. Render por tipo:
  - **wallet (0):** botón `sweep()` (writeContract) habilitado si `pendingAmount > 0`.
  - **github (1):** si hay voucher en `window.location.hash` (retorno del OAuth: `signature, deadline, payout`) → botón "Claim" que hace `writeContract claimAndBind(payout, deadline, signature)`; si no, botón "Verify with GitHub" → `location.href = /api/attest/github/start?vault=..&payout=<address conectada>`.
  - **twitter (2):** botón "Verify with X via Reclaim" → `POST /api/attest/twitter/init` → `ReclaimProofRequest.fromJsonString(reclaimConfigJson)` → `getRequestUrl()` → render QR (`react-qr-code`) + `startSession({ onSuccess: (proofs) => POST /api/attest/twitter/verify {proof: proofs[0] ?? proofs, state} })` → con el voucher → `claimAndBind`. (Nombres client-side del SDK: confirmar contra el README instalado, misma nota que Task 14.)
  - Común: si `boundWallet != 0` mostrar "Bound to X" + botón `sweep()`; post-tx link a Blockscout `https://robinhoodchain.blockscout.com/tx/<hash>`; errores de tx en texto plano legible.

- [ ] **Step 3: Verificar manualmente contra anvil** — en 3 terminales: (1) `anvil --fork-url https://rpc.mainnet.chain.robinhood.com`, (2) deploy factory local + crear un escrow de prueba vía `cast` impersonando el portal (`cast rpc anvil_impersonateAccount 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B` + `cast send <factory> "newVault(address,address,address,bytes)" ... --from 0xe9F7...197B --unlocked`), fondearlo (`cast send <escrow> --value 0.5ether`), (3) `npm run dev` con `NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545` y `NEXT_PUBLIC_FACTORY_ADDRESS=<factory local>` → lookup encuentra el vault, la página muestra 0.5 ETH pendiente, `sweep` de un wallet-type paga. Para github: correr el flujo completo requiere OAuth app → como mínimo verificar que `/start` valida y redirige (302 a github.com).
Expected: lookup + estado + sweep funcionan end-to-end en fork local.

- [ ] **Step 4: Commit** — `git add web && git commit -m "feat(web): dapp claim (lookup + flujos wallet/github/twitter)"`

---

### Task 16: CLI de atestación manual + .env + notas de deploy Vercel

**Files:**
- Create: `web/scripts/attest-manual.mjs`
- Modify: `web/README.md`

**Interfaces:**
- Consumes: mismo esquema de firma de Task 13.
- Produces: escape hatch operativo del piloto: `node scripts/attest-manual.mjs <vault> <payout>` imprime `{signature, deadline}` usando `ATTESTER_PK` del entorno — para cuando Reclaim/GitHub estén caídos y la verificación se haga a ojo (documentado como centralizado).

- [ ] **Step 1: Script**

```js
// web/scripts/attest-manual.mjs — USO EXCEPCIONAL (piloto): atestacion manual.
// La verificacion de identidad la hace UN HUMANO fuera de banda. Centralizado a proposito.
import { createPublicClient, http } from "viem";
import { sign, serializeSignature } from "viem/accounts";

const [vault, payout] = process.argv.slice(2);
if (!vault || !payout || !process.env.ATTESTER_PK) {
  console.error("uso: ATTESTER_PK=0x.. node scripts/attest-manual.mjs <vault> <payout>");
  process.exit(1);
}
const client = createPublicClient({ transport: http(process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com") });
const deadline = BigInt(Math.floor(Date.now() / 1000) + 15 * 60);
const digest = await client.readContract({
  address: vault,
  abi: [{ type: "function", name: "bindDigest", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bytes32" }] }],
  functionName: "bindDigest",
  args: [payout, deadline],
});
const sig = await sign({ hash: digest, privateKey: process.env.ATTESTER_PK });
console.log(JSON.stringify({ vault, payout, deadline: deadline.toString(), signature: serializeSignature(sig) }, null, 2));
```

- [ ] **Step 2: `web/README.md`** — cómo correr dev (anvil fork + envs), correr tests, deploy a Vercel (proyecto nuevo bajo cuenta `0xkeezy-3892`, root dir `web/`, envs de `.env.example` — marcar cuáles son secretos server-only: todos los que no empiezan con `NEXT_PUBLIC_`), y la política del attester (§7 y §10 del spec: key dedicada, sin fondos, riesgo aceptado documentado).

- [ ] **Step 3: Verificar** — `node --check scripts/attest-manual.mjs` → sin errores. `npx vitest run && npm run build` → verde. **Commit:** `git add web && git commit -m "feat(web): cli de atestacion manual + docs de deploy"`

---

### Task 17: RUNBOOK de launch del token piloto (gated en llaves del usuario)

**Files:**
- Create: `docs/RUNBOOK-launch.md`

**Interfaces:**
- Consumes: hallazgos del fork test (Plan A Task 10, en `contracts/README.md`), factory deployada, web deployada.
- **GATE:** NO ejecutar el launch sin las 5 llaves de §13 del spec (ETH en 4663, Reclaim creds, GitHub OAuth app, identidad piloto + recoveryDays, wallet attester dedicada). El runbook se ESCRIBE ahora; se EJECUTA cuando Jose las entregue.

- [ ] **Step 1: Escribir `docs/RUNBOOK-launch.md`** con exactamente estas secciones y comandos:

````markdown
# RUNBOOK — Launch del token piloto FLEDGE en flap.sh/robinhood

## 0. Pre-flight (todas las llaves presentes)
- [ ] Wallet deployer con ETH en chain 4663 (>= 0.05 ETH recomendado)
- [ ] Wallet ATTESTER nueva y dedicada (sin fondos); su PK SOLO en Vercel env
- [ ] Vercel: web deployada con todas las envs de web/.env.example
- [ ] Reclaim: APP_ID/SECRET + provider Twitter configurados
- [ ] GitHub OAuth app: callback = https://<dominio>/api/attest/github/callback
- [ ] Identidad piloto decidida (ej. github:0x-keezy) + recoveryDays (ej. 0)
- [ ] contracts/README.md § Hallazgos de fork test LEIDO (salt/dexId)

## 1. Deploy de la factory
export PATH="$HOME/.foundry/bin:$PATH"
cd /c/Users/PC/Flap/contracts
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
# anotar FACTORY=0x...; verificar en Blockscout:
forge verify-contract $FACTORY src/SocialFeeEscrowFactory.sol:SocialFeeEscrowFactory \
  --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args $(cast abi-encode "constructor(address)" 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B)
# actualizar NEXT_PUBLIC_FACTORY_ADDRESS en Vercel y redeploy web

## 2. vaultData del piloto
VAULT_DATA=$(cast abi-encode "f((string,string,address,address,uint256))" \
  "(github,0x-keezy,0x0000000000000000000000000000000000000000,$ATTESTER_ADDR,0)")
# OJO: si cast rechaza la tupla asi, encodear con chisel o un script viem: abi.encode de
# (string,string,address,address,uint256) SIN selector. Verificar contra el test de factory.

## 3. Salt
# Si el fork test mostro que salt arbitrario funciona: SALT=0x...01 y listo.
# Si exige vanity 7777: anvil --fork-url https://rpc.mainnet.chain.robinhood.com &
#   node scripts/mine-salt.mjs '<params json>' $FACTORY 7777  -> {salt, token}

## 4. Launch (llamada directa al VaultPortal)
cast send 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B \
  "newTokenV6WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8,address,bytes))" \
  "(Fledge Pilot,FLEDGE,<meta>,1,$SALT,1,0x0000000000000000000000000000000000000000,10000000000000000,0x,0x0000000000000000000000000000000000000000000000000000000000000000,0x,<dexId>,0,300,300,3153600000,259200,10000,0,0,0,0,0x0000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000,<V6>,$FACTORY,$VAULT_DATA)" \
  --value 0.01ether --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $DEPLOYER_PK
# <dexId>/<V6>: usar los valores confirmados por el fork test (contracts/README.md)

## 5. Verificacion post-launch (TODAS obligatorias)
- [ ] Token visible en flap.sh/robinhood/board y en Blockscout
- [ ] ESCROW=$(cast call $FACTORY "getVaults(bytes32)(address[])" $(cast call $FACTORY "identityHashFor(string,string,address)(bytes32)" "github" "0x-keezy" 0x00..00))
- [ ] cast call $ESCROW "taxToken()(address)" == token lanzado
- [ ] cast call $ESCROW "description()(string)" legible
- [ ] Comprar una pizca via flap.sh -> cast balance $ESCROW crece (puede demorar: el tax se despacha por lotes)

## 6. Smoke de claim real
- Abrir https://<dominio>/claim/$ESCROW con la wallet del piloto
- Flujo GitHub completo -> claimAndBind -> ETH llega a la payout
- Post en X: solo DESPUES de este paso verde (gate quality-gate antes de publicar)

## 7. Rollback / incidentes
- El launch NO es reversible (token vivo). Si el escrow no recibe tax: revisar mktBps=10000 en el tx y el marketAddress del token (Helper 0xb10bD2672aE63735d677164A54B573a016f0203C).
- Si el attester falla: scripts/attest-manual.mjs (verificacion humana, documentar en el canal).
- Fondos SIEMPRE seguros: sin bind no hay egress posible salvo recoverUnclaimed (si se configuro).
````

- [ ] **Step 2: Commit** — `git add docs && git commit -m "docs: runbook de launch del piloto (gated en llaves)"`

---

## Gate de cierre del Plan B

`npx vitest run` + `npm run build` verdes; flujo manual contra anvil fork verificado (Task 15 Step 3); runbook escrito. Invocar superpowers:requesting-code-review con foco en: attester nunca confía en datos del cliente, secrets nunca en respuestas/logs, gates de identidad antes de firmar. El launch real espera las 5 llaves de Jose.
