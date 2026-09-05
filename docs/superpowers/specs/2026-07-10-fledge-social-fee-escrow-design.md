# FLEDGE — Social Fee Escrow sobre Flap × Robinhood Chain

**Fecha:** 2026-07-10 · **Autor del diseño:** Fable 5 (pensamiento) · **Ejecutor previsto:** Opus 4.8
**Codename:** FLEDGE (provisional — "fledgling": el pichón al que la bandada alimenta; a juego con Flap 🦋). Contratos con nombres neutrales: `SocialFeeEscrow` / `SocialFeeEscrowFactory`.
**Repo:** `C:\Users\PC\Flap`

---

## 1. Una línea

Un token de Flap cuyos **fees de trading se acumulan para UNA persona identificada por su wallet, su GitHub o su Twitter/X** — sin que necesite wallet conocida de antemano — y que ella cobra probando su identidad (firma directa, OAuth de GitHub, o prueba zkTLS de Reclaim para X).

## 2. Contexto y oportunidad (grounded 2026-07-10)

Todo lo siguiente fue verificado HOY en esta sesión (RPC + bundle vivo de flap.sh + interfaces locales), no de memoria:

- **Robinhood Chain** (L2 Arbitrum Orbit, mainnet 1-jul-2026): chainId **4663** (`0x1237` confirmado vía RPC `rpc.mainnet.chain.robinhood.com`), gas ETH nativo, explorer `robinhoodchain.blockscout.com`. Meme meta caliente; la chain premia ser early.
- **Flap en Robinhood** (config extraída del bundle `main-app-42a7ca0260cf92f4.js` de flap.sh): VaultPortal `0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B` (proxy EIP-1967, con código on-chain, impl `0x2813CD0b6089f76F3407792f79276E5d4f80935A` no verificada), Portal `0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09`, TaxTokenV3 impl `0x7777C8743C88B3aff3cf262135beF2c8b2e83333`, Helper `0xb10bD2672aE63735d677164A54B573a016f0203C`, WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, swapRegistry `0x35Bae0b77753a586f68f9C4CD0E8d1a468169031`. Payment token único: **ETH nativo** (`address(0)`); el código del launcher lanza `"Vault only supports native token"` si no.
- **Prior art — honestidad primero:** Flap YA tiene un vault de "fees a un handle de X": el **Gift Vault / FlapXVault** (extraído del bundle: el gift owner es una cuenta de X que dirige los fees a cualquier address EVM **posteando tweets**; si no lo gestiona en 7 días cae a dividend mode; *"Only Twitter / X handle is supported in this release"*). **PERO la config de Robinhood Chain solo lista UN vaultType (IndexVault/Stocks)** — el Gift Vault **no está configurado en esta chain** (`"Gift Vault factory is not configured for this chain"`). 
- **Nuestra ventana**, entonces, no es "inventamos fees→identidad" sino: **primer fee-escrow social EN Robinhood Chain**, y superior al Gift Vault en cuatro ejes: (1) **tres identidades** (wallet + GitHub + Twitter) vs solo X; (2) claim por **zkTLS (Reclaim)** verificable vs parseo de tweets por el backend de Flap; (3) **inmutable y sin funciones privilegiadas** (ni siquiera nosotros podemos tocar los fondos) vs vault administrado; (4) recovery **paramétrico y transparente** elegido al launch vs fallback fijo de 7 días.
- **Permissionless real:** `VaultPortal.newTokenV6WithVault` acepta **cualquier factory** (badge UNVERIFIED si no está registrada) — confirmado en recon AppleHood 2026-07-09 y consistente con el docstring oficial de `IVaultSchemasV1.sol`: *"Any contract that implements VaultFactoryBaseV2 can be used to launch tokens via VaultPortal — no on-chain registration is required."*
- **El bloqueante del Guardian NO aplica:** el mandato de Flap (VaultBase/VaultFactoryBaseV2) exige rol para el Guardian **solo si existen funciones privilegiadas**. Este diseño tiene **cero** funciones privilegiadas → no dependemos de conocer la dirección del Guardian de Robinhood (el bloqueante que hoy frena a RAM/AppleHood).

