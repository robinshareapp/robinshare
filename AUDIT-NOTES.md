# RobinShare — contract code for review (v3, post-audit)

## AUDIT OUTCOME — approved for deployment (2026-07-17)

GT's follow-up report (`774664f8`, v4) flagged **one** finding: `vaultUISchema()` declared
`claimByProof`/`recoverUnclaimed` without their inputs (the EIP-170 concession we had disclosed
in our own feedback, together with the deployer-split alternative). **David Zhang reviewed the
report and our disclosure and approved as-is: "There are no problems now, you can proceed with
the deployment."** Consistent with Flap's stated policy (RAM audit, 2026-07-03): the UI-schema
constraints exist for the auto-generated portal UI and are lifted for projects shipping a
bespoke UI — RobinShare ships its own dApp.

**This tree (tag `audited-v3`) is the approved source; deployed bytecode must build from here.**
A full fix for that finding (flattened `claimByProof(uint256,string,uint256,string,bytes)` +
`SocialFeeEscrowDeployer` split freeing the factory's runtime + exact schema/signature parity
with tests, 105/105 green) exists on branch **`v4-schema-exact`** — unaudited, parked as material
for a future version. Do not deploy from that branch without a fresh audit round.

## Pre-audit propio adversarial — 18 findings, todos arreglados (2026-07-16)

Antes de mandar el paquete v3 a GT armamos nuestro propio pre-audit adversarial (mismo estilo que
el bot de GT: caza violaciones SYS-REQ y mismatches doc-vs-código) sobre el estado post-v3 +
post-X_VERIFIER. Encontró 18 cosas reales, todas arregladas en esta pasada:

- **Honestidad de privilegios** (src + README): el header de la factory y el `@dev` del GUARDIAN en
  `RobinhoodAddresses.sol` ya decían la verdad (3 funciones gateadas) desde el commit del
  X_VERIFIER; lo que faltaba era `README.md` completo — tenía "sin funciones privilegiadas",
  `receive()` "VACÍO", el mandato Guardian "satisfecho por vacuidad", una sección "⚠️ GUARDIAN
  placeholder" con el `0xdEaD` histórico, "Robinhood: PENDIENTE" del X verifier (ya cableado), el
  constructor de 2 args de la factory (hoy 1 arg), y conteos de tests viejos. Reescrito entero.
- **Mandate de `VaultBaseV2` incompleto**: `SocialFeeEscrow.vaultUISchema()` omitía `claimByProof`
  y `recoverUnclaimed` — los vaults twitter y la recovery de creator no tenían ruta de claim
  documentada para la UI. Agregados ambos (bilingües). `expectedTweet` quedó fuera por presupuesto
  de bytecode (ver nota de EIP-170 abajo).
- **Schema de la factory con atribución falsa**: `vaultDataSchema()` decía que twitter usa "FLEDGE's
  canonical attester" — ya venía corregido (usa el `XGeneralVerifier` de Flap, no el attester).
- **NatSpec stale**: el constructor de `SocialFeeEscrow` y el `@dev` de `_getXVerifier` ya reflejaban
  la realidad (gate anti-brick de la factory); `IXGeneralVerifier.sol` todavía decía "Robinhood:
  pendiente" — corregido.
- **Higiene de tests**: `test/Fork.t.sol` hacía un early-return sin RPC que forge reportaba como
  `[PASS]` sin ejecutar nada (falso verde). Ahora usa `vm.skip(block.chainid != 4663)`, que reporta
  "skipped" honestamente. Repro real: `forge test --match-contract Fork --fork-url robinhood -vv`
  (verificado verde en esta misma pasada).
- **Docs del paquete** (este archivo + `AUDIT-STATUS-f70e5476.md`): números de tests/tamaño stale,
  la fila de `rotateAttester` del preaudit contradiciendo el finding 5 de v3 sin marcarlo, y una
  sección de "claims elsewhere" que ya era ella misma stale. Ver las notas inline más abajo.

### EIP-170: la factory embebe el initcode ENTERO del vault

`SocialFeeEscrowFactory.newVault` hace `new SocialFeeEscrow(...)`, así que agregar contenido a
`SocialFeeEscrow.vaultUISchema()` (lo mandado arriba) infla el bytecode de **ambos** contratos, no
solo del vault — el margen de 10 KB+ del vault es irrelevante para el presupuesto de la factory.
Agregar `claimByProof` + `recoverUnclaimed` tal cual (con sus `FieldDescriptor[]` completos y la
prosa bilingüe original, más verbosa) hubiera dejado a la factory ~2,950 B por encima del cap de
EIP-170 — no arrancaba. Mitigado con, en orden de impacto medido:

