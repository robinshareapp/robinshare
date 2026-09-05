# RobinShare sobre pons v2 — diseño del port

- **Fecha**: 2026-08-29
- **Estado**: aprobado por Jose como base para el plan de implementación
- **Reemplaza el rail de**: Flap (`VaultPortal` / `VaultBaseV2`) → **pons v2** en Robinhood Chain
- **Versión Flap preservada**: rama `flap-rail` (`c512884`) + tag `audited-v3` (`5574646`)
- **Cadena**: Robinhood Chain, chainId **4663** (`0x1237`), L2 Arbitrum Orbit

---

## 1. Contexto y por qué se porta

RobinShare es un *social fee escrow*: se lanza un token cuyas fees de trading se acumulan en un
contrato inmutable **a nombre de una persona** identificada por GitHub, X o wallet, sin que esa
persona tenga wallet de antemano. Después cobra probando quién es.

El producto está **construido y auditado** sobre Flap (aprobación de GT/David Zhang sobre el árbol
`audited-v3`), pero **nunca se lanzó**: lleva 6 semanas trabado esperando el badge de Flap.

**La razón del port es destrabar el launch, no la economía.** Esto se dice explícitamente porque una
versión anterior de este diseño afirmaba una mejora económica de 6–15× que la revisión refutó:

- En Flap, RobinShare ya lanzaba con `buyTaxRate = sellTaxRate` hasta **10%** y `mktBps = 10000`
  (100% del tax al escrow). Mismo techo, misma proporción al vault.
- El delta real del port es **+0,70 pp del fee base** (~+7% relativo en el tope).
- Muestra de 120 launches de pons medidos de punta a punta: volumen de vida **mediano 0,107 ETH**,
  cobrado por el creator **0,00167 ETH**. 29 de 120 nunca tuvieron un trade.
- pons v2 lleva **103.178 launches** y **1.023 graduaron (0,99%)**.

Lo que pons sí da y Flap no: **no hay puertas** (sin audit-gate del launchpad, sin badge, sin
Guardian en el camino crítico), launch permissionless por ~0,0005 ETH.

## 2. Alcance

> **ACTUALIZADO 2026-08-29 tras el review adversarial**: el limite "solo ETH nativo" pasa de ser una
> decision de alcance a estar **impuesto por el contrato**. `attachToken()` rechaza cualquier launch
> con `pairToken != address(0)` o `buybackEnabled == true`. Motivo medido: **el 50,5% de los launches
> reales de pons cotiza contra un ERC-20**, y en esos el vault entregaria **CERO** (las fees se
> acreditan en el ledger por-token del escrow, `pendingAmount()` da 0 y `withdraw()` revierte); con
> `recoveryDays > 0` la plata quedaba **encerrada para siempre**. Es mejor rechazar el **link** que
> atrapar fondos. **Precision agregada 2026-08-30**: `attachToken()` corre DESPUES de que
> `launchToken` ya se ejecuto y el fee ya se gasto, asi que no puede rechazar el launch — rechaza
> atarse a el. El efecto es que ese launch queda huerfano, no que la plata quede encerrada. **Consecuencia de producto: RobinShare sirve para la mitad ETH-pareada de pons.**

**Dentro**: contratos (vault + factory), backend del attester, y los cambios de la web necesarios
para lanzar y cobrar sobre pons.

**Fuera** (decisiones explícitas, no omisiones):
- Pagar en activos que no sean ETH nativo (pons permite parear contra acciones tokenizadas; se
  descartó). Hacerlo después implica reescribir el vault, no agregar un `if`.
- Contrato orquestador de 1 transacción (ver §4).
- Migrar los vaults de Flap ya existentes: no hay ninguno en producción.

## 3. Roles y terminología

El contrato de Flap llama `creator` al que lanza. En un producto que se trata de pagarle a
*creators*, eso es una trampa: durante el diseño llevó a proponer un clawback obligatorio hacia el
lanzador, que es exactamente el ataque que el producto existe para impedir. Se renombra:

| Rol | Nombre | Qué puede hacer |
|---|---|---|
| Quien lanza la moneda y paga el launch fee | **`launcher`** | Elegir identidad destino, `recoveryDays` y el creator tax. Con recovery habilitado, `recoverUnclaimed` **antes** de un bind |
| El dev al que van las fees | **`beneficiary`** | Probar identidad (`claimAndBind` / `claimByProof`), `rebindWallet`, retirar |
| La wallet probada | `boundWallet` | Recibir el payout |

