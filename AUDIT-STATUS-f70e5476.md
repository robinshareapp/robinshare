# Flap Vault Interaction Risk Report — status (FLEDGE response)

Original report generated: 2026-07-16 08:58:22 UTC. Source:
`f70e5476_robinshare-contracts-v2-version1.md`. This file is the sign-off copy: every finding is
marked and annotated with what shipped in v3. See `AUDIT-NOTES.md` (v3 section) for the
finding-by-finding table with covering tests, and `test/AuditFixesV3.t.sol` for the tests
themselves.

## Vault Security Rating
High

## Status Guide / 状态说明

| Status | Meaning / 含义 |
|:---:|---|
| **TP** | True Positive — This is a real issue, we will fix it. / 确认问题，我们会修复。 |
| **FP** | False Positive — This is not a real issue, the analysis is incorrect. / 误报，分析有误。 |
| **By Design** | This is intentional behavior, not a bug. / 这是设计如此，非缺陷。 |
| **Acknowledged** | The issue is real but the impact is acceptable, will not fix. / 问题确实存在，但影响在可接受范围内，不修复。 |

---

## Risk Findings

### Finding 1: Standalone revert with string literal instead of require() in factory _parseType (SYS-REQ-LITERAL-ERRORS)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** SYS-REQ-LITERAL-ERRORS: SocialFeeEscrowFactory._parseType uses a standalone `revert(unicode"identity type must be wallet|github|twitter / 身份类型无效")` statement rather than the mandated `require(condition, "message")` form. The rule prohibits standalone `revert("...")`/`revert(unicode"...")` in developer code because it breaks UI error-string compatibility, even though the string is well-formed and bilingual.
- **Vulnerable Code:**
  - `SocialFeeEscrowFactory.sol (_parseType): revert(unicode"identity type must be wallet|github|twitter / 身份类型无效")`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** —
> **Fixed in v3:** `_parseType` now ends with `require(false, unicode"identity type must be wallet|github|twitter / 身份类型无效"); return 0;` — same condition, same message, mandated form. Covered by `test_F1_parseType_tipoInvalido_usaFormaRequire` (new) and the pre-existing `test_tipoInvalido_y_recoveryCap` (unaffected, same revert string).

### Finding 2: UI-facing view strings are English-only while error messages are bilingual (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** SYS-REQ-MULTILANG: The contract establishes multi-language intent — every require/revert message uses a bilingual `English / 中文` form. However, the user-facing strings returned by view functions (description(), vaultUISchema(), vaultDataSchema(), tokenCreationPolicies()) are written in English only, missing the Chinese translations. Under the rule, once multi-language support is evidenced, every user-facing string (including view/status strings) must include all languages separated by ` / `.
- **Vulnerable Code:**
  - `SocialFeeEscrow.vaultUISchema: "Trading-fee escrow for one identity (wallet, GitHub or X). Funds can only ever go to the wallet that proved the identity."`
  - `SocialFeeEscrow.vaultUISchema: "Prove the identity with an attester voucher, bind the payout wallet and claim all pending ETH."`
  - `SocialFeeEscrow.vaultUISchema: "Push all pending ETH to the already-bound wallet. Anyone may pay the gas."`
  - `SocialFeeEscrow.vaultUISchema: "ETH accumulated and not yet paid out."`
  - `SocialFeeEscrow.vaultUISchema: "The wallet that proved ownership of the identity."`
  - `SocialFeeEscrow.vaultUISchema: field descriptions "Wallet that will receive the fees", "Voucher expiry (unix seconds)", "Attester voucher signature", "ETH currently claimable", "Wallet bound to the identity (zero until proven)"`
  - `SocialFeeEscrow.description: "FLEDGE fee escrow for ", "bound to ", "unclaimed (recoverable by creator)", "waiting for its person", " ETH pending, ", " ETH paid out. Status: "`
  - `SocialFeeEscrowFactory.vaultDataSchema: description "Escrows 100% of the vault share of trading fees for ONE identity..." and field descriptions "wallet | github | twitter", "Handle for github/twitter (empty for wallet)", "Recipient wallet (only for identityType=wallet, else 0x0)", "Days until creator may recover unclaimed funds (0 = never)"`
  - `SocialFeeEscrowFactory.tokenCreationPolicies: "Quote token must be the native token (ETH).", "Vault share of the tax must be greater than zero."`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** —
