# RobinShare — route trading fees to the builders who earned them

**RobinShare** lets anyone launch a coin on **[pons](https://pons.fun) v2** (Robinhood Chain)
whose trading fees accrue to **one person** — identified by their **GitHub handle or wallet** —
without that person needing a wallet up front. They claim later by proving the identity.

Robin Hood is about sharing with others. Here, that means sharing with the devs who actually
earned it.

- **Chain:** Robinhood Chain (4663)
- **Launchpad:** pons v2 — `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`
- **Contracts:** `RobinShareVault` + `RobinShareVaultFactory`
- **X:** [@RobinShareApp](https://x.com/RobinShareApp)

> **Status: LIVE on Robinhood Chain mainnet, and NOT audited.**
>
> - **Site:** <https://www.robinshareapp.com>
> - **Factory:** [`0xBf25E1d9082B5Ad0b8C68f072E94C797028c6855`](https://robinhoodchain.blockscout.com/address/0xBf25E1d9082B5Ad0b8C68f072E94C797028c6855)
> - **Attester** (the trusted key on the GitHub path, disclosed on purpose):
>   [`0x1E047B17BF45aE7D29287bd6389De4982C343f0A`](https://robinhoodchain.blockscout.com/address/0x1E047B17BF45aE7D29287bd6389De4982C343f0A)
>
> The full cycle has been exercised on mainnet: launch → trade → harvest → prove identity with the
> real GitHub OAuth → claim. **This contract has not been audited**, and that is an accepted risk,
> not a pending task. Remaining decisions are in [`PENDIENTES.md`](PENDIENTES.md).
>
> **Disclosure:** the person who builds RobinShare also works on PonsVault, a competing product on
> this chain.

## How it works

1. **Name them** — pick a builder by GitHub or wallet. Their coin launches on pons in
   seconds, always paired against native ETH.
2. **Fees accrue** — a creator tax set at launch (up to the cap pons enforces, today 10%) lands
   in an immutable vault under that identity's name. Steady-state that's **10.7% of trade
   volume** reaching the vault; in the first seconds it is higher because pons' snipe tax lands
   in the same bucket.
3. **They claim** — they prove it's them (GitHub OAuth voucher, a tweet verified by an on-chain
   oracle, or a wallet signature) and withdraw the ETH.

## What is true, and what is not ours to promise

The vault has **no owner, no upgrade path, no pause and no emergency hatch**. Whoever launched
the coin can never redirect its fees — unless they set a recovery window at launch, which the
vault publishes on-chain and the claim page shows as a badge.

Two powers are **not** ours to disclaim, and the product says so on every page:

- **pons** — the launchpad's owner (a 2-of-3 multisig) can point any coin's `creatorFeeRecipient`
  somewhere else, behind a public 3-day timelock, and the change applies retroactively to
  anything not yet swept. Sweeping early is the mitigation.
- **our attester key** — on a **GitHub** vault, our signature *is* the proof of identity, so that
  key can bind any GitHub vault to any wallet. That is inherent to attesting an OAuth login
  on-chain. X and wallet vaults do not depend on it.

**Only ETH-paired launches are supported.** With an ERC-20 pair, pons credits fees in a
per-token ledger the vault cannot pay out from, so `attachToken()` refuses those launches
outright rather than trapping the money. That's roughly half of pons.

## Repo layout

| Path | What |
|---|---|
| `contracts/src/RobinShareVault.sol` · `RobinShareVaultFactory.sol` | The live rail. Foundry. |
| `contracts/src/pons/` | pons v2 addresses + the minimal ABI surface we call |
| `contracts/test/ForkPons.t.sol` | The whole money cycle against the **real** pons contracts |
| `web/` | Next.js 16 — landing, `/create` (3 transactions), `/claim/[vault]`, GitHub OAuth attester, X oracle proxy |
| `docs/RUNBOOK-launch-pons.md` | The exact launch procedure |
| `docs/superpowers/specs/2026-08-29-…-port-design.md` | The approved design, with its divergences dated |
| `PENDIENTES.md` | What still needs a human decision before any of this ships |

### The Flap rail (previous version, preserved)

RobinShare was originally built and audited on the **Flap** launchpad. That version is intact on
the **`flap-rail`** branch and the **`audited-v3`** tag, and `contracts/src/SocialFeeEscrow*.sol`
plus `contracts/src/flap/` still build here. It is **not** the live line: the audit covers that
tree, not this one.

One Flap dependency survives the port on purpose: the X claim route uses Flap's on-chain
`XGeneralVerifier` oracle. Whether to keep it is an open decision — `PENDIENTES.md` §4.

## Development

```bash
# contracts — unit tests
cd contracts && forge test

# the tests that actually prove the integration, against live pons
forge test --match-contract ForkPonsTest --fork-url robinhood --compute-units-per-second 40
```

A bare `forge test` **skips** the fork suite and still exits 0, so it proves nothing about pons.
Set `REQUIRE_FORK=1` to turn that skip into a failure.

```bash
# web
cd web && npm install && npm run dev
npx vitest run          # includes an executable honesty gate over the landing copy
```

## Security notes

- The vault is immutable and bound to a single identity at launch. Reviewed adversarially across
  several rounds; the findings and their fixes are in the commit history of `feat/pons-web`.
- The GitHub path relies on a factory-canonical attester (a constructor argument, never
  launcher-supplied — a launcher-supplied attester would enable self-signed rugs). Treat that key
  as **custodial**, not merely a signing key: see `PENDIENTES.md` §2 and §3.
- `attachToken()` verifies against pons' own registry that the launch routes its creator fees
  here *and* that our launcher made it, so the vault↔coin link cannot be squatted.
- **The contract has not been audited.** The Flap audit does not carry over: this is new code
  that custodies other people's ETH.

**Disclosure.** The person who builds RobinShare also works on **PonsVault**, a competing product
on this same chain, and RobinShare launches its coins on pons. There is no formal obligation to
say this; it is said anyway, because finding it out from somewhere else is worse. (`PENDIENTES.md`
§5.)

Not affiliated with Robinhood, pons or Flap.