## 4. Orden de operaciones e integración con pons

La circularidad es **dura y no salvable con CREATE2**: en `PonsV2LaunchDeployer`, la creation code de
la curva incluye `params.creatorFeeRecipient`, y la del token incluye la curva. La dirección del
token depende de la del vault, así que **el vault va primero**.

Esto es gratis porque **`taxToken` no se lee en ninguna parte del vault** (verificado por grep sobre
`SocialFeeEscrow.sol`): se elimina.

```
1. factory.createVault(identityType, identityValue, identityWallet, recoveryDays) -> vault
2. pons.launchToken(params, 0, pairToken)  con:
      params.creatorFeeRecipient = vault
      params.buybackEnabled      = false
      params.creatorTaxBps       <= 1000
   msg.value = launchFee() = 0.0005 ETH exactos
```

**Dos transacciones, sin orquestador.** Un vault huérfano (si el paso 2 falla) es inofensivo: nunca
recibe fees. Un orquestador ahorraría una firma y daría atomicidad, pero agrega superficie auditada
y entra en conflicto con el chequeo anti-squat de §7. Queda como mejora de UX posterior.

**Link vault↔token auto-verificable**: `attachToken(address token)`, permissionless, que solo acepta
si `pons.getLaunchedToken(token).creatorFeeRecipient == address(this)`. Nadie tiene que confiar en
nadie, y no es un parámetro del constructor.

`buybackEnabled = false` es obligatorio: con buyback activo, `buybackBurnBps = 5000` se lleva la
mitad del bucket del creador y **la vestea 5 años**.

## 5. El camino del dinero

Es el cambio estructural del port. En Flap el dinero llegaba por **push nativo** y
`address(this).balance` *era* la contabilidad. En pons se **acredita en un ledger externo** bajo la
clave del vault, y solo sale con un `claim()` que es estrictamente `msg.sender`.

```
trades → curva / hook acumulan → [sweepCurve] → FeeEscrow acredita al vault → [pull] → vault → beneficiary
```

### 5.1 `sweepCurve()` — permissionless, **no opcional**

Passthrough a `sweepFees(0)` de la curva del token (selector `0x3729bb9a`). Autorizado para el
`creatorFeeRecipient`, que somos nosotros — el *deployer* **no** está autorizado (revierte
`NotFeeSweepOperator()`, `0x8d42130c`).

Es obligatorio porque **el operador de pons no barre a tiempo en fase de curva**, que es donde vive
el 99% de los tokens: medido, en una ventana de 404 s tradearon 118 curvas y solo se barrieron 15; 5
de 7 curvas activas muestreadas acumulaban **0,857 ETH fuera del escrow** en un solo instante.

Post-graduación existe `sweepPoolFees(bytes32,uint256,uint256)` en el hook (`0x3d61055e`), pero
revierte con `InternalSwapRequiresOperator()` (`0x31cdb504`) siempre que haya fees denominadas en el
memecoin — que es el régimen normal (55% de los cobros medidos).

> ⚠️ **DIVERGENCIA, marcada 2026-08-30.** Este diseño decía que el vault "lo intenta dentro de un
> `try/catch`". **No se construyó**: `_sweepCurve()` sólo llama `sweepFees(0)` de la curva, y
> `MEME_HOOK` no se referencia desde ningún lado. Se deja así a propósito — la llamada necesita el
> `poolId` (`bytes32`) del pool graduado, que el vault no tiene y habría que derivar de la `PoolKey`,
> y agregar una llamada que no se puede probar contra un pool real es peor que no tenerla.
>
> Lo que **sí** se hizo es medir el caso contra la cadena
> (`ForkPons.t.sol::test_fork_postGraduation_...`, cruzando el umbral real de 4,2 ETH), y ahí
> apareció algo que el diseño no sabía: **la graduación barre y acredita al vault en el camino**
> (0,5049 ETH en el test), dentro del mismo `buy()` que cruza el umbral — no hay que dispararla. Así
> que no se pierde nada en el borde. Después de graduar, `sweepCurve()` queda en no-op permanente y
> dependemos del `feeSweepOperator` de pons para las fees del pool. Sólo el 0,99% de los launches
> gradúa, y es pérdida de **liveness**, no de fondos.

### 5.2 `pull()` — permissionless