## 3. Decisiones de producto (fijadas por Jose, 2026-07-10)

| Decisión | Elección |
|---|---|
| Forma del producto | **Fund-a-person**: 1 token → 1 identidad; todos los fees del token se acumulan para ella |
| Alcance v1 | **End-to-end + lanzar un token real** (contratos + attester + dApp de claim + launch) |
| Twitter en v1 | **Sí, vía Reclaim (zkTLS)** — no depender del fetch de X (bloqueado, ya documentado en el vault) |
| Modelo de trabajo | Fable 5 diseña (este spec + plan-pack) · **Opus 4.8 ejecuta** |

## 4. Arquitectura

```
   Trader compra/vende $TOKEN (bonding curve → DEX)
        │  tax buy/sell (bps), porción mktBps
        ▼
   Flap TaxProcessor ──call{value: ETH}──►  SocialFeeEscrow  (= marketAddress del token, fijado al crear, SIN setter)
                                             │  receive() VACÍO (invariante dura, ver §6)
                                             │  identityType/Value inmutables, attester inmutable
                                             │  claimAndBind(voucher EIP-712) / sweep() / recoverUnclaimed()
                                             ▼
                                       boundWallet de la persona
                        ▲ voucher EIP-712 {payoutWallet, nonce, deadline}
        ┌───────────────┴────────────────┐
        │  ATTESTER (Next.js API, Vercel)│   identityType:
        │  · wallet  → no interviene     │   0 wallet  → sin attester: boundWallet preset en constructor
        │  · github  → OAuth → login     │   1 github  → attester verifica login == identityValue
        │  · twitter → Reclaim verifyProof│  2 twitter → attester verifica extractedParameters.username
        └───────────────▲────────────────┘
                        │ sesión autenticada
                 dApp de claim (misma app Next.js):
                 conectar wallet → probar identidad → claimAndBind() → cobra ETH
```

**Insight que sostiene todo:** el contrato es **agnóstico a la identidad** — on-chain solo se verifica UNA firma EIP-712 del attester (o nada, para wallet). Toda la fragilidad del mundo web2 (OAuth, zkTLS, APIs) vive off-chain en un attester **reemplazable por vault** (cada launch elige su attester). Esto mantiene el contrato diminuto, inmutable y auditable de un vistazo, y no depende de que Reclaim tenga verifier desplegado en la chain 4663 (casi seguro no lo tiene).

### Componentes (aislamiento y responsabilidad única)

1. **`SocialFeeEscrow`** (Solidity, inmutable, extiende `VaultBaseV2`) — recibe ETH del TaxProcessor, lo retiene, lo entrega SOLO a la wallet que probó la identidad. Sin owner, sin pause, sin upgrade, sin funciones privilegiadas.
2. **`SocialFeeEscrowFactory`** (extiende `VaultFactoryBaseV2`, spec v2.2) — la llama el VaultPortal en el launch; decodifica/valida/normaliza `vaultData`, despliega el escrow con `new`, mantiene registro identityHash→vaults, expone `vaultDataSchema()` para el form auto-generado de flap.sh.
3. **Attester** (Next.js API routes en Vercel, **open source en este repo**) — 2 flujos: GitHub OAuth y Reclaim/Twitter. Emite vouchers EIP-712 con una key dedicada (`ATTESTER_PK`). La lógica es pública para que cualquiera audite que solo firma con prueba real.
4. **dApp de claim** (misma app Next.js, wagmi/viem, chain 4663 custom) — lookup de vaults por identidad o token, flujo de prueba, claim, estado vivo (`pendingAmount`, `boundWallet`, historial por eventos).
5. **Scripts de launch/ops** (Foundry script + runbook) — deploy de factory, mining de salt (sufijo vanity `7777`), llamada directa a `newTokenV6WithVault` (no dependemos de que el CA Store de robinhood liste custom factories).

## 5. Contrato `SocialFeeEscrow` — especificación exacta

### Storage