> **Fixed in v3:** every string listed above now carries an `English / 中文` form. `description()` builds a full English sentence plus a full Chinese mirror (grammatically coherent in both, joined by `" / "`) rather than interleaving fragments. Factory-side translations were kept deliberately terse (see Finding 4's EIP-170 note — the factory had negative bytecode margin on the first pass) while the vault side, with 10 KB+ of headroom, got fuller translations. Covered by `test_F2_description_esBilingue`, `test_F2_vaultUISchema_esBilingue`, `test_F2_factorySchemas_sonBilingues`.

### Finding 3: Creator recovery window has no minimum bound, enabling fee seizure before the legitimate identity can claim (COM-FUND-DIVERSION)
- **Severity:** High
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** In SocialFeeEscrowFactory.newVault, recoveryDays is only bounded above (<= 3650) with no minimum, so recoveryAfter can be set as low as block.timestamp + 1 day. For GITHUB/TWITTER escrows boundWallet stays address(0) until the identity proves ownership, so once the short window elapses the creator can call recoverUnclaimed(to) at any time and push the entire (and all future-accruing) escrow balance to an arbitrary creator-chosen address, diverting fees that the vault advertises as reserved for the social identity. The legitimate identity holder may not even be aware the escrow exists within such a short window.
- **Vulnerable Code:**
  - `robinshare-contracts-v2/src/SocialFeeEscrowFactory.sol - newVault (recoveryDays validation)`
  - `robinshare-contracts-v2/src/SocialFeeEscrow.sol - recoverUnclaimed`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** —
> **Fixed in v3:** added a floor — `require(recoveryDays == 0 || recoveryDays >= 30, ...)` — so a non-zero recovery window can no longer be shorter than 30 days (0 still means "never"; the existing `<= 3650` upper bound is unchanged). `vaultDataSchema()`'s field description now documents the 30–3650 range. Covered by `test_F3_recoveryDays_menorA30_reverts`, `test_F3_recoveryDays_cero_siempreOk`, `test_F3_recoveryDays_treinta_ok`, `test_F3_recoveryDays_treintaCincuenta_ok`, `test_F3_recoveryDays_masDelMax_reverts`.

### Finding 4: Non-upgradeable vault lacks Guardian-controlled receive() forward switch (SYS-REQ-RESCUE-MECHANISM)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** SocialFeeEscrow is non-upgradeable and provides a Guardian-only emergency withdraw (emergencyWithdrawNative) for ETH, but it does NOT implement the required Guardian-controlled receive() forward switch. The receive() function has an empty body with no forward-enabled flag, forward-address setter, or non-reverting low-level forwarding of msg.value. During an incident, incoming tax revenue cannot be redirected to a safe address at the point of receipt; the only recourse is repeated after-the-fact emergency withdrawals. Because the contract cannot be upgraded, this missing facet cannot be added later.
- **Vulnerable Code:**
  - `robinshare-contracts-v2/src/SocialFeeEscrow.sol - receive()`
  - `robinshare-contracts-v2/src/SocialFeeEscrow.sol - emergencyWithdrawNative`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** —
> **Fixed in v3:** new Guardian-only `setRescueForward(bool on, address to)` plus `rescueForward`/`rescueTo` state. `receive()` best-effort forwards `msg.value` to `rescueTo` via `.call` when the switch is on (emits `Forwarded`); if the forward fails, the ETH stays in the vault — `receive()` **never reverts**, preserving the hard invariant. Confirmed viable against how Flap actually delivers tax: `.call` under Rule 005 (<1M gas), not a 2300-gas stipend (see `test/Fork.t.sol:129-135`). This is also the finding that put the factory's bytecode over the EIP-170 limit on the first pass together with Finding 2 — see `AUDIT-NOTES.md` v3 section for the measured margin after trimming. Covered by `test_F4_receive_sinSwitch_acumulaNormal`, `test_F4_guardian_activaForward_ySeForwardea`, `test_F4_forwardATargetQueRevierte_receiveNuncaRevierte`, `test_F4_setRescueForward_soloGuardian`, `test_F4_setRescueForward_onSinDestino_reverts`, `test_F4_receiveConForward_gasBajo1M`.

### Finding 5: Guardian cannot rotate the canonical attester (rotateAttester self-gated) (SYS-REQ-GUARDIAN-ACCESS)
- **Severity:** High
- **Confidence:** Medium
- **Detected by:** rule_review
- **Description:** SocialFeeEscrowFactory.rotateAttester is gated solely by `require(msg.sender == attester)`. The Guardian returned by _getGuardian() is not authorized to call it. The attester is a critical signer address whose vouchers authorize payouts for every GitHub-identity vault (vaults read `attester` live from the factory). If the attester key is lost, the Guardian cannot rotate it to a successor, permanently breaking the claimAndBind path for all GitHub vaults; if the key is compromised, the Guardian cannot rotate it out to invalidate forged vouchers. This mirrors the setSigner/critical-address-rotation case the Guardian-access mandate is designed to protect against.
- **Vulnerable Code:**
  - `robinshare-contracts-v2/src/SocialFeeEscrowFactory.sol - rotateAttester`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** —
> **Fixed in v3:** gate is now `require(msg.sender == attester || msg.sender == _getGuardian(), ...)`. Corrected the NatSpec/comments that claimed "self-gated: ni admin ni Guardian" (both on the `attester` state variable and on `rotateAttester` itself — now stale claims). Covered by `test_F5_guardian_puedeRotarAttester`, `test_F5_attesterVigente_siguePudiendoRotar`, `test_F5_randomAddress_noPuedeRotar`, `test_F5_rotarPorGuardian_vaultsLeenElNuevoEnVivo`; pre-existing `test_rotateAttester_soloElVigente` updated for the new message text (and now needs a supported chain since `_getGuardian()` evaluates as part of the `||`).

### Finding 6: Twitter claim replay guard is per-claimer, allowing a stale authorization to override a newer binding and divert funds
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In SocialFeeEscrow.claimByProof the replay guard is `lastTweetId[msg.sender]` (keyed per candidate wallet) rather than a single global counter. The GitHub path (claimAndBind) uses the global `bindNonce` embedded in the signed digest, so any successful bind invalidates every previously issued voucher. The Twitter path has no such global invalidation: a wallet A that was named in an older but still oracle-valid tweet (tweetId T1) can call claimByProof and re-bind/sweep the entire current balance even after the handle owner posted a newer tweet naming wallet B (tweetId T2 > T1) and B already bound. Because each successful claim immediately sweeps `address(this).balance` to the newly bound wallet, the accumulated balance intended for the current bound wallet B is diverted to A. This is a divergence between the intended model (the funded handle controls the destination; a newer proven authorization should supersede older ones, as it does on the GitHub path) and the actual per-sender guard, with no on-chain revocation of an old, unused tweet authorization.
- **Vulnerable Code:**
  - `robinshare-contracts-v2\src\SocialFeeEscrow.sol: claimByProof (lastTweetId[msg.sender] replay guard)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** —
> **Fixed in v3:** `lastTweetId` is now a single global `uint128` (was `mapping(address => uint128)`); `claimByProof` requires `proof.tweetId > lastTweetId` (global) before accepting a claim, so any newer tweet invalidates every older one for every candidate — mirroring how `bindNonce` globally invalidates old GitHub vouchers. **Breaking ABI change**: the public getter went from `lastTweetId(address) → uint128` to `lastTweetId() → uint128`. Grepped `C:\Users\PC\Flap\web` for `lastTweetId` — no references found today, so no web follow-up is currently needed; flagging in case a future integration reads it. Covered by `test_F6_replayGlobal_walletViejaNoPuedeRobarTrasRebindMasNuevo` (the exact scenario described in this finding) and `test_F6_replayGlobal_tweetIdCrecienteSigueFuncionandoParaRebind` (legitimate re-bind still works); pre-existing `test_claimByProof_happyPath` updated for the new getter signature.

---

## Verification we ran before sending (v3)

*Figures below are at the v3 cut (2026-07-16, before the post-v3 X_VERIFIER wiring and before our
own pre-audit pass). Kept as a historical record of what we verified at the time; see the note
right after this section for the current, re-measured numbers.*

- **92 of 92 unit tests green** (`forge test`): 71 tests from the v2 (preaudit) round + 21 new tests
  born red against the pre-v3 code, in `test/AuditFixesV3.t.sol`.
- **Fork E2E green against live Robinhood Chain** (`forge test --match-contract ForkTest --fork-url
  robinhood -vv`): real launch through the real VaultPortal → tax → GitHub claim → sweep, re-run
  after the v3 changes.
- **`forge build --sizes`**: `SocialFeeEscrow` runtime 14,122 B (margin 10,454 B vs the 24,576 B
  EIP-170 cap). `SocialFeeEscrowFactory` runtime 24083 B (a 493-byte margin — tight; Findings 2 and
  4 add bytecode and the factory briefly exceeded the cap before we trimmed the added Chinese/English
  copy for size).

### Current numbers (re-measured after the post-v3 X_VERIFIER wiring and our own pre-audit pass)

The two figures above are now stale on two counts: the post-v3 commit wired Robinhood's
`X_VERIFIER` (+3 tests, unrelated size delta), and this pre-audit pass added `claimByProof` +
`recoverUnclaimed` to `SocialFeeEscrow.vaultUISchema()` (closing the doc-vs-code mandate gap our
own adversarial pre-audit found) — which, because the factory embeds the vault's entire initcode
via `new SocialFeeEscrow(...)` in `newVault`, pushed `SocialFeeEscrowFactory` **over** the EIP-170
cap until we trimmed schema/string verbosity (shared `_fd`/`_method`/`_arr1`/`_arr3` helpers +
leaner bilingual copy on both contracts) to claw the margin back. Verified with `forge test` /
`forge build --sizes` in this same pass:

- **95/95 unit tests green** (94 run + 1 honestly `vm.skip`-ped without `--fork-url`): 71 v2 +
  21 v3 + 3 post-v3 (`X_VERIFIER` wiring). Fork E2E green against live Robinhood Chain
  (`forge test --match-contract Fork --fork-url robinhood -vv`).
- **`forge build --sizes`**: `SocialFeeEscrow` runtime 14,449 B (margin 10,127 B). `SocialFeeEscrowFactory`
  runtime 24,440 B (margin **136 B** — thinner than the v3 cut; see `AUDIT-NOTES.md` for the full
  breakdown and the recommendation to move to a lookup-table pattern if more room is needed later).