Llama `IV2FeeEscrow(0xd3AF...).claim()`. El ETH vuelve por `.call` con **todo el gas** (sin stipend),
así que entra por el `receive()`. Es obligatorio: el `claim()` de pons es `msg.sender`-only, sin
`claimFor` ni `claimOnBehalf`, así que **nadie más en el mundo puede sacar ese ETH**.

### 5.3 Composición y guardas

`sweepCurve()` y `pull()` se ejecutan **dentro** de `claimAndBind`, `claimByProof` y el retiro. Sin
eso, alguien prueba su identidad y cobra cero mientras su plata está afuera.

Ambos deben ser **no-revert por saldo cero**: `claim()` revierte `NoBalance()` (`0xc2caa2a6`) si no
hay saldo, lo que convertiría un no-op en un griefing barato y repetible contra las rutas de claim.
Se envuelven con guarda de balance previo (o `try/catch`).

`receive()` debe seguir siendo **infalible y barato**: nunca revierte por lógica propia.

Coste medido del ciclo completo: **~270k gas ≈ 0,0000386 ETH**. Irrelevante — el debate correcto es
autorización y liveness, no coste.

### 5.4 Payout: **pull, no push**

`sweep()` (que empujaba ETH al `boundWallet` con `.call` y revertía si fallaba) se reemplaza por
**`withdraw()`**, callable **sólo por `boundWallet`**, que hace `sweepCurve()` + `pull()` y le
transfiere el total al caller. El vault deja de decidir cuándo y cómo se entrega.

Esto elimina el único escenario en que los fondos quedaban realmente trabados (un `boundWallet` que
no puede recibir ETH en una llamada push) **sin introducir ninguna llave de emergencia**: si la
wallet no puede recibir, simplemente no llama, y la identidad puede rotarla con `rebindWallet`.

### 5.5 ERC-20 que llegan sin aviso

`rescuePoolFees` del hook (onlyOwner de pons) **no pasa por el escrow**: hace `safeTransfer` ERC-20
directo al `creatorFeeRecipient`. Además 11 de las 18 curvas más activas cotizan contra ERC-20.

El vault expone un retiro de ERC-20 arbitrarios **gateado a `boundWallet`** (mismo destino que el
ETH, nunca un destino libre). Debe tolerar tokens no estándar (retorno vacío, fee-on-transfer) y no
puede quedar bloqueado por un token envenenado: retiro **por token**, no un barrido de lista.

## 6. Recovery: irrevocable por default

`recoveryDays = 0` significa **nunca** (`recoveryAfter = 0` → `recoverUnclaimed` revierte). **Es el
default y el modo promocionado.**

Se rechazó explícitamente hacer el recovery obligatorio: le daría al `launcher` un clawback
garantizado, permitiendo lanzar "para" un dev conocido, farmear fees y quedarse con todo cuando la
persona no aparece a tiempo. Es el ataque que el producto existe para impedir.

Con recovery habilitado se mantiene: piso de 30 días, tope 3650, solo el `launcher`, solo **antes**
de un bind, y a una dirección que él elige.

La UI muestra el badge **`irrevocable`** o **`revocable en N días`** leído **on-chain**, no de una
promesa.

## 7. Identidad y claims

Las tres rutas sobreviven. El núcleo se porta intacto: `identityHash`, `_normalize`, `_parseType`,
EIP-712 (`BIND_TYPEHASH`, `bindDigest`, dominio por-vault), `bindNonce`, `rebindWallet`, y el replay
guard **global** `lastTweetId`.

**Dos cambios:**

1. **La ruta X pasa a ser relayable.** Hoy `claimByProof` exige `msg.sender == payout wallet`, así
   que **un dev sin wallet no puede cobrar** — justo en la ruta más viral, y contra la promesa
   central de la marca. Pasa a aceptar firma del beneficiary, como ya hace `claimAndBind`, para que
   un tercero pueda pagar el gas del primer claim. El replay guard global se mantiene sin cambios.
