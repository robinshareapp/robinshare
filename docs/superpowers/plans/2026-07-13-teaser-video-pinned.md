# Video teaser-explainer pinned @RobinShareApp — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Producir el video teaser 16:9 (~25–30s, texto cinético + música, sin voz) del spec `docs/superpowers/specs/2026-07-13-teaser-video-pinned-design.md`, en dos cortes: **B** (bookends 3D Higgsfield) y **A** (cero créditos), para que Jose elija cuál fijar en @RobinShareApp.

**Architecture:** Los assets reales salen de la web en producción (capturas animadas con el rig Playwright que ya vive en `web/scripts/`). La composición se hace con HyperFrames (HTML → MP4): una sola línea de tiempo de 5 beats, con los bookends 3D como variable de composición para derivar el corte A sin duplicar. La música se resuelve con `media-use`. Gate final: juez `juez-entregables`.

**Tech Stack:** HyperFrames (CLI `npx hyperframes`), Playwright (channel chrome, solo resuelve con cwd=`web/`), Higgsfield MCP (`generate_image`, modelo Cinema Studio 2.5 `cinematic_studio_2_5`, 1 cr/img, SIEMPRE preflight `get_cost:true`), ffmpeg/ffprobe.

## Global Constraints

- Copy del video en **inglés**; texto EXACTO de los beats copiado del spec (ver Task 4).
- Paleta/tipos del sistema web: papel oscuro `#0D120E`, papel claro `#F7F8F4`, tinta `#F2F3EE`, lima `#CCFF00`, verde señal `#00C805`, Archivo Black (display), IBM Plex Mono (mono).
- **Nada de stats/tracción inventada**: los únicos montos visibles son los del tape ilustrativo ya etiquetado en la web.
- Higgsfield: presupuesto duro ≤ **15 créditos** en total; preflight `get_cost:true` antes de cada generación.
- Los binarios NO van al repo público: `promo/teaser-pinned/assets/` y `promo/teaser-pinned/renders/` van al `.gitignore`. Se commitea solo fuente (HTML/scripts/config).
- Nadie publica nada: los MP4 finales se entregan a Jose en disco.
- Al cerrar (Jose eligió corte): borrar candidatos Higgsfield descartados y capturas crudas ya compuestas (regla de limpieza de media del CLAUDE.md global).

---

### Task 1: Scaffold del proyecto HyperFrames

**Files:**
- Create: `promo/teaser-pinned/` (proyecto HyperFrames vía `init`)
- Modify: `.gitignore` (raíz del repo)

**Interfaces:**
- Produces: proyecto HyperFrames validable en `promo/teaser-pinned/` con `index.html` raíz; carpetas `assets/` y `renders/` ignoradas por git.

- [ ] **Step 1: Leer las skills de HyperFrames** — invocar `Skill: hyperframes` (router) y `Skill: hyperframes-cli`. Son el contrato canónico del CLI (init/validate/render); este plan NO redefine su sintaxis.

- [ ] **Step 2: Inicializar el proyecto**

```bash
mkdir -p /c/Users/PC/Flap/promo && cd /c/Users/PC/Flap/promo
npx hyperframes init teaser-pinned   # aceptar defaults; composición 1920x1080 si lo pregunta
cd teaser-pinned && npx hyperframes doctor
```
Expected: `doctor` sin errores fatales (Chrome/ffmpeg detectados).

- [ ] **Step 3: Ignorar binarios**

Agregar al `.gitignore` de la raíz del repo:
```gitignore
# promo: binarios de video/imagen no van al repo publico
promo/teaser-pinned/assets/
promo/teaser-pinned/renders/
```

- [ ] **Step 4: Commit**

```bash
cd /c/Users/PC/Flap && git add promo/teaser-pinned .gitignore && git commit -m "chore(promo): scaffold hyperframes del teaser pinned"
```

---

### Task 2: Capturas de la web real en producción

**Files:**
- Create: `web/scripts/_promo-capture.mjs` (vive en `web/scripts/` porque Playwright SOLO resuelve con cwd=`web/`)
- Create (output): `promo/teaser-pinned/assets/tape-hero.webm`, `sec-01.png`, `sec-02.png`, `sec-03.png`, `stats.png`

