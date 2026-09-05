# ENSAYO — Launch de RobinShare contra anvil fork (2026-07-17)

> Ensayo general del `docs/RUNBOOK-launch.md` contra un fork LOCAL de Robinhood Chain
> (`anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663`). Cero gasto real.
> Foundry: `export PATH="$PATH:/c/Users/PC/.foundry/bin"`. Todo corrido desde `contracts/`.

## 0. Estado del repo (verificación previa)

```bash
git -C C:/Users/PC/Flap describe --tags   # -> audited-v3-3-g331a443
git -C C:/Users/PC/Flap status            # -> clean
```

`main` (331a443) está **3 commits por delante** del tag `audited-v3` (5574646), no exactamente
en el tag. Diff de esos 3 commits:

```bash
git diff --stat audited-v3..HEAD -- contracts/src contracts/script   # -> vacío
git diff --stat audited-v3..HEAD                                     # -> solo contracts/AUDIT-NOTES.md (+16 líneas)
```

Los 3 commits son: un fix del audit v4 (`4e42002`), su **revert** (`11f77fb`), y un commit de
docs (`331a443`) que solo toca `AUDIT-NOTES.md`. Neto: **`contracts/src/` y `contracts/script/`
son byte-idénticos a `audited-v3`.** Es seguro tratar el árbol actual de `main` como
`audited-v3` para este ensayo — no se tocó ningún contrato.

## 1. Fork

```bash
export PATH="$PATH:/c/Users/PC/.foundry/bin"
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 > anvil.log 2>&1 &
cast chain-id --rpc-url http://localhost:8545   # -> 4663 CONFIRMADO
```

