# TEST en MAINNET (Robinhood Chain 4663) — flujo A → identidad → B reclama

Probado end-to-end contra un fork de mainnet (script + claim). Acá corrés lo mismo en vivo.
**Todo con TU key local — nadie más la toca.** Montos mínimos (ETH real, pero centavos).

## Qué vas a probar

Wallet **A** (tu deployer) crea un token en Flap cuyas fees van a una **identidad** (tu **GitHub**, tu **X**, o una **wallet**). Después, wallet **B** **reclama** probando esa identidad y recibe el ETH.

- Para GitHub **sin montar GitHub-OAuth todavía**: usás el **attester manual** (vos atestás a mano y firmás el voucher con la key del attester). El mecanismo on-chain es idéntico al de producción.
- Para **wallet**: aún más simple — la wallet queda bindeada al crear y solo hace `sweep`.

## Prerrequisitos

- [ ] **Foundry** en PATH (`export PATH="$HOME/.foundry/bin:$PATH"`).
- [ ] **ETH en wallet A** en la chain 4663 (con ~0.03 ETH sobra: gas + ~$1 fee de Flap + dev-buy 0.005).
- [ ] Una **wallet attester dedicada** (la generás abajo; su key la guardás para cuando montes el attester real).
- [ ] Tus **wallet A** y **wallet B** (pueden ser dos cuentas tuyas de MetaMask; exportá sus private keys para los comandos, o usá `--account` de una keystore).

---

## Paso 0 — Generar la wallet attester (10 seg, la key NO sale de tu máquina)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cast wallet new
# guardá: Address -> es tu ATTESTER_ADDRESS ; Private key -> guardala para despues (el attester real)
```

## Paso 1 — Deploy factory + launch del token (wallet A, un solo comando)

**Variante GitHub** (fees a tu github; B reclama por github):

```bash
cd /c/Users/PC/Flap/contracts
IDENTITY_TYPE=github \
IDENTITY_VALUE=<tu-usuario-github> \
ATTESTER_ADDRESS=<address-del-paso-0> \
TOKEN_NAME="Fledge Test" TOKEN_SYMBOL=GIFT \
  forge script script/LaunchPilot.s.sol --rpc-url robinhood --broadcast --private-key <WALLET_A_PK>
```

**Variante X:** igual pero `IDENTITY_TYPE=twitter IDENTITY_VALUE=<tu-handle-x>`.
**Variante Wallet:** `IDENTITY_TYPE=wallet RECIPIENT=<wallet-B>` (sin `IDENTITY_VALUE`).

Del output anotá: **FACTORY**, **TOKEN**, **ESCROW**. (Para lanzar más tokens con la misma factory, pasá `FACTORY=0x…` y no la re-despliega.)

**Arte del token (opcional, para que se vea lindo en flap.sh):** subí una imagen (o el avatar del dev) al `/api/upload` de Flap y pasá el CID como `META_CID`:
```bash
# ej. avatar de github del receptor:
CID=$(curl -s "https://flap.sh/api/upload?warmup=true" \
  -F 'operations={"query":"mutation Create($file: Upload!, $meta: MetadataInput!){ create(file:$file, meta:$meta) }","variables":{"file":null,"meta":{"name":"Fund <dev>","symbol":"GIFT","description":"Fees for <dev>, claimable via GitHub","website":"https://github.com/<dev>"}}}' \
  -F 'map={"0":["variables.file"]}' \
  -F "0=@<(curl -sL https://github.com/<dev>.png);type=image/png" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s).data.create))")
# y agregá  META_CID=$CID  al comando forge script de arriba
```
(La página `/create` hace todo esto solo — la imagen es solo para el launch por CLI.)

## Paso 2 — Generar fees en el escrow

- **Real:** entrá a `flap.sh/robinhood`, buscá tu token (o `dexscreener.com/robinhood/<TOKEN>`) y comprá/vendé una pizca — el tax cae al escrow (puede demorar, se despacha por lotes).
- **Rápido (simular):** mandá un poco de ETH directo al escrow (su `receive()` lo acepta):
  ```bash
  cast send <ESCROW> --value 0.01ether --rpc-url robinhood --private-key <WALLET_A_PK>
  cast balance <ESCROW> --rpc-url robinhood   # deberia mostrar el saldo
  ```

## Paso 3 — B reclama

### Si la identidad es GITHUB o X (voucher del attester manual)

```bash
cd /c/Users/PC/Flap/web
ATTESTER_PK=<attester-key-del-paso-0> RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  node scripts/attest-manual.mjs <ESCROW> <WALLET_B>
# imprime {deadline, signature}  -> usalos abajo
```
```bash
export PATH="$HOME/.foundry/bin:$PATH"
cast send <ESCROW> "claimAndBind(address,uint256,bytes)" <WALLET_B> <deadline> <signature> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key <WALLET_B_PK>
```

### Si la identidad es WALLET (sin voucher, solo sweep)

```bash
cast send <ESCROW> "sweep()" --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key <cualquiera>
```

## Paso 4 — Verificar

```bash
cast call <ESCROW> "boundWallet()(address)"  --rpc-url robinhood   # == WALLET_B
cast call <ESCROW> "pendingAmount()(uint256)" --rpc-url robinhood  # 0 tras el claim
cast balance <WALLET_B> --rpc-url robinhood                        # subio ~lo que habia en el escrow
```

Y en el explorer: `https://robinhoodchain.blockscout.com/address/<TOKEN>` y `/address/<ESCROW>`.

---

## Después del test (para el flujo automático real)

El único cambio hacia producción es reemplazar el **attester manual** por el **attester server** (verifica GitHub/X solo y firma):
1. Deploy `web/` a Vercel con envs (`ATTESTER_PK` = la key del paso 0, `GITHUB_*`, `NEXT_PUBLIC_FACTORY_ADDRESS` = tu FACTORY) — checklist completo en `docs/DEPLOY-WEB.md`.
2. GitHub OAuth app (callback `https://<dominio>/api/attest/github/callback`). X/Twitter no necesita app: usa el `XGeneralVerifier` de Flap, ya vivo en Robinhood.
3. La gente crea tokens en `/create` y reclama en `/claim/<escrow>` sin que vos firmes nada.

**Nota de confianza:** la factory queda atada a ESA address de attester (inmutable). Usá la misma del paso 0 para el server real, así los tokens del test y los de producción comparten oráculo. Si perdés/rotás la key del attester, redesplegás factory.
