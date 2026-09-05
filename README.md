# FLEDGE contracts

> ⚠️ **ESTE README DESCRIBE EL RAIL DE FLAP, QUE YA NO ES LA LINEA VIVA.**
>
> RobinShare se porto al launchpad **pons v2** (misma cadena, Robinhood Chain 4663). En el rail
> nuevo no hay `VaultPortal`, ni vanity `0x7777`, ni Guardian, y los contratos son
> `RobinShareVault` + `RobinShareVaultFactory`. Lo de abajo sigue siendo correcto **para la rama
> `flap-rail` y el tag `audited-v3`**, y se conserva por eso.
>
> Para el rail vivo: [`docs/superpowers/specs/2026-08-29-robinshare-pons-port-design.md`](../docs/superpowers/specs/2026-08-29-robinshare-pons-port-design.md)
> (diseno), [`docs/RUNBOOK-launch-pons.md`](../docs/RUNBOOK-launch-pons.md) (operacion) y
> [`PENDIENTES.md`](../PENDIENTES.md) (lo que falta decidir). **El contrato nuevo no esta auditado.**

`SocialFeeEscrow` + `SocialFeeEscrowFactory` — el motor on-chain de FLEDGE sobre Flap × Robinhood Chain (4663).

## Qué es cada contrato

- **`SocialFeeEscrow`** — inmutable. Recibe el tax (ETH nativo) del TaxProcessor de Flap y solo lo entrega a la wallet que probó la identidad (wallet / github / twitter), o al `creator` vía `recoverUnclaimed` si nadie reclama antes del deadline. Sin owner, sin pause, sin upgrade, sin admin keys nuestras. Tiene **dos** funciones gateadas al Guardian OFICIAL de Flap (público, per-chain, heredado de `VaultBase` — nunca una key de FLEDGE ni del creator): `emergencyWithdrawNative` (escape hatch de última instancia, Audit v3 finding 4 / Option A del preaudit) y `setRescueForward` (switch para redirigir el tax entrante durante un incidente). `receive()` nunca revierte por lógica propia: si el rescue-forward está prendido, reenvía el ETH entrante best-effort (y si el forward falla, el ETH se queda en el vault, rescatable). Ver `AUDIT-NOTES.md`.
- **`SocialFeeEscrowFactory`** — la llama `VaultPortal.newTokenV6WithVault`. Valida/normaliza la identidad on-chain, despliega un escrow por token, mantiene el registro `identityHash → vaults[]`, y expone `vaultDataSchema()` para el form auto-generado de flap.sh. Sin owner/pause/upgrade ni keys nuestras. Única función gateada: `rotateAttester` (el attester vigente, o el Guardian oficial de Flap como backup — Audit v3 finding 5).

## Invariantes (fijadas por los tests)

1. El ETH solo sale hacia `boundWallet` (identidad probada), al `creator` vía `recoverUnclaimed` (solo si nunca hubo bind y venció el plazo ≥30 días), o al Guardian oficial de Flap vía `emergencyWithdrawNative`/el destino que el Guardian fije con `setRescueForward`. Ningún otro egress. **Peor caso de bug ajeno al Guardian = fondos trabados, nunca robo por tercero no-Guardian.**
2. `receive()` nunca revierte por lógica propia (probado con stipend 2300 y fuzz). Con el rescue-forward prendido por el Guardian, la recepción requiere más de los 2300 gas de `transfer`/`send` para completar el forward — Flap entrega el tax con `.call` bajo Rule 005 (<1M gas, sin stipend), así que esto no aplica al flujo real (ver `test/Fork.t.sol`).
3. Voucher no replayable (nonce/tweetId global), no válido en otro vault (verifyingContract) ni otra chain (chainId) ni tras `deadline`.
4. El mandato Guardian de Flap se satisface ACTIVAMENTE, no por vacuidad: el Guardian real de Robinhood (`0x0000b487…0000`) co-gatea `rotateAttester` en la factory y gatea `emergencyWithdrawNative`/`setRescueForward` en cada vault (Option A del preaudit + los fixes de Audit v3).