```solidity
// inmutables (fijados por la factory en el constructor)
address public immutable taxToken;        // dirección PREDICHA del token (aún sin código al construir — NO llamarlo)
address public immutable creator;         // quien lanzó el token vía VaultPortal
uint8   public immutable identityType;    // 0=wallet, 1=github, 2=twitter
address public immutable attester;        // firmante de vouchers (0x0 permitido solo para type=0)
uint64  public immutable recoveryAfter;   // timestamp; 0 = nunca. Ver recoverUnclaimed()
string  public identityValue;             // handle normalizado (vacío para type=0); string no puede ser immutable

// mutables
address public boundWallet;               // 0x0 hasta el bind; para type=0 se setea en el constructor
uint256 public bindNonce;                 // anti-replay de vouchers
uint256 public totalPaid;                 // contabilidad de todo lo pagado (sweep+claim+recover)
```

### Funciones

- `receive() external payable {}` — **cuerpo VACÍO. Invariante dura.** Razón doble: (a) recon AppleHood verificó que si `receive()` revierte, esa porción del tax va al fee receiver de Flap para siempre, sin retry; (b) si el TaxProcessor enviara con stipend de 2300 gas, cualquier SSTORE o evento revertiría por out-of-gas. Nada de contadores ni eventos acá; `totalReceived` se deriva off-chain como `balance + totalPaid` (y por logs del TaxProcessor).
- `claimAndBind(address payoutWallet, uint256 deadline, bytes signature)` — para types 1/2. Verifica EIP-712 (dominio `{name:"SocialFeeEscrow", version:"1", chainId, verifyingContract:this}`, struct `Bind(address payoutWallet,uint256 nonce,uint256 deadline)` con `nonce = bindNonce` leído del contrato), firmante == `attester`, `block.timestamp <= deadline`, `payoutWallet != 0`. Efectos (CEI): `boundWallet = payoutWallet; bindNonce++;` luego paga TODO el balance a `payoutWallet` vía `call`. Re-llamable con voucher fresco para **re-bind** (persona rota su wallet → attester re-verifica identidad y firma con el nonce nuevo). Para type=0 revierte (usar `sweep`).
- `sweep()` — permissionless. `require(boundWallet != 0)`; paga todo el balance a `boundWallet`. Es el camino de cobro continuo post-bind (los fees siguen llegando de por vida) y el único camino para type=0.
- `recoverUnclaimed()` — solo si `recoveryAfter != 0 && block.timestamp >= recoveryAfter && boundWallet == address(0)`: paga el balance al `creator`. **Una vez bound, jamás recuperable por el creator.** Racional: resuelve "la persona nunca apareció" sin hatch de admin (el trade-off exacto lo elige el creator al launch con `recoveryDays`; 0 = los fees esperan para siempre). Es nuestro análogo paramétrico del fallback de 7 días del Gift Vault de Flap.
- `pendingAmount() view returns (uint256)` → `address(this).balance`.
- `description() view returns (string)` — obligación de VaultBase; string dinámica EN: identidad, estado (unclaimed/bound/recoverable), balance pendiente, total pagado.
- `vaultUISchema() view returns (VaultUISchema)` — obligación de VaultBaseV2; describe `claimAndBind` (write), `sweep` (write), `pendingAmount`/`boundWallet`/`identity` (views) con `FieldDescriptor` correctos (tipos del set soportado: string/address/uint256/…).

### Eventos

`Bound(address indexed payoutWallet, uint256 nonce)` · `Swept(address indexed to, uint256 amount)` · `Recovered(address indexed to, uint256 amount)`.

### Invariantes de seguridad (las que los tests DEBEN fijar)

1. **El ETH solo sale hacia:** (a) `boundWallet` probado, o (b) `creator` vía `recoverUnclaimed` estrictamente si nunca hubo bind y pasó el plazo. No existe NINGÚN otro egress. Peor caso de bug = fondos trabados, nunca robo por tercero (contraste deliberado con el `burn()` rug-vector del draft FlapLLM documentado en el vault).
2. `receive()` nunca revierte — ni con 2300 gas ni con calldata vacía ni con balance previo.
3. Un voucher no es replayable (nonce), no es válido en otro vault (verifyingContract) ni en otra chain (chainId), ni después de `deadline`.
4. Reentrancia: CEI estricto; `sweep()` reentrante es inocuo (segundo call paga 0 → `require(amount>0)` corta). Sin ReentrancyGuard: no hay path dañino, menos superficie.
5. Sin funciones privilegiadas ⇒ mandato Guardian de Flap satisfecho por vacuidad; `_getGuardian()` jamás se invoca.
6. Rule 004 de Flap: todos los `require` con strings literales bilingües `"EN / 中文"` (el renderer de flap.sh no decodifica custom errors). Adoptado desde el día 1 para el path del badge.