**Interfaces:**
- Produces: `tape-hero.webm` (~12s, 1920×1080, el hero con el feed llenándose y el block real subiendo) + 4 stills de secciones. Task 4 los consume por esos nombres exactos.

- [ ] **Step 1: Escribir el script de captura**

```js
// web/scripts/_promo-capture.mjs — captura assets del teaser desde PROD
// Uso: cd web && node scripts/_promo-capture.mjs
import { chromium } from "playwright";

const URL = "https://robinshare.vercel.app/";
const OUT = "C:/Users/PC/Flap/promo/teaser-pinned/assets";
const VP = { width: 1920, height: 1080 };

const browser = await chromium.launch({ channel: "chrome" });

// 1) video del hero: el tape llenándose (12s)
const ctx = await browser.newContext({ viewport: VP, recordVideo: { dir: OUT, size: VP } });
const page = await ctx.newPage();
await page.goto(URL, { waitUntil: "load" });
await page.waitForTimeout(2500);      // primer fill + block cargado
await page.waitForTimeout(12000);     // 12s de feed corriendo
const vid = page.video();
await ctx.close();                     // flushea el webm
console.log("video:", await vid.path());

// 2) stills de secciones /01 /02 /03 y stats (scroll dirigido)
const page2 = await browser.newPage({ viewport: VP });
await page2.goto(URL, { waitUntil: "load" });
await page2.waitForTimeout(1500);
const beats = [
  ["sec-01", "/01"], ["sec-02", "/02"], ["sec-03", "/03"],
];
for (const [name, num] of beats) {
  const el = page2.locator(`text="${num}"`).first();
  await el.scrollIntoViewIfNeeded();
  await page2.waitForTimeout(900);    // reveals/animaciones asientan
  await page2.screenshot({ path: `${OUT}/${name}.png` });
  console.log("shot:", name);
}
const stats = page2.locator("text=Admin keys").first();
await stats.scrollIntoViewIfNeeded();
await page2.waitForTimeout(900);
await page2.screenshot({ path: `${OUT}/stats.png` });
console.log("shot: stats");
await browser.close();
```

- [ ] **Step 2: Ejecutarlo y renombrar el webm**

```bash
cd /c/Users/PC/Flap/web && node scripts/_promo-capture.mjs
cd /c/Users/PC/Flap/promo/teaser-pinned/assets && mv *.webm tape-hero.webm
```
Expected: log `video:` + 4 `shot:`; quedan `tape-hero.webm` + 4 PNG.