1. Funciones internas compartidas `_fd`/`_method`/`_arr1`/`_arr3` (SocialFeeEscrow) y `_fd`
   (Factory) en vez de construir cada `FieldDescriptor`/`VaultMethodSchema` inline en cada uno de
   los 7 métodos — via_ir comparte un solo cuerpo por JUMP en vez de duplicar la lógica de armado
   de struct 7 veces (~530 B ahorrados).
2. `claimByProof`/`recoverUnclaimed` quedaron con `inputs`/`outputs` vacíos (solo nombre +
   descripción bilingüe + `isWriteMethod`): la granularidad de `FieldDescriptor` por parámetro no
   es gratis y el tipo `struct` de `XGeneralProof` no tiene una representación honesta en el schema
   de todos modos (`FieldDescriptor.fieldType` no tiene un valor "tuple"). Esto SÍ es una
   concesión — un futuro con más margen debería revisar si vale la pena reintroducir los inputs.
3. `expectedTweet` (la view que "considerá exponer" para el flujo X) quedó **afuera** del schema:
   no es una acción de claim en sí y el presupuesto no alcanzaba para las tres cosas.
4. Traducciones recortadas (sin perder significado ni el bilingüe) en TODO `vaultUISchema()` y en
   las descripciones pre-existentes de la factory (`vaultDataSchema`, `_validateBeforeLaunch`) —
   ninguna de género require()/revert() con match exacto en tests fue tocada.

Medido con `forge build --sizes` en cada paso (no estimado):

| Contrato | Tamaño runtime | Margen vs 24,576 B |
|---|---|---|
| `SocialFeeEscrow` | 14,449 B | 10,127 B |
| `SocialFeeEscrowFactory` | 24,440 B | **136 B** — más ajustado que el margen post-v3 (460 B). Cualquier adición futura a `SocialFeeEscrow.vaultUISchema()` (o a la factory) DEBE re-medir con `forge build --sizes` antes de mergear; con este margen, la próxima adición probablemente necesite el patrón de lookup-table que ya se venía recomendando, no más recortes de copy. |

`forge test`: **95/95** (94 corridos + 1 `vm.skip` honesto sin `--fork-url`) — mismo total que
antes, solo se actualizó el test `test_vaultUISchema_tieneMetodos` (4→7 métodos, nuevo orden) para
que siga siendo verde con el schema ampliado. Fork E2E verde contra RPC real de Robinhood
(`forge test --match-contract Fork --fork-url robinhood -vv`), incluyendo la aserción de 7 métodos.

---

## Post-v3 — Robinhood's official XGeneralVerifier wired in (2026-07-16)

*Sección histórica: cifras y estado al corte post-v3 / post-X_VERIFIER, antes del pre-audit propio
de arriba. Se conserva tal cual se escribió — ver la sección de arriba para el estado actual.*

Flap deployed its official `XGeneralVerifier` on Robinhood Chain and Jose verified it
on-chain (has code, chain id 4663): `0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17` (docs.flap.sh).
Added as `RobinhoodAddresses.X_VERIFIER`; `SocialFeeEscrowFactory._getXVerifier()` now returns it
for `block.chainid == 4663` instead of `address(0)` (BSC 56 unchanged). This resolves the
preaudit High #2 gate for Robinhood specifically: twitter vaults can now be **created** there too
(previously rejected with `"x verifier not deployed on this chain"`), and the twitter claim path
(`claimByProof`) is now live end-to-end on Robinhood, not just BSC.

New TDD coverage in `test/AuditFixes.t.sol`: `test_xVerifier_robinhood_devuelveLaDireccionOficial`,
`test_xVerifier_bsc_sigueSiendoElDeBSC`, `test_twitterVault_enRobinhood_bakeaElVerifier` (all born
red against the pre-fix code, now green). The preexisting `test_twitter_sinVerifier_rechazadoAlCrear`
/ `test_twitter_sinVerifier_charsetRevientaPrimero` (which used to exercise chain 4663 as the
"verifier not deployed" case) moved to BSC Testnet (97, supported by `_getVaultPortal` but with no
`_getXVerifier` entry) to keep covering the anti-brick gate for chains Flap hasn't reached yet.

`forge test`: 95 of 95 green (92 pre-existing + 3 new). Fork E2E green against live Robinhood RPC.
`SocialFeeEscrowFactory` runtime size: 24116 B, margin 460B under the 24576 B EIP-170 cap
(measured with `forge build --sizes`).