### Edge cases resueltos

- ETH llega DURANTE un claim (dispatch en el mismo bloque) → lo toma el próximo `sweep()`.
- `boundWallet` es un contrato que revierte en receive → `sweep` revierte (fondos quedan; la persona puede re-bind a otra wallet con voucher fresco).
- Attester key comprometida ANTES del bind → el atacante puede bindear vaults no reclamados hacia sí. Mitigación v1: key dedicada en Vercel env (no reusada), montos de piloto, y **el daño está acotado al vault** (attester es por-vault, inmutable; rotación = los vaults nuevos usan attester nuevo). Documentado como riesgo aceptado de v1 (§10).
- Identidad con mayúsculas/`@` → normalización canónica **en la factory on-chain** (§6), nunca en N lugares.

## 6. Contrato `SocialFeeEscrowFactory` — especificación exacta

- **Firma que el VaultPortal invoca** (vendored de AppleHood, verificada): `newVault(address taxToken, address quoteToken, address creator, bytes vaultData) returns (address vault)`. **Gotcha crítico documentado en la interfaz:** `taxToken` es una dirección **predicha** — el token NO existe todavía cuando corre `newVault`. Prohibido llamarlo/chequearle código; solo almacenarlo.
- `vaultData` = tupla ABI `(string identityType, string identityValue, address identityWallet, address attester, uint256 recoveryDays)`:
  - `identityType` ∈ {"wallet","github","twitter"} (string legible porque el form de flap.sh se auto-genera del schema; la factory parsea → uint8, revierte si no matchea).
  - Para `wallet`: `identityWallet != 0`, `identityValue` debe venir vacío, `attester` ignorado (se guarda 0x0).
  - Para `github`/`twitter`: `identityValue` no vacío, `attester != 0`.
  - `recoveryDays`: 0 = nunca; N = `recoveryAfter = block.timestamp + N days` (cap sanity: `require(N <= 3650)`).
- **Normalización on-chain** (`_normalize`): strip `@` inicial, lowercase ASCII (A-Z→a-z), y validación de charset: twitter `1-15` de `[a-z0-9_]`; github `1-39` de `[a-z0-9-]`. Cualquier byte fuera del set → revert (mata unicode look-alikes de raíz). `identityHash = keccak256(abi.encode(uint8 type, normalizedValue))`; para wallet `keccak256(abi.encode(uint8(0), identityWallet))`.
- **Registro:** `mapping(bytes32 => address[]) public vaultsByIdentity` + `getVaults(bytes32) view` + evento `VaultCreated(bytes32 indexed identityHash, uint8 identityType, string identityValue, address indexed vault, address indexed taxToken, address creator, address attester, uint64 recoveryAfter)`. El dApp busca por mapping y/o logs (Blockscout API).
- `isQuoteTokenSupported(address q)` → `q == address(0)` (solo ETH nativo — consistente con la config de la chain).
- `vaultDataSchema()` → los 5 campos con `FieldDescriptor` (tipos: string, string, address, address, uint256; decimals 0; descripciones claras EN).
- Validación v2.2: `_validateBeforeLaunch(LaunchValidationDataV1)` → exige `quoteToken == address(0)` y `vaultBps > 0` (footgun real: mktBps=0 dejaría el escrow seco para siempre); `tokenCreationPolicies()` refleja lo mismo en forma machine-readable para el UI. `factorySpecVersion()` queda `"v2.2"` (default del base).
- Deploy de instancias con `new` plano (sin beacon, sin clones EIP-1167): gas L2 barato, sin indirección delegatecall, inmutabilidad literal.
- La factory tampoco tiene funciones privilegiadas (nada de allowlists, nada de owner).