- [ ] **Step 3: Verificar el video con ffprobe y a ojo**

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 tape-hero.webm   # ~14 (2.5 + 12)
```
Leer 2–3 frames extraídos (`ffmpeg -i tape-hero.webm -vf fps=1/4 f%d.png`) con la tool Read: el tape debe verse llenándose, sin cursor ni scrollbar rara. Si el feed no corre en el webm, subir los waits y re-capturar.

- [ ] **Step 4: Commit (solo el script — assets están gitignored)**

```bash
cd /c/Users/PC/Flap && git add web/scripts/_promo-capture.mjs && git commit -m "feat(promo): captura de assets del teaser desde prod"
```

---

### Task 3: Bookends 3D con Higgsfield (solo corte B)

**Files:**
- Create (output): `promo/teaser-pinned/assets/bookend-open.png`, `bookend-close.png`

**Interfaces:**
- Consumes: MCP Higgsfield (`mcp__d268d28c-…__generate_image`; cargar schema vía ToolSearch).
- Produces: 2 PNG elegidos (apertura y cierre). Task 4 los consume por esos nombres.

- [ ] **Step 1: Preflight de costo** — llamar `generate_image` con `get_cost:true` para el modelo `cinematic_studio_2_5`. Expected: 1 crédito/imagen. Si difiere, recalcular: presupuesto duro ≤15 créditos total.

- [ ] **Step 2: Generar 4 candidatos (2 por prompt)**

Prompt 1 (apertura, papel oscuro):
> Studio still life photograph of a single elegant wooden longbow with a deep forest-green grip, standing upright on a seamless very dark green-black paper background (#0D120E), soft diffused studio key light from the upper left, subtle lime-green (#CCFF00) rim light tracing the bow's curve, tactile wood grain texture, minimalist centered composition, large negative space, premium product photography, 16:9

Prompt 2 (cierre, hermano del de apertura):
> Studio still life photograph of a single arrow lying diagonally on seamless very dark green-black paper (#0D120E), fletching in lime green (#CCFF00), soft studio light, long soft shadow, tactile feather and wood texture, minimalist composition with large negative space, premium product photography, 16:9

- [ ] **Step 3: Curar sin piedad** — Leer los 4 con la tool Read. Criterio de descarte: render genérico/plástico, texto fantasma, anatomía rara del objeto, fondo que no lea como papel. Si los 4 fallan, UNA ronda más (4 imágenes) refinando el prompt con lo aprendido; si vuelve a fallar, **fallback aprobado en spec**: el corte B degrada a tipografía sobre papel oscuro (== corte A) y se le informa a Jose.

- [ ] **Step 4: Guardar los 2 elegidos** como `assets/bookend-open.png` y `assets/bookend-close.png` (descarga vía la URL que devuelve el MCP). Borrar los descartados del disco.

---

### Task 4: Composición de los 5 beats (una línea de tiempo, variable `bookends`)

**Files:**
- Modify: `promo/teaser-pinned/index.html` (+ los archivos de escena que el contrato de HyperFrames pida)

**Interfaces:**
- Consumes: assets de Tasks 2–3 por nombre exacto; contrato de `hyperframes-core` + `hyperframes-animation` (leerlas ANTES de escribir HTML).
- Produces: composición validable con variable `bookends` (true=corte B / false=corte A).

- [ ] **Step 1: Leer `Skill: hyperframes-core`, `Skill: hyperframes-animation` y `Skill: hyperframes-media`** — timing `data-*`, `class="clip"`, variables de composición, reglas de playback de media y determinismo. El HTML se escribe contra ese contrato, no de memoria.

- [ ] **Step 2: Armar la línea de tiempo** con este contenido EXACTO (copy del spec, verbatim):

| Beat | t | Contenido | Motion (de hyperframes-animation) |
|---|---|---|---|
| 1 Hook | 0–4s | `Robin Hood is about sharing.` — Archivo Black, tinta sobre papel oscuro. Si `bookends`: `bookend-open.png` de fondo con parallax lento (scale 1.06→1.0), texto encima | entrada por palabra, stagger |
| 2 Twist | 4–7s | `We built that on-chain.` — lima `#CCFF00` sobre `#0D120E`, corte seco | hard cut + settle |
| 3 Producto | 7–19s | `tape-hero.webm` (7–13s, encuadre con leve zoom-in) → `sec-01.png`/`sec-02.png`/`sec-03.png` (13–19s, 2s c/u, slide editorial). Rótulos mono pequeños: `the real product — live at robinshare.vercel.app` | media playback del framework + Ken Burns suave |
| 4 Promesa | 19–24s | Tres líneas en secuencia: `Every trade pays the builder.` / `0 admin keys.` / `100% of the fee → builder.` (la última en lima) | stack cinético, una línea por beat de música |
| 5 Remate | 24–28s | BowMark (copiar el SVG de `web/components/BowMark.tsx` a HTML inline) + `ROBINSHARE` + `Soon on Robinhood Chain.` + `robinshare.vercel.app` en mono. Si `bookends`: `bookend-close.png` de fondo, oscurecido | logo sting, fade out limpio |

- [ ] **Step 3: Validar**

```bash
cd /c/Users/PC/Flap/promo/teaser-pinned && npx hyperframes validate && npx hyperframes lint
```
Expected: 0 errores.

