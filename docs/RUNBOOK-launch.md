# RUNBOOK — Launch de RobinShare en Robinhood Chain (launch-day checklist)

> **Estado: AUDITADO Y ENSAYADO.** Audit de GT aprobado para deploy (2026-07-17, "you can proceed
> with the deployment"). Cada comando de este runbook fue ensayado end-to-end contra un anvil fork
> de Robinhood (deploy → launch → tax → claim → sweep, todo verde) — evidencia y outputs reales en
> `docs/ENSAYO-LAUNCH-2026-07-17.md`.
> **Fuente del deploy: el tag `audited-v3`** (bytecode deployado == auditado; NO deployar del
> branch `v4-schema-exact` sin otra ronda de audit).

## 0. Pre-flight (las 4 llaves de Jose)

- [ ] **ETH en chain 4663** en la wallet deployer (>= 0.05 ETH: gas + ~$1 fee + dev-buy).
- [ ] **Wallet ATTESTER** nueva y dedicada (`cast wallet new`), SIN fondos. Su address =
      `ATTESTER_ADDRESS` (attester canónico de la factory); su PK va SOLO al env de Vercel
      (`ATTESTER_PK`). Si address y PK no matchean, `/api/health` lo delata (`attesterMatches:false`).
- [ ] **GitHub OAuth app** (`GITHUB_CLIENT_ID`/`SECRET`) — paso a paso exacto en
      `docs/DEPLOY-WEB.md` (callback: `https://<dominio>/api/attest/github/callback`).
- [ ] **Identidad piloto + recoveryDays** (propuesta: `github:0x-keezy`, recoveryDays=0).
      OJO audit v3 F3: recoveryDays válidos son **0 (nunca) o >= 30** — 1..29 revierte.

> Twitter/X **NO necesita llave**: usa el `XGeneralVerifier` oficial de Flap, ya vivo en Robinhood
> (`0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17`) y cableado en la factory. (La app de Reclaim del
> plan original quedó obsoleta — esa ruta se eliminó.)

## 1. Deploy de la factory (desde `audited-v3`, con attester canónico)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd contracts
git diff --stat audited-v3 -- src/ script/   # DEBE salir vacío (main == lo auditado)

ATTESTER_ADDRESS=0x<addr-del-attester> \
  forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
# anotar FACTORY=0x...  (y confirmar en el log: "Canonical attester" y "VaultPortal")

# verificar en Blockscout (constructor de UN arg — el gate del portal es heredado/hardcodeado,
# ya no es param; corregido tras el ensayo):
forge verify-contract $FACTORY src/SocialFeeEscrowFactory.sol:SocialFeeEscrowFactory \
  --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args $(cast abi-encode "constructor(address)" $ATTESTER_ADDRESS)
```

Luego: web a Vercel con `NEXT_PUBLIC_FACTORY_ADDRESS=$FACTORY` — checklist completo en
`docs/DEPLOY-WEB.md` (env vars, OAuth app, smoke de `/api/health`).

## 2. vaultData del piloto (4 campos — el attester NO va acá, es canónico de la factory)

```bash
# (string identityType, string identityValue, address identityWallet, uint256 recoveryDays)
VAULT_DATA=$(cast abi-encode "f(string,string,address,uint256)" \
  "github" "0x-keezy" "0x0000000000000000000000000000000000000000" 0)
# recoveryDays: 0 = nunca; si no, >= 30 (piso del audit v3). Ensayado: 0 pasa.
```

## 3. Salt (minería LOCAL, sin RPC — el portal exige vanity 0x7777)

```bash
node scripts/mine-salt.mjs 7777      # -> {"salt":"0x..","token":"0x..7777","iterations":N}
# guardar SALT=0x.. y TOKEN_PREDICHO=0x..7777
```

## 4. Launch

**Opción A — página `/create` (recomendada, la vía del producto):** con la web deployada y
`NEXT_PUBLIC_FACTORY_ADDRESS` seteada: conectar wallet → nombre/símbolo + a quién van las fees
(github/x/wallet) + dev-buy → firmar. La página mina el salt local y llama al VaultPortal.

**Opción B — CLI (llamada directa al VaultPortal):** ensayada verbatim en el fork — el comando
corre tal cual en Git Bash (el `{}` de metadata no necesita escaping). Params fork-verificados:
`dexThresh=1`, `migratorType=1`, `dexId=0`, `lpFeeProfile=0`, `tokenVersion=6`, `quoteToken=0x0`,
`mktBps=10000`, tax 3%/3%, `taxDuration=3153600000`, `antiFarmerDuration=259200`.
`value = quoteAmt` (dev-buy, ej. 0.01 ETH).

```bash
cast send 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B \
  "newTokenV6WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8,address,bytes))" \
  "(Fledge Pilot,FLEDGE,{},1,$SALT,1,0x0000000000000000000000000000000000000000,10000000000000000,0x,0x0000000000000000000000000000000000000000000000000000000000000000,0x,0,0,300,300,3153600000,259200,10000,0,0,0,0,0x0000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000,6,$FACTORY,$VAULT_DATA)" \
  --value 0.01ether --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $DEPLOYER_PK
```

> Alternativa turnkey: `script/LaunchPilot.s.sol` (deploy+mine+launch+verify en 1 broadcast; acepta
> `META_CID` para el arte). No ensayada en esta pasada — la Opción B sí, verbatim.

## 5. Verificación post-launch (todas obligatorias)

```bash
IDH=$(cast call $FACTORY "identityHashFor(string,string,address)(bytes32)" "github" "0x-keezy" 0x0000000000000000000000000000000000000000 --rpc-url https://rpc.mainnet.chain.robinhood.com)
ESCROW=$(cast call $FACTORY "getVaults(bytes32)(address[])" $IDH --rpc-url https://rpc.mainnet.chain.robinhood.com)
```
- [ ] Token visible en flap.sh/robinhood/board y en Blockscout; su address == `TOKEN_PREDICHO`.
- [ ] `cast call $ESCROW "taxToken()(address)"` == token lanzado.
- [ ] `cast call $ESCROW "attester()(address)"` == `ATTESTER_ADDRESS` (canónico, leído vivo de la factory).
- [ ] `cast call $ESCROW "description()(string)"` legible (bilingüe).
- [ ] Comprar una pizca vía flap.sh → `cast balance $ESCROW` sube (el tax se despacha por lotes; puede demorar).

## 6. Smoke de claim real

- Abrir `https://<dominio>/claim/$ESCROW`, conectar wallet, flujo GitHub → `claimAndBind` → ETH
  llega a la payout. (Ensayado en fork incluyendo la firma del `bindDigest` y el `sweep()` posterior
  — comandos manuales de respaldo en `ENSAYO-LAUNCH-2026-07-17.md` §7.)
- La ruta X ya está viva (oráculo beta `verifyx.taxed.fun/prove?chain_id=4663`): probarla como
  fast-follow con un tweet real, no como gate del launch.
- Post en X: SOLO después del claim verde (pasar por quality-gate antes de publicar).

## 7. Rollback / incidentes

- El launch NO es reversible (token vivo). Si el escrow no recibe tax: revisar `mktBps=10000` en el
  tx y el `marketAddress` del token (Helper `0xb10bD2672aE63735d677164A54B573a016f0203C`).
- Si el attester falla: `web/scripts/attest-manual.mjs` (verificación humana; documentar).
- Incidente mayor: el Guardian oficial de Flap tiene `emergencyWithdrawNative` + `setRescueForward`
  (audit v3 F4/F5) — es SU multisig, no una key nuestra; coordinarlo con GT.
- Fondos SIEMPRE seguros: sin bind no hay egress salvo `recoverUnclaimed` (si recoveryDays>0).

## Apéndice: gotchas de ensayo (para futuros fork-tests manuales)

- **NO usar las cuentas default de anvil como payout/receptoras en un fork de Robinhood**: en la
  chain real esas addresses públicas ya tienen delegaciones EIP-7702 de un sweeper bot
  (`0x0436…f2d7`) — el ETH que reciben desaparece al instante y parece un bug del contrato. Usar
  addresses frescas (`cast wallet new` / `makeAddr`). Detalle en `ENSAYO-LAUNCH-2026-07-17.md` §3.