## 7. Attester — especificación

**Stack:** Next.js App Router (misma app que el dApp), deploy Vercel. Key de firma `ATTESTER_PK` en env (wallet dedicada NUEVA, sin fondos, solo firma). Vouchers EIP-712 firmados con viem `signTypedData`.

**Flujo GitHub (OAuth Web Application Flow):**
1. `GET /api/attest/github/start?vault=0x..&payout=0x..` → valida vault (lee on-chain `identityType==1`), guarda `{vault, payout}` en cookie de sesión firmada (o `state` cifrado), redirect a `github.com/login/oauth/authorize` (scope vacío — solo identidad pública).
2. `GET /api/attest/github/callback?code=..&state=..` → intercambia code→token, `GET /user` → `login`. Compara `login.toLowerCase() === identityValue` on-chain del vault. Si matchea: lee `bindNonce` on-chain, firma voucher `{payoutWallet, nonce, deadline: now+15min}`, lo devuelve al front (JSON) → el front manda `claimAndBind`.
3. Env: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` (OAuth App que crea Jose, 2 min).

**Flujo Twitter/X (Reclaim zkTLS)** — verificado hoy contra README oficial del SDK:
1. Paquete `@reclaimprotocol/js-sdk` (v5.2.x). Backend: `ReclaimProofRequest.init(APP_ID, APP_SECRET, PROVIDER_ID)` con el provider "Twitter/X username" del marketplace de Reclaim (Jose lo selecciona en `dev.reclaimprotocol.org` al crear la app).
2. `setAppCallbackUrl('https://<app>/api/attest/twitter/callback', true /* jsonProofResponse */)` → generar request config/URL → el front lo muestra como QR/deeplink (`react-qr-code`); el usuario completa la verificación con la app/extension de Reclaim.
3. Callback recibe el proof → `const { isVerified, data } = await verifyProof(proof, providerVersion)`; extrae `data[0].extractedParameters.username`; compara lowercase contra `identityValue` del vault (sesión correlacionada por `X-Reclaim-Session-Id` ↔ `{vault, payout}` guardados en el start). Si ok → firma voucher idéntico al flujo GitHub.
4. Env: `RECLAIM_APP_ID`, `RECLAIM_APP_SECRET`, `RECLAIM_PROVIDER_ID_TWITTER`. **Nota de resiliencia:** si Reclaim se cae o cambia el provider, existe `scripts/attest-manual.ts` (CLI local con la misma key) como escape hatch operativo del piloto — centralizado y documentado como tal.

**Regla de diseño anti-confusión de capas:** el attester NUNCA computa identityHash ni normaliza por su cuenta: **lee `identityType`/`identityValue`/`bindNonce` del propio vault on-chain** y decide contra eso. Una sola fuente de verdad de normalización (la factory). Elimina la clase entera de bugs JS↔Solidity de hash mismatch.

**Seguridad del attester:** no necesita firma de la wallet de payout (la persona autenticada ELIGE su payout; un atacante no puede iniciar el flujo sin el login/proof de la víctima). Rate limit básico por IP. Deadline corto (15 min). Logs de vouchers emitidos (auditabilidad).

## 8. dApp de claim — especificación

- **Páginas:** `/` (lookup: pegás handle/wallet/token address → lista de vaults con `pendingAmount` vivo, vía `getVaults(identityHash)` + fallback logs Blockscout) · `/claim/[vault]` (detalle + flujo por tipo: wallet→`sweep()`; github→botón OAuth; twitter→QR Reclaim) · `/launch` (instrucciones + link al form de flap.sh si el CA Store lo renderiza, y receta CLI si no).
- **Web3:** wagmi v2 + viem, `defineChain` custom 4663 (RPC + explorer Blockscout), conectores injected (MetaMask/Rabby). Sin RainbowKit (peso innecesario para v1).
- **Estado vivo:** `pendingAmount`, `boundWallet`, `totalPaid`, historial de `Swept` por logs. Post-claim: confeti sobrio + link a tx en Blockscout.
- **Diseño visual:** v1 funcional limpia (sin skin premium todavía); el branding FLEDGE es un paso posterior explícitamente fuera de alcance (§12). Regla del vault aplicable cuando toque: comprometerse a UNA dirección de arte.

## 9. Integración Flap + launch runbook (receta exacta)

Lanzamiento **por script** (Foundry), sin depender del UI (el CA Store de robinhood no lista custom factories hoy; el board igual indexa el token):

1. Deploy `SocialFeeEscrowFactory` (verify en Blockscout).
2. **Salt:** todos los tax tokens observados de Flap terminan en `7777` (`taxVanityEnding` en config; el UI mina salt con `findTaxSalt`). Asumir que el Portal lo exige (fork test lo confirma; si no revierte con salt random, el vanity es opcional e igual lo minamos por estética). Script `scripts/mine-salt.ts`: brute-force CREATE2 hasta sufijo `7777` (~2 bytes, segundos de CPU). Inputs de la predicción: portal, impl V3, meta — fijar `meta` ANTES de minar.
3. Construir `NewTokenV6WithVaultParams` (struct completo extraído del bundle — campos y orden exactos en el plan): `dexThresh:1, migratorType:1, quoteToken:address(0), quoteAmt:<dev-buy ETH>, permitData:"0x", extensionID:0x0, extensionData:"0x", dexId:<default>, lpFeeProfile:0, buyTaxRate:300, sellTaxRate:300, taxDuration:3153600000 (≈100 años), antiFarmerDuration:86400*3, mktBps:10000, deflationBps:0, dividendBps:0, lpBps:0, minimumShareBalance:0, dividendToken:address(0), commissionReceiver:address(0), tokenVersion:6, vaultFactory:<factory>, vaultData:<abi.encode(tupla §6)>`. `dexId` y `lpFeeProfile` se confirman en el fork test (T-10 del plan) probando valores del enum empezando por 0 — el bundle no fija el valor para robinhood y el struct usa enums (`IPortalTypes.DEXId`). Receta piloto: 3%/3%, 100% del tax al escrow.
4. `VaultPortal.newTokenV6WithVault{value: quoteAmt}` → devuelve `token`; el evento `VaultCreated` de nuestra factory da el escrow. Verificar `token.marketAddress == escrow` (o equivalente vía Helper) en el mismo script.
5. Smoke test en vivo: comprar una pizca por el bonding curve → confirmar que el escrow acumula ETH → flujo de claim completo con la identidad piloto.
6. Badge VERIFIED de Flap: fuera de alcance v1; postulación por el grupo `Shilder <> FLAP` después del piloto (§12).

**Costos estimados:** creación ~$1 (política Flap) + gas L2 (centavos) + dev-buy opcional 0.01–0.05 ETH (los `quickAmounts` de la chain).

## 10. Modelo de amenazas y riesgos aceptados

| Riesgo | Vector | Mitigación / Postura |
|---|---|---|
| Robo por tercero sin identidad | claim/sweep/recover | Imposible por construcción (invariante 1); tests lo fijan |
| Replay/phishing de voucher | reuso, otro vault, otra chain | nonce + verifyingContract + chainId + deadline 15 min |
| Attester comprometido | firma vouchers falsos pre-bind | Riesgo central de v1, ACEPTADO documentado: key dedicada, montos piloto, daño acotado por-vault; v2 = threshold/multi-attester o verifier on-chain de Reclaim |
| Attester caído | Reclaim/GitHub down | Fondos NUNCA en riesgo (solo se pausa el bind); CLI manual de respaldo; attester nuevo requiere vault nuevo (trade-off de inmutabilidad, aceptado) |
| Fees quemados por receive() | dispatch del TaxProcessor | receive() vacío + test con 2300 gas + test de fuzz |
| Identidad muerta | nadie clama jamás | `recoveryDays` elegido al launch (0=esperan por siempre); una vez bound, nunca recuperable |
| Squatting de identidad | lanzar token "para" alguien sin su permiso | Inherente al producto (es un GIFT, igual que el Gift Vault de Flap); el contenido/UI nunca implica endorsement del receptor; disclaimer visible |
| Front-run del launch | copiar factory/params | Irrelevante: permissionless por diseño; la ventaja es ejecución+narrativa |
| Legal/marca | "Robinhood" en marketing | Mismo playbook PACOI: cero implicación de afiliación; disclaimer |

**Nota Rule 009 (para el badge futuro):** vault no-upgradeable normalmente exige `emergencyWithdrawNative/Token` guardian-gated. Nuestro `recoverUnclaimed` paramétrico es un sustituto by-design más trust-minimized; si Flap exige las hatches literales para el badge, decisión consciente en v2 (trade-off de confianza documentado), no ahora.

## 11. Estrategia de testing (el plan la detalla por task)

- **Foundry unit:** todas las invariantes de §5/§6; fuzz sobre montos/nonces/deadlines; charset de normalización (property: idempotente, rechaza no-ASCII).
- **Vector cruzado EIP-712:** fixture JSON generado por el attester TS (viem) → test Solidity que recupera el signer del MISMO vector; y a la inversa (`forge` genera digest → TS verifica). Mata la clase de bug de dominio/typehash desalineado.
- **Foundry fork (RPC 4663):** launch end-to-end real vía `newTokenV6WithVault` con `vm.deal`/`prank` → token creado, escrow correcto en el registro, simulación de dispatch (call{value} directo al escrow con gas full y con 2300) → claim → sweep. Confirma en fork la hipótesis del salt `7777`.
- **Attester (vitest):** mocks de GitHub API y de `verifyProof`; casos: match, case-mismatch (debe normalizar), handle ajeno (rechaza), proof inválido (rechaza), nonce desactualizado (re-lee on-chain).
- **E2E manual guiado (runbook):** piloto real con la identidad de Jose en mainnet con montos mínimos.

## 12. Fuera de alcance v1 (explícito)

Branding/skin premium del dApp · badge VERIFIED de Flap · multi-recipient (listas/merkle → v2 "repartidor") · router universal multi-token · verificación 100% on-chain (verifier Reclaim on-chain / oráculo GitHub) · threshold attesters · UI custom para el Artifact Workbench de Flap (4 archivos: solo si el badge lo pide) · más identidades (Telegram, dominio, email).

## 13. Llaves externas (bloqueantes SOLO del launch real, no del build)

1. 🔑 ETH en chain 4663 en la wallet de deploy (gas + ~$1 + dev-buy opcional).
2. 🔑 App de Reclaim: `dev.reclaimprotocol.org` → APP_ID/SECRET + provider Twitter (Jose, ~10 min).
3. 🔑 OAuth App de GitHub: client id/secret (Jose, ~2 min).
4. 🔑 Identidad piloto y `recoveryDays` del token piloto (propuesta: GitHub `0x-Keezy` o X `0xKeezy`, recoveryDays=0, tax 3/3, mktBps 100%).
5. 🔑 Wallet attester dedicada (generar nueva; solo su PK en Vercel env).

## 14. Grounding de esta sesión (fuentes)

- RPC `eth_chainId`/`eth_getCode` en vivo (chainId 0x1237; VaultPortal con código).
- Bundle flap.sh descargado hoy: struct `NewTokenV6WithVaultParams` completo, config de chains (robinhood sin Gift Vault, BNB con él), i18n del Gift Vault (mecánica tweets/7 días/X-only), `"Vault only supports native token"`.
- Interfaces oficiales vendored en `C:\Users\PC\AppleHood\contracts\src\flap\` (IVaultFactory/IVaultSchemasV1/VaultBase/VaultBaseV2/VaultFactoryBaseV2/RobinhoodAddresses): firma de `newVault` con token predicho, sistema de schemas v2.2, mandato Guardian condicional.
- README oficial `@reclaimprotocol/js-sdk` (v5.2.0): `ReclaimProofRequest.init`, `setAppCallbackUrl(url, true)`, `verifyProof(proof, providerVersion)`, `data[0].extractedParameters.username`.
- Vault Obsidian: recon AppleHood 2026-07-09 (VaultPortal permissionless/UNVERIFIED, marketAddress sin setter, receive() sin retry), patrones RAM (Rules 001/004/009, require bilingüe).