- [ ] **Step 4: Snapshot de frames clave y revisarlos** — `npx hyperframes snapshot` (o `capture`) en t≈2s, 10s, 16s, 21s, 26s; Leer los PNG. Cada beat debe leerse en <1s de mirada; tipografía sin desbordes.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/PC/Flap && git add promo/teaser-pinned && git commit -m "feat(promo): composicion 5 beats del teaser (variable bookends)"
```

---

### Task 5: Música

**Files:**
- Create (output): `promo/teaser-pinned/assets/bgm.mp3` + registro en el ledger de media-use

**Interfaces:**
- Consumes: `Skill: media-use` (verbo `resolve`).
- Produces: `assets/bgm.mp3` (~30s o loopeable), cableado a la composición como pista de audio.

- [ ] **Step 1: Resolver BGM** — invocar `Skill: media-use` con necesidad: *BGM electrónico limpio, pulso contenido tipo tech-minimal, 25–35s, sin épica de trailer, mood confiado*. Expected: archivo local congelado + entrada en ledger.

- [ ] **Step 2: Cablear el audio a la composición** según el contrato de `hyperframes-media` (pista de audio con fade-out en el beat 5). Re-correr `npx hyperframes validate`. Expected: 0 errores.

- [ ] **Step 3: Commit** (fuente solamente): `git add promo/teaser-pinned && git commit -m "feat(promo): bgm cableado"`

---

### Task 6: Render de ambos cortes + verificación

**Files:**
- Create (output): `promo/teaser-pinned/renders/teaser-B.mp4`, `renders/teaser-A.mp4`

**Interfaces:**
- Consumes: composición de Tasks 4–5.
- Produces: 2 MP4 finales para el gate.

- [ ] **Step 1: Render corte B** (bookends=true) y **corte A** (bookends=false) con `npx hyperframes render` pasando la variable según el contrato del CLI; salidas a `renders/teaser-B.mp4` y `renders/teaser-A.mp4`.

- [ ] **Step 2: Verificar contenedores**

```bash
cd /c/Users/PC/Flap/promo/teaser-pinned/renders
for f in teaser-A.mp4 teaser-B.mp4; do ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height -of default=nw=1 "$f"; done
```
Expected: h264, 1920×1080, duración 25–30s, tamaño ≪512MB (límites de X sobrados).

- [ ] **Step 3: Ver los videos de verdad** — extraer 6 frames por corte (`ffmpeg -i teaser-B.mp4 -vf fps=1/5 fB%d.png`) y Leerlos; confirmar: tape visiblemente animado en el beat 3, copy sin typos, bookends solo en B, fade final limpio.

---

### Task 7: Quality-gate

- [ ] **Step 1: Juez** — invocar `Skill: quality-gate` delegando al subagent `juez-entregables` con: los frames extraídos de ambos cortes, el spec, y el copy. Pedir veredicto ship/revise por corte.
- [ ] **Step 2: Fix loop** — si `revise`: aplicar blockers concretos (Tasks 4–6 según toque) y re-render SOLO el corte afectado. Cap: 2 ciclos; si no converge, presentar a Jose el estado con los hallazgos abiertos.

---

### Task 8: Entrega + mirror

- [ ] **Step 1: Entregar** — mensaje final a Jose con las rutas de `teaser-B.mp4` y `teaser-A.mp4`, qué mirar en cada uno, y el recordatorio de que él publica/pinnea.
- [ ] **Step 2: Vault** — actualizar `C:\Users\PC\Obsidian\Proyectos\Crypto\DeFi\Fledge.md` (sección promo: spec, plan, cortes renderizados, créditos gastados) + commit+push del vault.
- [ ] **Step 3: Commit final del repo** — fuente de la composición al día; binarios afuera (gitignore de Task 1).
- [ ] **Step 4: Limpieza diferida** — cuando Jose elija corte: borrar el corte perdedor si él quiere, candidatos Higgsfield descartados (ya borrados en Task 3) y capturas crudas ya compuestas.

## Self-review

- **Cobertura del spec**: hook/twist/producto/promesa/remate ✓ (Task 4), dos cortes ✓ (Tasks 4/6), web real como centro ✓ (Task 2), Higgsfield ≤15 créditos + curaduría + fallback ✓ (Task 3), música catálogo ✓ (Task 5), quality-gate ✓ (Task 7), Jose publica / no stats inventadas ✓ (constraints + Task 8).
- **Placeholders**: los pasos de HyperFrames delegan sintaxis fina al contrato de sus skills (decisión explícita, son la doc canónica y viven en la máquina); todo lo demás — copy, prompts, scripts, comandos de verificación — está literal.
- **Consistencia de nombres**: `tape-hero.webm`, `sec-0N.png`, `stats.png`, `bookend-open/close.png`, `bgm.mp3`, `teaser-A/B.mp4` usados idénticos entre tasks ✓.