2. **Anti-squat**: `createVault` no impide que alguien cree vaults para identidades ajenas — es
   deseable, *ese es el producto*. Lo que sí se registra es `isVault[address]`, usado por el attester
   (§8).

   > 🔄 **CORREGIDO 2026-08-30 — el chequeo `deployer == launcher` SÍ se implementa.** Este párrafo
   > decía que no, y el motivo que daba era correcto sobre **otro** ataque: squatear una *identidad*,
   > que efectivamente no se puede impedir y además es el producto. Pero había un segundo squat, el
   > del **link**, y contra ese el chequeo funciona exacto. Reproducido con PoC: la dirección del
   > vault es pública desde `VaultCreated`, el flujo de `/create` son tres transacciones, y por
   > 0,0005 ETH un extraño lanzaba su propia moneda apuntándole las fees al vault de la víctima y la
   > ataba antes de la tercera. Como el link es de una sola vez, el vault quedaba pegado **para
   > siempre** a la curva del atacante: la moneda real ya no se podía atar, `sweepCurve()` barría la
   > equivocada, y el beneficiario probaba su identidad para cobrar cero.
   >
   > El costo declarado (cerrarle la puerta al orquestador de 1 tx) es una mejora de UX que el propio
   > §4 deja para después; el squat era explotable hoy. Que `deployer` sea quien lanzó está probado
   > contra la cadena en `ForkPons.t.sol::test_fork_fullCycle_nativePair`.

## 8. Attester (backend) — arreglo de seguridad

> **RESUELTO 2026-08-29** — plan `docs/superpowers/plans/2026-08-29-attester-blind-signature-fix.md`,
> aplicado en `main` (merge `3b3dc9b`) y en `flap-rail` (`5d5a810`). El server ya no le pide el
> digest al contrato (`web/lib/bind.ts`) y valida procedencia contra la factory
> (`assertVaultFromFactory`). Suite: 15 → **26 tests**, `tsc` y `next build` limpios en ambas ramas.

**Bug existente en el código auditado**, independiente del port: el attester expone
`/api/attest/github/start?vault=<address>`, toma esa dirección, le pide `bindDigest(...)`,
`identityType()` e `identityValue()`, valida el OAuth de GitHub, y **firma el digest que ese contrato
le devolvió** — sin validar que la dirección sea un vault nuestro.

Ataque: el atacante despliega un contrato que devuelve `identityType() = 1`,
`identityValue() = <su propio login>` y un `bindDigest` que **reenvía al vault víctima**; hace OAuth
con su cuenta real; obtiene una firma válida contra **cualquier** vault de GitHub. Como
`sign({hash})` es una firma cruda sobre 32 bytes, la autenticación funciona y el server firma algo
que no leyó.

Hoy no es explotable sólo porque la web está en 503 con `ATTESTER_PK` sin setear.

**Fix, las dos capas:**

1. **El server calcula el digest, no lo pide.** Lo construye con nuestro typehash y el dominio
   EIP-712 scopeado a la dirección recibida; del contrato sólo lee `bindNonce`. Si el atacante apunta
   a su propio contrato, el digest queda scopeado a *su* contrato y la firma no sirve contra la
   víctima. Mata el ataque por construcción.
2. **Procedencia**: `factory.isVault(addr)`; el server rechaza cualquier dirección fuera del registro.

**Se aplica también a `flap-rail`**, no sólo a la línea pons.

## 9. Web

- `/create`: reemplaza el minado de salt vanity `0x7777` y la llamada al `VaultPortal` de Flap por el
  flujo de §4 (crear vault → `launchToken`). Campos nuevos: `creatorTaxBps`, `pairToken`, `salt`,
  exenciones de snipe tax. `buybackEnabled` fijo en `false`.
- `/claim/[vault]` y `/v`: cambian por el ABI del vault, no por el launchpad.
- `/api/attest/*`: el fix de §8.
- `/api/x-prove`: sin cambios (el prover de Flap es agnóstico del rail, ver §11).
- Imagen del token: pons tiene `logo` en `TokenParams`; se mantiene el pinning propio.
- Env: `NEXT_PUBLIC_FACTORY_ADDRESS`, `ATTESTER_PK`, GitHub OAuth, `stateSecret`, `appBaseUrl` —
  hoy **todos MISSING** (`/api/health` = 503). La producción no existe todavía.

## 10. Lo que se elimina

`VaultBaseV2` · `VaultFactoryBaseV2` · `onlyGuardian` · `emergencyWithdrawNative` ·
`setRescueForward` / `rescueForward` / `rescueTo` · `vaultUISchema()` · `description()` ·
`newVault()` (entrypoint del VaultPortal) · `tokenCreationPolicies()` · `_validateBeforeLaunch()` ·
`isQuoteTokenSupported()` · `factorySpecVersion()` · `taxToken`.

Estimado: **~487 → ~250 líneas** en el vault. Achicar el contrato es lo que hace pagable la
auditoría (§13).

## 11. Invariantes de seguridad

