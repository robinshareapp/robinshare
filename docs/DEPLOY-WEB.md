# DEPLOY del attester + dApp a Vercel (flujo github/X automático)

Con esto, la gente crea tokens en `/create` y reclama en `/claim/<escrow>` **sin que vos firmes a mano** (el `attest-manual.mjs` deja de hacer falta). El server verifica GitHub/X solo y firma el voucher.

## Prerrequisito

**Factory ya desplegada** en 4663 (ver `docs/RUNBOOK-launch.md` paso 1) — necesitás su address (`FACTORY`) y la address de la wallet **attester** canónica que le pasaste al deploy (`ATTESTER_ADDRESS`). Guardá también la **PK** de esa wallet attester: va al env de Vercel. Si PK y address no corresponden a la misma wallet, todos los claims github/X revierten — `GET /api/health` lo detecta (`attesterMatches: false`).

## Checklist de deploy (en orden)

- [ ] **1. `vercel login`** (Jose, cuenta `0xkeezy-3892`) — interactivo, no lo puede hacer el agente.
- [ ] **2. `vercel link`** desde `web/` — crea/asocia el proyecto. Root Directory = `web/`.
- [ ] **3. Setear las env vars** (Project → Settings → Environment Variables, ambiente Production). Lista exacta abajo.
- [ ] **4. Deploy**: `npx vercel --prod`.
- [ ] **5. Smoke test** (obligatorio, ver sección abajo).

### 1. `vercel login`

```bash
cd C:\Users\PC\Flap\web
npx vercel login
```

### 2. `vercel link`

```bash
npx vercel link
# Root Directory: web/  (si pregunta "In which directory is your code located?", contestá "./")
```

(Alternativa: subir `web/` como proyecto nuevo desde el dashboard de Vercel, cuenta `0xkeezy-3892`, Root Directory `web`.)

### 3. Env vars — lista exacta

Copiá de `web/.env.example`. Todas van al ambiente **Production** (y Preview si querés probar antes):

| Var | Tipo | Valor / de dónde sale |
|---|---|---|
| `NEXT_PUBLIC_FACTORY_ADDRESS` | pública | El `FACTORY=0x...` que imprimió `forge script script/Deploy.s.sol` (docs/RUNBOOK-launch.md paso 1). |
| `NEXT_PUBLIC_RPC_URL` | pública | `https://rpc.mainnet.chain.robinhood.com` (default si no la seteás — podés omitirla). |
| `NEXT_PUBLIC_DIRECTION` | pública, **opcional** | **No la seteés.** Sin definir cae a `legend` (identidad oficial de RobinShare, ganó el bake-off 2026-07-13). Las direcciones archivadas siguen navegables en `/v/<dir>` sin esta var. |
| `ATTESTER_PK` | **secreta** | PK de la wallet attester dedicada (nueva, sin fondos) generada en `docs/RUNBOOK-launch.md` paso 0. Su ADDRESS **debe ser** la que quedó como `ATTESTER_ADDRESS` (canónico, inmutable) en la factory de arriba. |
| `ATTESTER_STATE_SECRET` | **secreta** | String random largo que firma el `state` del OAuth de GitHub. Generalo con `openssl rand -hex 32`. |
| `GITHUB_CLIENT_ID` | pública* | Client ID de la GitHub OAuth App (ver sección siguiente). |
| `GITHUB_CLIENT_SECRET` | **secreta** | Client Secret de esa misma OAuth App. |
| `APP_BASE_URL` | pública | El dominio real de prod, ej. `https://robinshare.vercel.app` o el dominio propio. Sin `/` final. |

*(`GITHUB_CLIENT_ID` no es sensible por sí solo, pero marcalo igual en Vercel junto a su secret — no necesita prefijo `NEXT_PUBLIC_` porque solo lo lee el server en `/api/attest/github/start`.)*