Fork block: `11935664`. Cuentas/keys: las 10 default del mnemonic `test test test ... test junk`
(cada una con 10000 ETH sintéticos que anvil inyecta al iniciar, independientemente del balance
real que tengan en el chain forkeado — ver discrepancia #3, es importante).

- Cuenta #0 `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` — usada como **DEPLOYER**.
- Cuenta #1 `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` — usada como **ATTESTER**.

## Paso 1 del runbook — Deploy de la factory

```bash
cd contracts
export DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ATTESTER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ATTESTER_ADDRESS=$ATTESTER_ADDRESS \
  forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --private-key $DEPLOYER_PK
```

**Resultado: VERDE.**

```
SocialFeeEscrowFactory: 0x67d269191c92Caf3cD7723F116c85e6E9bf55933
VaultPortal: 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B
Canonical attester: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

`VaultPortal` logueado == `RobinhoodAddresses.VAULT_PORTAL` (hardcodeado, no constructor param) — correcto.

### verify-contract (dry, sin mandar a blockscout)

```bash
# constructor-args CORRECTOS (constructor real: SocialFeeEscrowFactory(address attester_), 1 arg)
cast abi-encode "constructor(address)" $ATTESTER_ADDRESS
# -> 0x00000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c8   (32 bytes)

# lo que el runbook pide hoy (2 args, INCORRECTO)
cast abi-encode "constructor(address,address)" 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B $ATTESTER_ADDRESS
# -> 64 bytes
```

Prueba dura: inspeccioné el calldata real de la tx de deploy
(`contracts/broadcast/Deploy.s.sol/4663/run-latest.json`, campo `transactions[0].transaction.input`).
Los **últimos 32 bytes exactos** del input son el attester zero-padded — no hay lugar para un
segundo argumento de 32 bytes. Confirma que el constructor real toma UN solo `address`.

**Comando corregido para el runbook:**

```bash
forge verify-contract $FACTORY src/SocialFeeEscrowFactory.sol:SocialFeeEscrowFactory \
  --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args $(cast abi-encode "constructor(address)" $ATTESTER_ADDRESS)
```

## Paso 2 del runbook — vaultData

```bash
VAULT_DATA=$(cast abi-encode "f(string,string,address,uint256)" \
  "github" "0x-keezy" "0x0000000000000000000000000000000000000000" 0)
```

Corre tal cual, sin cambios. `recoveryDays=0`: confirmado válido — `SocialFeeEscrowFactory.sol:87`
tiene `require(recoveryDays == 0 || recoveryDays >= 30, ...)`, y el escrow ya deployado
(ver Paso 5) devuelve `recoveryAfter() == 0`. El piso de 30 días del Audit v3 finding 3 solo
aplica cuando `recoveryDays != 0`; `0` ("nunca") sigue siendo válido tal como asume el runbook.

## Paso 3 del runbook — Salt local

```bash
node scripts/mine-salt.mjs 7777
```

```json
{"salt":"0x0000000000000000000000000000000000000000000000000000000000002d76","token":"0x4Ddc650a977Cd39F03A890aFd6985e76e8de7777","iterations":11638}
```

SALT y TOKEN_PREDICHO minados en <1s, sin RPC. Corre tal cual.

## Paso 4 del runbook — Launch (Opción B, CLI)

Comando EXACTO del runbook (solo sustituyendo `$SALT`/`$FACTORY`/`$VAULT_DATA`/`--private-key`/`--rpc-url`),
incluyendo el `{}` literal de metadata y todas las comas internas de la tupla:

```bash
export FACTORY=0x67d269191c92Caf3cD7723F116c85e6E9bf55933
export SALT=0x0000000000000000000000000000000000000000000000000000000000002d76
export VAULT_DATA=$(cast abi-encode "f(string,string,address,uint256)" "github" "0x-keezy" "0x0000000000000000000000000000000000000000" 0)

cast send 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B \
  "newTokenV6WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8,address,bytes))" \
  "(Fledge Pilot,FLEDGE,{},1,$SALT,1,0x0000000000000000000000000000000000000000,10000000000000000,0x,0x0000000000000000000000000000000000000000000000000000000000000000,0x,0,0,300,300,3153600000,259200,10000,0,0,0,0,0x0000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000,6,$FACTORY,$VAULT_DATA)" \
  --value 0.01ether --rpc-url http://localhost:8545 --private-key $DEPLOYER_PK
```

**Resultado: VERDE.** `status 1 (success)`, tx `0xe07395f48c7711c8b8bd49193c7d7d6be868858ea10ed6204eeb969b8dbd11a5`.

- Token creado: **`0x4Ddc650a977Cd39F03A890aFd6985e76e8de7777`** — coincide EXACTO con `TOKEN_PREDICHO` del paso 3.
- `VaultCreated` emitido por la factory con `identityHash = 0xe9301c3d61204eed55d73b6af0ff5be116f24588f4eb69c7b21a3598e4af99fa` y `vault = 0xfBD745797A0fb50429f0a2b04581092798Fdf30B`.
- Verifiqué de paso que los índices de enum usados en la tupla (dexThresh=1 FOUR_FIFTHS, migratorType=1 V2_MIGRATOR, dexId=0 DEX0, lpFeeProfile=0 STANDARD, tokenVersion=6 TOKEN_TAXED_V3) matchean exactamente los enums reales en `src/flap/IPortal.sol` — sin desvíos.

**Nota sobre el quoting de `{}`:** la preocupación del brief no se materializó. El comando
corre tal cual en Git Bash — las comillas dobles alrededor de toda la tupla evitan que bash
interprete `{}` o las comas internas (brace expansion de bash solo dispara sin comillas y solo
con contenido tipo `{a,b}`; `{}` vacío entre comillas es texto literal). **No hace falta ningún
escaping adicional; el runbook ya está bien en este punto.**

## Paso 5 del runbook — Verificación post-launch

```bash
IDH=$(cast call $FACTORY "identityHashFor(string,string,address)(bytes32)" "github" "0x-keezy" 0x0000000000000000000000000000000000000000 --rpc-url http://localhost:8545)
ESCROW=$(cast call $FACTORY "getVaults(bytes32)(address[])" $IDH --rpc-url http://localhost:8545)
```

`IDH = 0xe9301c3d61204eed55d73b6af0ff5be116f24588f4eb69c7b21a3598e4af99fa` (matchea el topic del evento).
`ESCROW = 0xfBD745797A0fb50429f0a2b04581092798Fdf30B`.

| Check del runbook | Comando | Resultado |
|---|---|---|
| token == TOKEN_PREDICHO | — | ✅ exacto |
| `taxToken()` == token lanzado | `cast call $ESCROW "taxToken()(address)"` | ✅ `0x4Ddc650a977Cd39F03A890aFd6985e76e8de7777` |
| `attester()` == canónico | `cast call $ESCROW "attester()(address)"` | ✅ `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| `description()` legible | `cast call $ESCROW "description()(string)"` | ✅ `"FLEDGE fee escrow for github:0x-keezy: 0.000 ETH pending, 0.000 ETH paid out. Status: waiting for its person. / ..."` (bilingüe) |
| comprar pizca → balance sube | vía flap.sh | ⚠️ NO probado (no hay UI/trading real en este ensayo); sustituido por transferencia directa de ETH al escrow — ver Extra abajo. El `TaxProcessor` real de Flap no se ejercitó. |

Extra verificado (no pedido explícitamente por el runbook pero útil): `recoveryAfter() == 0`,
`identityType() == 1` (TYPE_GITHUB), `identityValue() == "0x-keezy"` (sin normalizar de más — el
prefijo "0x" del handle NO se confunde con una dirección), `creator() == DEPLOYER`.

## Extra — Fee flow + claim real (valida runbook §6 sin web)

1. **Simulación de tax:** `cast send $ESCROW --value 0.05ether --private-key <cuenta#4>` → balance del escrow sube a 0.05 ETH. Confirma que `receive()` acumula sin revertir.

2. **Primer intento de claim — PAYOUT = cuenta default de anvil (#5, `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc`):**
   ```bash
   DIGEST=$(cast call $ESCROW "bindDigest(address,uint256)(bytes32)" $PAYOUT $DEADLINE --rpc-url http://localhost:8545)
   SIG=$(cast wallet sign --no-hash $DIGEST --private-key $ATTESTER_PK)
   cast send $ESCROW "claimAndBind(address,uint256,bytes)" $PAYOUT $DEADLINE $SIG --rpc-url http://localhost:8545 --private-key $CALLER_PK
   ```
   La tx fue exitosa (`status 1`), `boundWallet` quedó seteado a `$PAYOUT`, pero el balance de
   `$PAYOUT` **bajó a 0** en vez de subir 0.05 ETH. Investigado: **ver discrepancia #3 abajo** —
   causa raíz no es un bug del contrato ni del runbook.

3. **Repetido con wallet limpia** (`cast wallet new` → `0x37791C2F22928e1EF6d9fd778F9F7BF2c50a8726`, sin código, nunca tocada en el chain real):
   - Mandé 0.03 ETH más de "tax" al escrow.
   - `bindDigest` + firma del attester + `claimAndBind` llamado desde una tercera cuenta (permissionless, funciona sin ser ni el payout ni el creator).
   - **Resultado: VERDE.** Balance de la wallet fresca: exactamente `0.03 ETH`. `boundWallet` actualizado (re-bind confirmado, `bindNonce` avanzó a 1 en el evento `Bound`).

4. **`sweep()`:** mandé 0.02 ETH más al escrow, llamé `sweep()` desde una cuenta CUALQUIERA (ni payout, ni creator, ni attester) → exitoso, el payout recibió los 0.02 ETH adicionales (total acumulado: 0.05 ETH), escrow quedó en 0. Confirma que `sweep()` es permissionless tal como documenta el contrato.

## Cleanup

Anvil matado al final del ensayo (`kill` del proceso en background). No se dejaron procesos colgados.

---

## Discrepancias encontradas vs el runbook (numeradas, con corrección propuesta)

1. **[CONFIRMADO] `forge verify-contract` usa la firma de constructor equivocada.**
   El runbook (Paso 1) codifica `--constructor-args` con `"constructor(address,address)"`
   (VaultPortal + attester). El constructor real de `SocialFeeEscrowFactory` es
   `constructor(address attester_)` — **un solo argumento** (`vaultPortal` sale hardcodeado de
   `_getVaultPortal()`, no es parámetro). Verificado por código fuente Y empíricamente: los
   últimos 32 bytes del calldata de la tx de deploy real en el fork son exactamente el attester
   zero-padded, sin espacio para un segundo `address`. Con la firma vieja, la verificación en
   Blockscout fallaría por mismatch de constructor-args/bytecode.
   **Fix:** `cast abi-encode "constructor(address)" $ATTESTER_ADDRESS`.

2. **[CONFIRMADO] La llave #3 del pre-flight (app de Reclaim) ya no aplica — es stale.**
   El código (`SocialFeeEscrowFactory._getXVerifier()`, `SocialFeeEscrow.claimByProof`) usa el
   `XGeneralVerifier` oficial de Flap, hardcodeado por chain-id (`RobinhoodAddresses.X_VERIFIER`
   para 4663), sin ningún env var de Reclaim. Confirmado también en el código de la web:
   `web/.env.example` ("Reclaim quedó reemplazado por este oráculo"), `web/README.md`
   ("Sin env, sin Reclaim") y `web/app/api/x-prove/route.ts` ("Reemplaza a Reclaim en la ruta
   Twitter"). **Fix:** eliminar la llave #3 del §0 del runbook (o marcarla explícitamente como
   histórica/no aplicable).

3. **[NUEVO — gotcha operativo, no bug del runbook] Las 10 cuentas default del mnemonic de anvil
   ("test test test ... junk") ya tienen delegaciones EIP-7702 activas EN Robinhood Chain
   mainnet real**, heredadas al forkear. Confirmado con `cast code` en 7 de las 10 direcciones —
   todas devuelven `0xef0100...` (el magic-byte del EIP-7702 delegation designator), casi todas
   apuntando a `0x043600008d6a1d7811a99bb1299f61825bf5f2d7` (aparenta ser un bot "sweeper" que
   reclamó estas direcciones públicas/conocidas en el chain real). Si se usa una de esas cuentas
   como wallet "payout" de prueba manual (como hice al principio con la cuenta #5), el ETH que le
   llega **desaparece de su balance sin error ni revert** — la tx del claim es exitosa igual
   (`status 1`, evento `Swept` correcto), pero el destinatario ejecuta código ajeno heredado del
   chain real en vez de simplemente acumular saldo. **No es un bug de `SocialFeeEscrow` ni del
   runbook** — `test/Fork.t.sol` ya lo evita usando `makeAddr("keezy-payout")` en vez de cuentas
   default de anvil. **Recomendación para cualquier ensayo/smoke-test manual futuro contra un
   fork de una chain viva:** usar SIEMPRE `cast wallet new` (dirección fresca, sin historial)
   para wallets que deban "recibir y quedarse con" fondos — reservar las cuentas default de
   anvil solo para roles que firman pero no reciben (deployer, attester, caller de gas).

4. **[NO-BUG, concern descartada] El quoting de `{}` (metadata) en el `cast send` del Paso 4 NO
   es un problema en Git Bash.** El comando corre tal cual está escrito en el runbook — las
   comillas dobles que envuelven toda la tupla evitan cualquier interpretación de `{}` o las
   comas internas por parte de bash. No se necesita ningún escaping adicional ni cambio.

5. **[GAP de documentación, no bug] El runbook no menciona `contracts/script/LaunchPilot.s.sol`**,
   un script ya existente en el repo que automatiza deploy-opcional + mining de salt + launch +
   verificación de identityHash/vaults en un solo `forge script --broadcast`, vía envs
   (`IDENTITY_TYPE`, `IDENTITY_VALUE`, `RECOVERY_DAYS`, `DEV_BUY_WEI`, `TOKEN_NAME`,
   `TOKEN_SYMBOL`, `FACTORY`). Podría ser una "Opción C" más simple que la Opción B manual del
   runbook. No lo ejecuté en este ensayo (el foco era validar el runbook TAL COMO ESTÁ escrito),
   pero vale la pena evaluarlo antes de reescribir el documento.

6. **[OBSERVACIÓN, no requiere acción] `main` no está exactamente en el tag `audited-v3`** — está
   3 commits por delante (`git describe --tags` → `audited-v3-3-g331a443`). El diff neto contra
   el tag toca únicamente `contracts/AUDIT-NOTES.md` (un fix de audit v4 se aplicó y luego se
   revirtió íntegro); `contracts/src/` y `contracts/script/` son byte-idénticos a `audited-v3`.
   No bloquea el ensayo ni el deploy real, pero si se quiere una equivalencia estricta con el tag,
   conviene taggear el HEAD actual de `main` (o re-parar sobre `audited-v3` directo) antes del
   deploy en mainnet.