**Se conservan** (5 de los 6 findings del audit v3 y los del preaudit): el replay guard global de X,
el piso de 30 días de recovery, el attester rotable como fuente viva, el gate de `rebindWallet` a la
wallet-identidad original, y que `recoverUnclaimed` sea imposible después de un bind.

**Cambian de mecanismo**: los 4 hallazgos que el audit cerró apoyándose en el **Guardian de Flap** ya
no aplican. Se cierran de otra forma, sin llaves:

| Escenario | Antes | Ahora |
|---|---|---|
| `boundWallet` no puede recibir | `emergencyWithdrawNative` (Guardian) | **Payout pull** (§5.4) |
| Attester perdido | co-gate del Guardian en `rotateAttester` | Rotación por el attester vigente, **o** por `attesterAdmin` si se fijó uno. Con `attesterAdmin = 0x0` **no hay sucesor** y una llave perdida congela los vaults de GitHub para siempre — es una decisión abierta, PENDIENTES §3. *(Corregido 2026-08-30: esta celda decía "otras dos rutas" y hay una sola.)* |
| Tax en vuelo durante un incidente | `setRescueForward` | No aplica: en pons el dinero se acredita, no se empuja |
| Beneficiary que nunca aparece | Rescate del Guardian | **No es un defecto**: con `recoveryDays = 0` la plata espera indefinidamente. Esperar a su dueño **es el producto** |

**Invariante duro que el diseño debe defender**: no existe ningún camino por el que el ETH salga del
vault a una dirección que no sea `boundWallet` o el destino de `recoverUnclaimed` fijado por el
`launcher`. Lo mismo aplica al retiro de ERC-20 (§5.5).

> **Reformulado 2026-08-30 tras el review.** Enunciado así, el invariante se cumple en el código —
> pero es más débil de lo que parece, porque no dice nada sobre **quién puede convertirse en
> `boundWallet`**, que es lo que en realidad importa. La versión honesta, y la que hay que auditar:
>
> - vaults de **wallet**: sólo la identidad original, vía `rebindWallet`. Cerrado.
> - vaults de **X**: sólo quien produzca una prueba del oráculo con el substring exacto, que ata la
>   wallet y el vault. Cerrado *si el oráculo se comporta* (§12.3) — **con una salvedad medida
>   2026-08-30**: el binding es por **handle**, no por `xId`. `claimByProof` lee `proof.xId` y lo
>   descarta, así que si el handle se libera y otra persona lo registra, el nuevo dueño puede
>   probarlo y cobrar el vault del anterior. No hay arreglo limpio (el vault no conoce el `xId`
>   correcto al crearse, porque el launcher tipea un handle); un pin al primer claim cerraría la
>   mitad del re-bind. Queda para el auditor y para PENDIENTES §4.
> - vaults de **GitHub**: quien tenga la llave del **attester**, que es nuestra. En esa ruta la firma
>   ES la prueba de identidad, así que la llave puede bindear cualquier vault de GitHub a cualquier
>   wallet — probado en `ReviewRound2.t.sol::test_attesterAdmin_SI_alcanzaLosFondosDeUnVaultGithub`.
>   Es **inherente** a atestiguar un OAuth on-chain, no un bug; lo que era un bug es haberlo negado
>   en los comentarios del contrato y en el copy. Ahora está escrito, acotado y divulgado.

## 12. Riesgos aceptados

1. **pons puede redirigir las fees de cualquier token.** `setCreatorFeeRecipient` del factory,
   `onlyOwner` (Safe 2-de-3 `0x263ed295…19dd`), timelock de 3 días + ventana de ejecución de 3 días,
   y `renounceOwnership()` **permanentemente deshabilitado**. **Es retroactivo** sobre todo lo no
   barrido, y el mismo Safe rota el `feeSweepOperator` **sin timelock**. No es teórico: 4 propuestas
   históricas, 1 ejecutada (2026-08-24 → 2026-08-27) y 1 viva al 2026-08-31 revirtiendo el
   `transferCreatorFeeRecipient` de un creador.
   → **Mitigación**: `sweepCurve()` agresivo achica la ventana expuesta. **El copy dice la verdad**:
   *el launcher no puede desviarlas nunca; pons puede, con 3 días de aviso público y auditable.*
2. **La economía sí es inmutable**: se congela por lanzamiento (`_launchFeePolicies[token]`; la
   graduación registra el pool con ese snapshot). Es el claim de marca fuerte y honesto: *en pons lo
   económico es inmutable; lo único mutable es el destinatario.*