## Correr

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build --sizes                                              # AMBOS contratos deben quedar bajo 24,576 B (EIP-170)
forge test                                                        # la suite completa; el fork test skipea (vm.skip) sin --fork-url
forge test --match-contract Fork --fork-url robinhood -vv         # e2e real contra la chain
```

## Hallazgos de fork test (2026-07-10) — verificados on-chain

El fork test lanza un token real vía el `VaultPortal` de Robinhood Chain y corre launch → tax → claim. **Resultado: E2E VERDE.** El token real igualó exactamente al predicho localmente.

- **Vanity obligatorio `0x7777`.** El portal revierte `InvalidVanity(address)` (selector `0x7576ca0a`) si el tax token no termina en `7777`.
- **⚠️ `predictTaxTokenV1Address` es el predictor EQUIVOCADO para la ruta V6.** Da el address de un impl distinto (V1) que NO coincide con el que el portal calcula para `newTokenV6WithVault`.
- **Derivación correcta del tax token V6** (crackeada contra el revert y verificada con match EXACTO en el launch real):
  ```
  tokenAddr = CREATE2(
      deployer      = Portal (0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09),
      salt          = el salt raw (bytes32, sin transformar),
      initCodeHash  = keccak256(EIP-1167 minimal-proxy(TAX_TOKEN_V3_IMPL 0x7777…3333))
                    = 0x6ce33cede557fe3331031c87bf9be28f493a6086cdc8770ac0a4c7dd7320dea7
  )
  ```
  → **el salt se mina LOCALMENTE** (keccak puro, sin RPC) buscando sufijo `7777`. Ver `scripts/mine-salt.mjs` y `_predictV6` en `test/Fork.t.sol`.
- **⚠️ El vault se crea ANTES del check de vanity** (natspec + confirmado: un staticcall/eth_call del launch revierte con returndata VACÍA, no `InvalidVanity`). Por eso NO se puede minar el salt vía `eth_call` del launch — hay que predecir el address off-chain con la derivación de arriba.
- **Params válidos del launch (verificados):** `dexThresh = FOUR_FIFTHS (1)`, `migratorType = V2_MIGRATOR (1)`, `dexId = DEX0 (0)`, `lpFeeProfile = LP_FEE_PROFILE_STANDARD (0)`, `tokenVersion = TOKEN_TAXED_V3 (6)`, `quoteToken = address(0)` (ETH nativo), `value = quoteAmt` (dev-buy). Receta piloto: `buyTaxRate/sellTaxRate = 300` (3%), `mktBps = 10000` (100% al escrow), `antiFarmerDuration = 3 days`, `taxDuration = 3153600000` (~100 años).
- **Enums:** `DexThreshType` vive en `IPortalCommonTypes`; el resto (`MigratorType`, `DEXId`, `V3LPFeeProfile`, `TokenVersion`) en `IPortalTypes`.

## Ruta Twitter/X — XGeneralVerifier oficial de Flap

Tras el pitch, el equipo de Flap (GT) nos dio su infra oficial de verificación de X y pidió NO delegar la verificación a un attester externo que pueda drenar el vault (valida nuestro propio review). Integrado:

- **`claimByProof(XGeneralProof, sig)`** en el escrow para identidad **twitter**: chequea (1) el substring == `expectedTweet(msg.sender)` (ata la prueba a esa wallet + este vault), (2) `proof.xHandle == identityValue` (el tweet es del handle FONDEADO — check que el reference impl de Flap NO trae y es imprescindible para fund-a-persona), (3) `IXGeneralVerifier.verify()` (firma del oráculo de Flap), (4) replay GLOBAL por `tweetId` estrictamente creciente (Snowflake; Audit v3 finding 6 — antes era por-claimer). Libera a `msg.sender`.
- `expectedHandle` / `expectedTweet` para que el dApp arme el tweet exacto (patrón del Gift Vault de Flap: address del claimer + address del vault como tag único; hex lowercase).
- **`claimAndBind` ahora es GITHUB-only**; twitter usa `claimByProof`; wallet usa `sweep`/`rebindWallet`.
- El `XGeneralVerifier` es **chain-based** (`SocialFeeEscrowFactory._getXVerifier()`): **BSC mainnet `0xcA8DBE6CAC4BFDc41226b0BaF2359fd99989b3E4`** (verificado: tiene code, `oracleKey()=0xDE3C6ceF1e75e8A7EA6eEd7bf65EE627214F0d87`); **Robinhood 4663: desplegado y verificado on-chain (2026-07-16)** — `RobinhoodAddresses.X_VERIFIER = 0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17`. En cualquier chain sin entrada en `_getXVerifier()`, `newVault` RECHAZA la creación de vaults twitter (preaudit High #2) — no quedan brickeados esperando un `claimByProof` que revertiría para siempre.
- Tests: matriz completa de `claimByProof` con un mock del verifier (happy, wrong handle, wrong substring, bad sig, replay, wrong type, no verifier) + los tests de `_getXVerifier`/creación en BSC y Robinhood (`test/AuditFixes.t.sol`). Interfaz confirmada contra el contrato real en BNB.
- ⚠️ Reemplaza a Reclaim en la ruta X. El **flujo web de twitter** (leer `expectedTweet` → usuario tuitea → `POST` al oráculo de Flap → `claimByProof`) vive en `C:\Users\PC\Flap\web`.

## Seguridad — review adversarial (2026-07-10) + audit v3 de GT (2026-07-16)

Review multi-lente (4 auditores independientes + síntesis), y luego el audit formal de GT (reporte `f70e5476`, ver `AUDIT-STATUS-f70e5476.md` y `AUDIT-NOTES.md`). **Veredicto: robo por tercero no-Guardian IMPOSIBLE** — el ETH solo sale hacia la wallet que probó la identidad, al creator vía `recoverUnclaimed`, o al Guardian oficial de Flap por los dos hatches explícitos. Hallazgos relevantes, todos resueltos:

- **[important] Attester elegible por el creator → RESUELTO.** En el diseño original el creator pasaba el `attester` en `vaultData`, así que un creator malicioso podía nombrar su propia key, auto-firmarse un voucher y bindear su wallet — rugueando los fees mientras el token decía "para @torvalds". No era robo por tercero (el destino era el propio creator), pero rompía la garantía marketeada. **Fix:** el `attester` ahora es **canónico de la factory** (arg único del constructor `SocialFeeEscrowFactory(attester)` — el `vaultPortal` sale hardcodeado de `_getVaultPortal()`, no es un parámetro), se inyecta en TODO escrow social, y el creator **no puede elegirlo**. `vaultData` bajó de 5 a 4 campos (sin attester). Quien quiera otro oráculo despliega su propia factory.
- **[minor] TYPE_WALLET con boundWallet que revierte en receive → fondos trabados (documentado, mitigado).** `rebindWallet` (gated a `identityWallet`) permite rotar hacia una wallet que sí pueda recibir, sin depender de que la wallet original reciba ETH.
- **Audit v3 de GT (2026-07-16), 6 findings, todos TP, todos arreglados**: literal `revert()` → `require()` (finding 1); views bilingües (finding 2); piso de 30 días para `recoveryDays` (finding 3); `setRescueForward` + forward de `receive()` gated al Guardian (finding 4); `rotateAttester` co-gateado por el Guardian (finding 5); replay global de `claimByProof` por `tweetId` (finding 6). Detalle completo en `AUDIT-STATUS-f70e5476.md` y `AUDIT-NOTES.md`.

## Badge verificado de Flap — estado

GT indicó el path: Flap revisa el código + nosotros agregamos integration tests para RH; la info está en `flap-sh/FlapVaultExample` (spec-checker oficial + rule 006 + integration-test-guide).

- **Guardian REAL de Robinhood desbloqueado:** del commit `3b7689d8` de FlapVaultExample → `0x0000b48720d3B4ED6BC5031768B07F2b59270000` (resuelve el placeholder histórico `0xdEaD`; ver `src/flap/RobinhoodAddresses.sol`). Agregadas las ramas 4663 a `_getPortal`/`_getVaultPortal`/`_getGuardian` de los base contracts. A diferencia del estado original del proyecto, hoy el Guardian SÍ se usa: co-gatea/gatea 3 funciones (`emergencyWithdrawNative`, `setRescueForward`, `rotateAttester`).
- **Cobertura rule 006 (integration tests):** writes happy+revert (`claimAndBind`/`claimByProof`/`rebindWallet`/`sweep`/`recoverUnclaimed`), views (`pendingAmount`/`boundWallet`/`expectedTweet`), `description()` cambia con el estado, `vaultUISchema()` (count + isWriteMethod, 7 métodos), `vaultDataSchema()` de la factory, `newVault()` portal-only + revert desde no-portal, y `testReceiveGasUnder1M` (Rule 005). Total **la suite completa** (71 del preaudit v2 + 21 del audit v3 de GT + 3 post-v3 del wiring de `X_VERIFIER` en Robinhood) — correr `forge test` para el número real.
- **Integration test para RH:** `Fork.t.sol` lanza un token real vía el VaultPortal de RH y corre launch → tax → claim(github) → sweep + receive<1M + schema/description contra el estado real de la chain. Reproducir: `forge test --match-contract Fork --fork-url robinhood -vv`.
- Pendiente para el badge oficial: correr el spec-checker de FlapVaultExample como gate final + pasarle a Flap el standard-json-input + addresses cuando deployemos.

## Deploy

```bash
# ATTESTER_ADDRESS = la wallet dedicada del oraculo FLEDGE (attester canonico de la factory)
ATTESTER_ADDRESS=0x... forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
```

`SocialFeeEscrowFactory` toma un único constructor arg (`attester`); el `vaultPortal` no es parámetro, sale hardcodeado de `_getVaultPortal()` por chain.

## Bytecode y EIP-170

`SocialFeeEscrowFactory.newVault` hace `new SocialFeeEscrow(...)`, así que el initcode COMPLETO del vault queda embebido en el bytecode de la factory — cualquier byte que crezca en `SocialFeeEscrow.sol` (schemas, strings bilingües, requires) infla el tamaño de **ambos** contratos, no solo del vault. Medir siempre con `forge build --sizes` después de tocar cualquiera de los dos archivos; si la factory se acerca al margen, priorizar la verdad del contenido y recortar verbosidad (traducciones concisas, funciones `_fd`/`_method`/`_arr1`/`_arr3` compartidas en vez de construir cada `FieldDescriptor`/`VaultMethodSchema` inline) antes que omitir contenido mandado. Ver `AUDIT-NOTES.md` para el margen medido actual de cada contrato.

## Build notes

- `via_ir = true` (necesario: `newVault` + `description()` con `string.concat` tocan stack-too-deep sin él).
- OZ v5.4.0. Interfaces Flap vendored de AppleHood; un shim en `src/flap/oz-shims/` alias-ea `IAccessControlUpgradeable` (OZ v4 upgradeable) a la `IAccessControl` de v5.