> **Historical figures — this section records the state at the X_VERIFIER cut.** The schema
> completeness work that followed (see the EIP-170 section at the top) changed both numbers.
> **Current, shipped figures: 95 tests (94 run + 1 skipped without `--fork-url`); factory
> 24,440 B / 136 B margin.** Always trust the header, not this section.

## v3 — response to GT's formal audit report (f70e5476, 2026-07-16)

*Sección histórica (figures at the v3 cut): el test count y el tamaño de la tabla de margen más
abajo son del corte v3, previos al post-v3 (X_VERIFIER) y al pre-audit propio de arriba — usar los
números de la sección "Pre-audit propio" al inicio de este archivo para el estado actual real.*

The owner reviewed all 6 findings and marked them all **TP** — every one is fixed in this
revision. See `AUDIT-STATUS-f70e5476.md` for the finding-by-finding sign-off copy of your report.

| # | Finding | Severity | Resolution | Covering tests |
|---|---|---|---|---|
| 1 | `_parseType` used a standalone `revert(unicode"...")` instead of the mandated `require(cond, "msg")` form (SYS-REQ-LITERAL-ERRORS) | High | Replaced with `require(false, unicode"...")`, same condition, same message, same order (charset/length errors still surface first from `newVault`'s call sites). | `test_F1_parseType_tipoInvalido_usaFormaRequire`, plus the pre-existing `test_tipoInvalido_y_recoveryCap` unaffected (same revert string). |
| 2 | UI-facing view strings (`description()`, `vaultUISchema()`, `vaultDataSchema()`, `tokenCreationPolicies()`) were English-only while every require/revert is bilingual (SYS-REQ-MULTILANG) | High | Every user-facing view string now carries a `English / 中文` form. `description()` builds a full English sentence and a full Chinese mirror (not fragment-by-fragment) so both read grammatically, joined by `" / "`. Schema/method/field descriptions on both contracts got inline `"... / ..."` translations. Chinese text was kept deliberately terse on the **factory** side (see finding-2/EIP-170 note below) since every added byte counts against the 24576 B runtime cap; the **vault** side had 10 KB+ of headroom so its translations are fuller. | `test_F2_description_esBilingue`, `test_F2_vaultUISchema_esBilingue`, `test_F2_factorySchemas_sonBilingues`. |
| 3 | `recoveryDays` had no minimum (only `<= 3650`), letting a creator seize an unclaimed social escrow before the real identity had a fair chance to claim it (COM-FUND-DIVERSION) | High | Added a floor: `recoveryDays == 0 \|\| recoveryDays >= 30` (0 still means "never"; upper bound `<= 3650` unchanged). `vaultDataSchema()`'s `recoveryDays` field description now states the 30–3650 range. | `test_F3_recoveryDays_menorA30_reverts`, `test_F3_recoveryDays_cero_siempreOk`, `test_F3_recoveryDays_treinta_ok`, `test_F3_recoveryDays_treintaCincuenta_ok`, `test_F3_recoveryDays_masDelMax_reverts` (existing `test_tipoInvalido_y_recoveryCap` upper-bound case unaffected). |
| 4 | Non-upgradeable vault had no Guardian-controlled `receive()` forward switch — only after-the-fact `emergencyWithdrawNative` (SYS-REQ-RESCUE-MECHANISM) | High | New Guardian-only `setRescueForward(bool on, address to)` + `rescueForward`/`rescueTo` storage. `receive()` now best-effort forwards `msg.value` to `rescueTo` via `.call` when the switch is on, emitting `Forwarded`; it **never reverts** — if the forward fails the ETH simply stays in the vault (still rescuable via `emergencyWithdrawNative`). Confirmed viable against Flap's actual tax-delivery mechanism: `.call` under Rule 005 (<1M gas), not a 2300-gas stipend (`test/Fork.t.sol`). | `test_F4_receive_sinSwitch_acumulaNormal`, `test_F4_guardian_activaForward_ySeForwardea`, `test_F4_forwardATargetQueRevierte_receiveNuncaRevierte`, `test_F4_setRescueForward_soloGuardian`, `test_F4_setRescueForward_onSinDestino_reverts`, `test_F4_receiveConForward_gasBajo1M`. |
| 5 | `rotateAttester` was self-gated (`msg.sender == attester` only) — the Guardian had no path to rotate a lost/compromised attester key, which would permanently break `claimAndBind` for every GitHub vault (SYS-REQ-GUARDIAN-ACCESS) | High | Gate is now `msg.sender == attester \|\| msg.sender == _getGuardian()`. NatSpec/comments that claimed "self-gated: ni admin ni Guardian" corrected on both the `attester` state var and the function itself. | `test_F5_guardian_puedeRotarAttester`, `test_F5_attesterVigente_siguePudiendoRotar`, `test_F5_randomAddress_noPuedeRotar`, `test_F5_rotarPorGuardian_vaultsLeenElNuevoEnVivo`; pre-existing `test_rotateAttester_soloElVigente` updated (new message text, needs a supported chain since `_getGuardian()` is now evaluated in the OR) and `test_rotateAttester_voucherViejoMuere_nuevoFirma` / `test_rotateAttester_zero_reverts` unaffected. |
| 6 | Twitter claim replay guard was per-claimer (`lastTweetId[msg.sender]`), so a wallet named in an older but still oracle-valid tweet could rebind/sweep *after* a newer tweet had already bound a different wallet, diverting the newer wallet's accrued balance | Low | `lastTweetId` is now a single global `uint128` (was `mapping(address => uint128)`). `claimByProof` requires `proof.tweetId > lastTweetId` (global) before accepting, mirroring how `bindNonce` globally invalidates old GitHub vouchers. **ABI change**: the public getter went from `lastTweetId(address) → uint128` to `lastTweetId() → uint128`. Grepped `C:\Users\PC\Flap\web` for `lastTweetId` — no references found, so no web-side follow-up is needed today; flagging in case a future integration reads it. | `test_F6_replayGlobal_walletViejaNoPuedeRobarTrasRebindMasNuevo` (the exact scenario from the finding), `test_F6_replayGlobal_tweetIdCrecienteSigueFuncionandoParaRebind` (legit re-bind still works); pre-existing `test_claimByProof_happyPath` updated for the new getter signature. |

### EIP-170 margin after v3 (measured, not estimated)

`forge build --sizes` after all 6 fixes:

| Contract | Runtime size | Margin vs 24576 B |
|---|---|---|
| `SocialFeeEscrow` | 14,122 B | 10,454 B (comfortable — F4's new storage/functions and F2's fuller bilingual strings fit easily) |
| `SocialFeeEscrowFactory` | 24083 B | **a 493-byte margin** (tight — ~2%) |

F2 (bilingual views) and F4 (rescue-forward) are exactly the bytecode risk flagged in the task:
the factory's `vaultDataSchema()`/`tokenCreationPolicies()` Chinese strings pushed the factory
**over** the limit on the first pass (measured: -636 B, i.e. undeployable). Trimmed the added
Chinese/English copy (kept meaning, cut verbosity) plus shortened one pre-existing, unrelated
`_validateBeforeLaunch` message to recover margin. That margin (at the v3 cut) was real and
verified, but thin — any future factory-side addition (new field, longer message, another require) should
re-run `forge build --sizes` before merging, since ~2% headroom leaves little room before this
needs an actual refactor (e.g., moving descriptions to a lookup pattern) rather than copy edits.

### Verification run for v3

- `forge test`: **92 of 92 green** (71 pre-v3 + 21 new: `test/AuditFixesV3.t.sol`).
- `forge test --match-contract ForkTest --fork-url robinhood -vv`: green against the live chain
  (real launch → tax → GitHub claim → sweep, same flow as v2, run again after the v3 changes).
- `forge build --sizes`: see table above.

### Claims elsewhere that were stale because of v3 — RESOLVED

*Esta sub-sección quedó ella misma stale (era una lista de pendientes; los tres ítems ya están
arreglados). Se conserva solo el resumen de qué se hizo y dónde, no la lista original de "flagged,
not rewritten here".*

- `C:\Users\PC\Flap\web\app\directions\terminal\TerminalHome.tsx` — el claim "the one emergency
  hatch is flap's guardian" ya no está literal; reescrito para reflejar que el Guardian tiene 3
  puntos gateados (`emergencyWithdrawNative`, `setRescueForward`, `rotateAttester`). Ver commit
  `9c647df`.
- `C:\Users\PC\Flap\web\app\directions\manga\MangaHome.tsx` y
  `C:\Users\PC\Flap\web\app\directions\sherwood\SherwoodHome.tsx` — badges actualizados a "95 tests"
  (verificado: ambos archivos dicen `95 tests` hoy). Ver commit `9c647df`.
- `C:\Users\PC\Flap\contracts\README.md` — pase de honestidad completo en este mismo pre-audit
  (ver la sección "Pre-audit propio" al inicio de este archivo): ya no dice "sin funciones
  privilegiadas" ni tiene la sección "⚠️ GUARDIAN placeholder"; conteos de tests y tamaño
  actualizados; constructor de la factory corregido a 1 arg.

---

*Sección histórica (figures at the preaudit cut, 2026-07-15): la más vieja de las tres capas de
este archivo (preaudit → v3 → post-v3 → pre-audit propio). El test count de abajo (71/71) es de
ESE momento — ver el inicio del archivo para el estado actual real.*

This package responds to your preaudit of 2026-07-15. It now contains the full `src/` tree,
**the complete test suite** (`test/`, per "blocks sign-off"), and `foundry.toml`.

## Fixes in response to the preaudit

| # | Your finding | Resolution | Covering tests |
|---|---|---|---|
| High 1 | VaultPortal gate not hardcoded | **Fixed as you recommended**: constructor param removed entirely; `newVault` gates on the inherited `_getVaultPortal()` (per-chain hardcoded, your reference pattern). A `vaultPortal()` view exposes the effective gate for post-deploy verification. | `test_portalGate_*` (3) |
| High 2 | Twitter vaults permanently bricked while `xVerifier == 0` on the chain | **Fixed as you recommended**: the factory rejects `newVault()` for `identityType=twitter` when `_getXVerifier()` returns zero on the current chain. | `test_twitter_sinVerifier_*` (2), `test_twitter_conVerifier_creaEnBSC` |
| Critical | TYPE_WALLET vaults have zero recovery path if the wallet can't receive ETH | **Fixed**: new `identityWallet` immutable (the original identity, never mutated) + `rebindWallet(address newPayout)` gated to `msg.sender == identityWallet`. A misconfigured contract wallet that can't *receive* can still *execute* a call and rotate its payout to a working address — preserving the trust model (only the proven identity directs funds). A wallet that can neither receive nor execute is equivalent to a burned key in any design; that residual case is now covered by the Guardian hatch below. | `test_rebindWallet_*` (4) |
| High | `recoverUnclaimed()` push-only to a possibly-broken `creator` | **Fixed**: signature is now `recoverUnclaimed(address to)`. Since the destination became caller-chosen, the function is no longer permissionless: gated to `msg.sender == creator`. | `test_recover_*` (3 new + 4 updated) |
| Medium | No Guardian anywhere | **Adopted your Option A** (explicit product decision by the owner): `emergencyWithdrawNative(address to)` gated by the inherited `onlyGuardian` (official per-chain Guardian, `0x0000b487…0000` on 4663). CEI, full-balance rescue, does not touch `totalPaid`. | `test_emergencyWithdraw_*` (3) |
| High (new) | Attester key immutable everywhere, no rotation path | **Fixed** (product decision): `factory.attester` is now storage with `rotateAttester(address)` gated to the *current attester key itself* (no admin, no Guardian — ⚠️ **superseded by v3 finding 5**: the Guardian was later added as a co-gate; see the v3 table above, this row is preaudit-era history only). Vaults no longer store the attester — they hold an immutable `attesterSource` (the factory) and read the current attester **live** at claim time, so a rotation instantly invalidates old-key vouchers across every vault, past and future. The read-side ABI (`attester()` view on vault and factory) is unchanged. | `test_rotateAttester_*` (3) |

Notes on EIP-712 mechanics: unchanged (your review passed them) — `bindDigest`, nonce, deadline,
domain separator per vault all as reviewed.

## Verification we ran before sending

- **71/71 unit tests green** (includes 16 new tests born red against the pre-fix code).
- **Fork E2E green against live Robinhood Chain** (`forge test --match-contract ForkTest
  --fork-url robinhood`): real launch through the real VaultPortal (exercising the hardcoded
  gate) → tax → GitHub claim (attester read live from the factory) → sweep.

## Contracts under review (ours)

- `src/SocialFeeEscrow.sol` — the vault (wallet / GitHub / X identity; claim paths per type;
  `rebindWallet`; `recoverUnclaimed(to)`; Guardian `emergencyWithdrawNative`).
- `src/SocialFeeEscrowFactory.sol` — Portal-gated factory (hardcoded gate), on-chain identity
  normalization, canonical rotatable attester, twitter-verifier availability gate.

Everything under `src/flap/` is your own interfaces/bases vendored for compilation
(not under review). `src/flap/oz-shims/` shims the upgradeable-OZ import path.

## Build

Foundry, `solc 0.8.26`, `optimizer_runs = 200`, `via_ir = true`. Deps: OpenZeppelin Contracts
v5.4.0 + forge-std (tests). Full repo: <https://github.com/0x-Keezy/robinshare>.

Contact: @K3zzi (TG) · @0xKeezy