3. **La ruta X depende de infra de un competidor**: el prover `verifyx.taxed.fun` es un servicio HTTP
   de Flap sin auth ni SLA, y el `XGeneralVerifier` (`0xccDaB0d5…9c17`) es un proxy upgradeable
   controlado por un Safe 2-de-5 con implementación **no verificada**. Se midió en vivo y **es
   agnóstico del rail** (firma substrings arbitrarios, sin registro de vaults), pero no hay plan B.
4. **"0 admin keys" sigue siendo cierto para nuestro contrato**, y falso para el rail. El copy debe
   distinguirlo.

   > **Ampliado 2026-08-30**: falso también para el **producto** en la ruta GitHub, por el attester
   > (ver §11). El copy ahora lo dice, y vive en una constante única (`web/lib/claims.ts`) que las
   > nueve direcciones y el shell importan, con `web/test/copy.test.ts` exigiéndolo. La versión
   > anterior del gate tenía el agujero justo ahí: buscaba `no custody` y cuatro páginas decían
   > `non-custodial`.

## 13. Auditoría

El audit de Flap **no se porta**: la aprobación es sobre el árbol `audited-v3` y el propio
`AUDIT-NOTES` dice *"deployed bytecode must build from here"*. Este es un contrato nuevo que custodia
ETH de terceros.

**Decisión abierta, con dueño: Jose.** Auditor y presupuesto sin definir. El diseño reduce el vault a
~250 líneas justamente para que sea una auditoría chica.

## 14. Testing

- **Se conservan**: identidad, normalización, EIP-712, bind/rebind, replay guards, recovery.
- **Se descartan**: todo lo que testea el acoplamiento a Flap (gate del VaultPortal, schemas, policies).
- **Nuevos, obligatorios**:
  - `pull()` contra el `V2FeeEscrow` real en fork, incluido el caso `NoBalance()`.
  - `sweepCurve()` en fork, y el caso post-graduación que revierte `InternalSwapRequiresOperator()`.
  - `receive()` infalible bajo `.call` sin stipend.
  - Llegada de ERC-20 arbitrarios, incluido un token malicioso (revert / retorno no estándar).
  - Payout pull con un `boundWallet` que es un contrato sin `receive()`.
  - **Ruta X contra el verifier real** — hoy **no existe un solo test** que no use un mock con un
    bool seteable, y `Fork.t.sol` no la toca.
  - E2E en fork: `createVault` → `launchToken` → trades → `sweepCurve` → `pull` → `claimAndBind` →
    retiro.

## 15. Decisiones abiertas

| # | Decisión | Dueño |
|---|---|---|
| 1 | Auditor y presupuesto (§13) | Jose |
| 2 | Custodia y sucesión de la llave del attester (hoy no existe) | Jose |
| 3 | Si se conserva la ruta X pese a depender de infra de Flap, o se construye un attester propio para X | Jose |
| 4 | Disclosure del conflicto de interés (Jose es parte del equipo de PonsVault, competidor en la misma cadena) | Jose |

## 16. Referencias on-chain verificadas

| Qué | Dirección / selector |
|---|---|
| pons v2 factory | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` |
| V2FeeEscrow (verificado, no proxy) | `0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e` |
| V2MemeHook | `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` |
| Launch locker · router · deployer | `0x267444D0…4952` · `0xe33E9E47…2948` · `0x3711ceA4…1A42` |
| feeSweepOperator (EOA) | `0x49bbf2b70955fb3a106e084d4bfda92d334573d2` |
| owner de factory y hook (Safe 2-de-3) | `0x263ed295dafae1d9aadd6e56c4b6f9f38ee019dd` |
| XGeneralVerifier (Flap) | `0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17` |
| `launchToken(TokenParams,uint256,address)` | `0xf35abbcf` (con exenciones: `0xa72101af`) |
| `sweepFees(uint256)` — curva | `0x3729bb9a` |
| `sweepPoolFees(bytes32,uint256,uint256)` — hook | `0x3d61055e` |
| `getLaunchedToken(address)` | `0x3cf28b5a` |
| `NotFeeSweepOperator()` · `InternalSwapRequiresOperator()` | `0x8d42130c` · `0x31cdb504` |
| `NoBalance()` · `TransferFailed()` | `0xc2caa2a6` · `0x90b8ec18` |
| Config viva | `launchFee` 0,0005 ETH · `launchConfigId` **0** único · `maxCreatorTaxBps` 1000 · `curveFeeBps` 100 · graduación 4,2 ETH · supply 1e27 |