**Twitter/X no requiere ninguna env.** La ruta X usa el oráculo oficial de Flap (`XGeneralVerifier` en `https://verifyx.taxed.fun/prove?chain_id=4663`), ya desplegado y live en Robinhood Chain — no Reclaim, no app propia, no key.

### Crear la GitHub OAuth App (~2 min)

1. Andá a **github.com/settings/developers** → pestaña **OAuth Apps** → **New OAuth App**.
2. Completá el formulario:
   - **Application name**: `RobinShare` (o `RobinShare (prod)` si vas a tener una segunda para preview/staging).
   - **Homepage URL**: `https://<tu-dominio>` (el mismo que vas a poner en `APP_BASE_URL`).
   - **Application description**: opcional, ej. "Claim de fees por identidad GitHub/X en Robinhood Chain".
   - **Authorization callback URL**: `https://<tu-dominio>/api/attest/github/callback` — **exacto**, incluyendo el path. Este es el único campo que el server valida al hacer el round-trip del OAuth.
3. **Register application**.
4. En la página de la app recién creada: copiá el **Client ID** (visible) y clickeá **Generate a new client secret** → copiá el **Client Secret** (solo se muestra una vez).
5. Pegá ambos en las env vars de Vercel (`GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`).

Si después cambiás de dominio: hay que actualizar el **Authorization callback URL** en esta misma OAuth App Y el `APP_BASE_URL` en Vercel — deben quedar sincronizados o el callback de GitHub falla.

### 4. Deploy

```bash
cd C:\Users\PC\Flap\web
npx vercel --prod
```

### 5. Smoke test (obligatorio post-deploy)

```bash
curl https://<tu-dominio>/api/health
```
Debe devolver `{"ok": true, ...}` con:
- `checks.attesterMatches: true` — si da `false`, el `ATTESTER_PK` de Vercel no corresponde al attester que la factory tiene registrado. Arreglá la key en Vercel; si la que perdiste es la key y no el env, se **rota**: `rotateAttester(nuevo)` — no hay que redesplegar nada.
- `checks.env.githubOAuth: true` — confirma que `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` están seteadas (Twitter no necesita entrada acá, no requiere env).

Después, a mano:
- [ ] `https://<tu-dominio>/` carga (identidad `legend` de RobinShare).
- [ ] `https://<tu-dominio>/create` conecta wallet (MetaMask u otro injected) sin errores de consola.
- [ ] Lanzá un token de prueba a tu GitHub → `https://<tu-dominio>/claim/<escrow>` → **Verify with GitHub** → claim sin firmar a mano.

## Notas

- El `APP_BASE_URL` tiene que ser el dominio real exacto (el redirect del OAuth de GitHub vuelve ahí). Sin `https://` de más ni `/` final.
- El attester del server y el de la factory son lo mismo por diseño: una sola wallet oráculo. Guardá su PK bien.
- **El attester es ROTABLE, no inmutable.** `RobinShareVaultFactory.rotateAttester(address)` lo acepta del attester vigente **o** del `attesterAdmin`. O sea que perder la PK del attester **no** obliga a redesplegar la factory: el `attesterAdmin` (la wallet fría, `PENDIENTES.md` §3) rota a una llave nueva y el servicio sigue. Ésa es exactamente la razón de existir de esa wallet — si `attesterAdmin` fuera `0x0`, ahí sí una PK perdida congelaría el ETH de todos los vaults de GitHub para siempre.
- Lo que **sí** es inmutable es el `attesterAdmin`: se fija en el constructor y no hay setter. Equivocarse ahí obliga a redesplegar y abandonar los vaults ya creados.
- `scripts/attest-manual.mjs` (usa `ATTESTER_PK` + opcionalmente `RPC_URL`, distinto de `NEXT_PUBLIC_RPC_URL`) es el escape hatch manual del piloto — no hace falta configurarlo en Vercel, es un script local para cuando el flujo automático está caído.
