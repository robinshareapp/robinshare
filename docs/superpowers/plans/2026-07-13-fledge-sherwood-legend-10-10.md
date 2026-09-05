# Sherwood + Legend a 10/10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Llevar las direcciones Sherwood y Legend de FLEDGE (`C:\Users\PC\Flap\web`) a un veredicto "limpio" (sin hallazgos P0/P1) de un auditor de arte independiente, con foco específico en que ninguna de las dos se sienta "demo generada por IA" en vez de producto real — y confirmarlo en el navegador real de Jose antes de declararlas terminadas.

**Architecture:** Loop de auditoría→arreglo por dirección (Sherwood primero, Legend después). Cada ciclo: capturar beats de scroll con el rig Playwright existente (`web/scripts/_scrollshots.mjs`) → auditar esas capturas + el código fuente con el agente `aegis-visual-director` (auditoría ciega, prompt fijo) → implementar cada hallazgo P0/P1 directamente en el `.tsx`/`.css` que el hallazgo cite → sanity check (`tsc`+`lint`) → re-capturar → re-auditar. Máximo 3 ciclos por dirección; si al tercero sigue sucio, se detiene y se reporta a Jose en vez de seguir iterando indefinidamente. Gate final: verificación en el navegador real de Jose vía `claude-in-chrome`.

**Tech Stack:** Next.js 16 / React 19 / Tailwind 4, sin R3F/WebGL en estas dos direcciones (rebuild v3 asset-first: imágenes con `mix-blend-mode: screen` + transforms via rAF leyendo `Scroll.progress`). Playwright (`channel: chrome`, headed) para las capturas. Agente `aegis-visual-director` para el juicio (NO implementa, solo audita).

## Global Constraints

- Alcance **solo desktop**. El overflow de mobile (390px) en Legend NO se toca acá — es la tarea `task_1db78961` ya spawneada aparte.
- Solo se editan: `web/app/directions/sherwood/SherwoodHome.tsx`, `web/app/directions/legend/LegendHome.tsx`, y los compartidos que un hallazgo señale (`web/components/LiveVaultFeed.tsx`, `web/components/Reveal.tsx`, `web/app/globals.css`). No se tocan `hood/decree/terminal/manga`.
- La auditoría es **ciega**: el prompt del agente no debe incluirle mis propias sospechas ni el historial de bugs ya arreglados esta sesión — que lo encuentre solo.
- Todo hallazgo del agente debe pesar explícitamente el eje "¿esto lee como producto real de una empresa, o como demo generada por IA?" (además de composición/contraste/motion/marca).
- No reescribir copy salvo que un hallazgo concreto lo señale como parte de "se siente demo".
- Cap duro: **3 ciclos de auditoría por dirección**. Al tercero, si sigue habiendo P0/P1, PARAR y reportar a Jose — no looping infinito.
- El "10/10" no se declara sin pasar por el navegador real de Jose (`claude-in-chrome`), no solo el rig propio.
- Dev server (`npm run dev` en `web/`) debe estar corriendo en `localhost:3000` durante todo el plan — verificar al inicio de cada task, no asumir.

---

### Task 1: Baseline — capturar los beats actuales de Sherwood

**Files:**
- Ninguno se modifica. Output: capturas PNG en el directorio scratchpad de la sesión actual (usar el que el propio entorno indique; no hardcodear rutas de sesiones previas).

**Interfaces:**
- Consumes: `web/scripts/_scrollshots.mjs` (rig existente, firma: `node scripts/_scrollshots.mjs <url> <output-prefix> <fracciones-csv> [WxH]`).
- Produces: un set de PNGs `<prefix>-<frac*100>.png`, uno por fracción, que el Task 2 consume como input del audit.

- [ ] **Step 1: Verificar que el dev server está corriendo**

Run: `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/v/sherwood`
Expected: `200`. Si no, levantar con `cd web && npm run dev` (background) antes de continuar.

- [ ] **Step 2: Capturar los 9 beats de Sherwood a resolución de escritorio real (1440x900)**

Run (desde `web/`):
```bash
SCR="<scratchpad de la sesión actual>"
node scripts/_scrollshots.mjs http://localhost:3000/v/sherwood "$SCR/sw-audit1" "0,0.03,0.14,0.20,0.35,0.42,0.50,0.62,0.75,0.92" "1440x900"
```
Expected: 10 archivos `sw-audit1-00.png` … `sw-audit1-92.png`, cada uno con `y=<n>/<n>` (scroll aplicado, no clamped a 0) en la salida del script.

- [ ] **Step 3: Confirmar visualmente que cada captura corresponde a la sección esperada**

Leer cada PNG (`Read` tool) y confirmar contra esta tabla — si una fracción cae en la sección equivocada (por diferencias de alto real vs. lo estimado), ajustar la fracción y re-capturar esa sola:

| Fracción | Sección esperada (buscar este texto/elemento) |
|---|---|
| 0.00 | Hero, flecha nocked, titular "Take from the fees. / Give to the builder." |
| 0.03 | Hero en reposo, sin overlay oscuro fuerte todavía |
| 0.14 | Flecha en pleno vuelo hacia la luz (mitad de su recorrido) |
| 0.20 | Flecha cerca de desvanecerse / gate |
| 0.35 | "How it works" — filas 01·Mark / 02·Tax / 03·Claim |
| 0.42 | Fila de stats: 100ms / 0 / 3 / 51 |
| 0.50 | "The Take" — panel con `LiveVaultFeed` |
| 0.62 | "The Claim" — "One arrow. One name on it." |
| 0.75 | "The Ledger" — formulario de balance |
| 0.92 | Cierre "Loose your arrow." + footer |

- [ ] **Step 4: Commit — ninguno (task de solo-captura, no toca código)**

No aplica commit; las capturas quedan en scratchpad para el Task 2.

---

### Task 2: Loop auditoría→arreglo — Sherwood (hasta 3 ciclos)

**Files:**
- Modify: `web/app/directions/sherwood/SherwoodHome.tsx` (y, si un hallazgo lo señala explícitamente, `web/components/LiveVaultFeed.tsx`, `web/components/Reveal.tsx`, `web/app/globals.css`).

**Interfaces:**
- Consumes: capturas de Task 1 (`sw-audit1-*.png`) para el ciclo 1; capturas frescas propias para ciclos 2/3.
- Produces: `SherwoodHome.tsx` con los P0/P1 corregidos + un veredicto final de texto (limpio o lista de pendientes) que el Task 5 (gate final) consume.

**Prompt fijo para el agente `aegis-visual-director` (usar literalmente, sustituyendo `{PNGS}` por la lista de rutas del ciclo actual):**

```
Audita esta dirección de landing (SHERWOOD, FLEDGE) para un veredicto de calidad "10/10".
Capturas de los beats de scroll (en orden): {PNGS}
Código fuente: C:\Users\PC\Flap\web\app\directions\sherwood\SherwoodHome.tsx

Es una auditoría A CIEGAS — no asumas qué ya se corrigió antes, jzugalo con ojo fresco.

Aplica tu rúbrica normal (composición, jerarquía, contraste, coherencia de motion, marca) MÁS este
criterio con peso extra: ¿esto lee como el sitio de un producto real, o como una demo generada por
IA? Sé específico y técnico en cada hallazgo (qué archivo/línea/valor CSS, no solo "se ve raro").

Devolvé la respuesta en este formato exacto:
## Hallazgos
- [P0|P1|P2] <descripción específica> — archivo:línea si aplica, fix sugerido concreto
(uno por hallazgo; si no hay hallazgos de una severidad, omitila)

## Veredicto
LIMPIO — si no hay P0 ni P1.
PENDIENTE — si queda al menos un P0 o P1.
```

- [ ] **Step 1: Ciclo 1 — invocar al agente con las capturas de Task 1**

Usar el tool `Agent` con `subagent_type: aegis-visual-director` y el prompt fijo de arriba, `{PNGS}` = las 10 rutas de `sw-audit1-*.png`.

- [ ] **Step 2: Leer el veredicto**

Si `## Veredicto` dice `LIMPIO` → saltar a Task 3 (Sherwood terminado, no hace falta ciclo 2/3).
Si dice `PENDIENTE` → continuar al Step 3 con la lista de hallazgos P0/P1.

- [ ] **Step 3: Implementar cada hallazgo P0/P1 del ciclo 1**

Para cada hallazgo: abrir el archivo que cita (`Read` si no está ya en contexto), aplicar el fix con `Edit`. Si el hallazgo no especifica un valor concreto, elegir el fix técnico más directo consistente con el resto del archivo (mismo patrón que los fixes ya hechos esta sesión en Legend: medir con PIL si es un asset, revisar z-order/stacking si es un problema de superposición, etc.) — no dejar hallazgos sin resolver salvo que sean P2 (esos quedan anotados pero no bloquean el veredicto).

- [ ] **Step 4: Sanity check tras los fixes**

Run: `cd web && npx tsc --noEmit && npm run lint`
Expected: sin errores nuevos introducidos por los cambios (warnings pre-existentes no relacionados son aceptables).

- [ ] **Step 5: Commit del ciclo 1**

```bash
git add web/app/directions/sherwood/SherwoodHome.tsx
git commit -m "fix(sherwood): ciclo 1 de auditoria 10/10 — <resumen de 1 linea de los P0/P1 arreglados>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Re-capturar los mismos 9 beats (mismo comando que Task 1 Step 2, prefijo `sw-audit2`)**

- [ ] **Step 7: Ciclo 2 — repetir Steps 1-6 con `sw-audit2-*.png`, prefijo de commit "ciclo 2"**

Si el veredicto del ciclo 2 es `LIMPIO`, terminar acá (no hace falta ciclo 3).

- [ ] **Step 8: Ciclo 3 (solo si ciclo 2 seguía `PENDIENTE`) — repetir una vez más, prefijo `sw-audit3`**

Si tras este ciclo el veredicto SIGUE `PENDIENTE`: parar, NO seguir iterando. Documentar los hallazgos restantes en el resumen final (Task 5) para que Jose decida si son aceptables o si hace falta una ronda adicional fuera de este plan.

---

### Task 3: Baseline — capturar los beats actuales de Legend

**Files:**
- Ninguno se modifica. Output: PNGs en scratchpad.

**Interfaces:**
- Consumes: `web/scripts/_scrollshots.mjs`.
- Produces: PNGs `lg-audit1-*.png` que el Task 4 consume.

- [ ] **Step 1: Verificar dev server**

Run: `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/v/legend`
Expected: `200`.

- [ ] **Step 2: Capturar los 7 beats de Legend a 1440x900 (ancho real del hero — NO uses viewports artificialmente anchos, ya causó un falso negativo esta sesión con la pluma)**

Run (desde `web/`):
```bash
SCR="<scratchpad de la sesión actual>"
node scripts/_scrollshots.mjs http://localhost:3000/v/legend "$SCR/lg-audit1" "0,0.15,0.30,0.42,0.55,0.72,0.85" "1440x900"
```

- [ ] **Step 3: Confirmar visualmente cada captura**

| Fracción | Sección esperada |
|---|---|
| 0.00 | Hero: titular "Route fees to builders. Automatically." + panel terminal con la pluma + feed |
| 0.15 | Misma zona alta de la página; chequear posición de la pluma de TINTA (cae por el papel — `translate3d` con `fall = p*78vh`, `position: fixed`) relativa al contenido que ya scrolleó debajo |
| 0.30 | Mecanismo: cards "01 Name them / 02 Fees accrue / 03 They claim" |
| 0.42 | Fila de stats negro-gigante: 100ms / 0 / 3 / 51 |
| 0.55 | "One vault. One identity. Zero keys held." (sección custodia, fondo blanco) |
| 0.72 | "Is a vault accruing to you?" — formulario ledger |
| 0.85 | CTA final "Back the one who ships." + footer — chequear que la pluma de tinta (casi al final de su caída, `fall≈61vh`) no atropelle el CTA/footer |

- [ ] **Step 4: Commit — ninguno**

---

### Task 4: Loop auditoría→arreglo — Legend (hasta 3 ciclos)

**Files:**
- Modify: `web/app/directions/legend/LegendHome.tsx` (y compartidos si un hallazgo lo señala: `web/components/LiveVaultFeed.tsx`, `web/components/Reveal.tsx`, `web/app/globals.css`).

**Interfaces:**
- Consumes: capturas de Task 3 para ciclo 1; frescas para ciclos 2/3.
- Produces: `LegendHome.tsx` con P0/P1 corregidos + veredicto final para el Task 5.

**Prompt fijo (mismo formato que Task 2, adaptado a Legend):**

```
Audita esta dirección de landing (LEGEND, FLEDGE) para un veredicto de calidad "10/10".
Capturas de los beats de scroll (en orden): {PNGS}
Código fuente: C:\Users\PC\Flap\web\app\directions\legend\LegendHome.tsx

Es una auditoría A CIEGAS — no asumas qué ya se corrigió antes, juzgalo con ojo fresco.

Aplica tu rúbrica normal (composición, jerarquía, contraste, coherencia de motion, marca) MÁS este
criterio con peso extra: ¿esto lee como el sitio de un producto real (brokerage suizo, claro,
snappy), o como una demo generada por IA? Sé específico y técnico en cada hallazgo.

Devolvé la respuesta en este formato exacto:
## Hallazgos
- [P0|P1|P2] <descripción específica> — archivo:línea si aplica, fix sugerido concreto

## Veredicto
LIMPIO — si no hay P0 ni P1.
PENDIENTE — si queda al menos un P0 o P1.
```

- [ ] **Step 1: Ciclo 1 — invocar `aegis-visual-director` con `lg-audit1-*.png`**

- [ ] **Step 2: Leer veredicto.** Si `LIMPIO` → saltar a Task 5. Si `PENDIENTE` → Step 3.

- [ ] **Step 3: Implementar cada hallazgo P0/P1**

Mismo criterio que Task 2 Step 3. Si el hallazgo toca `LiveVaultFeed.tsx` (compartido con Sherwood), después de arreglarlo re-capturar UN frame de Sherwood en la sección donde aparece el feed (`p=0.50`) para confirmar que no se rompió nada ahí — no asumir que un cambio en un componente compartido es inocuo para la otra dirección.

- [ ] **Step 4: Sanity check**

Run: `cd web && npx tsc --noEmit && npm run lint`

- [ ] **Step 5: Commit del ciclo 1**

```bash
git add web/app/directions/legend/LegendHome.tsx
git commit -m "fix(legend): ciclo 1 de auditoria 10/10 — <resumen>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Re-capturar los mismos 7 beats, prefijo `lg-audit2`**

- [ ] **Step 7: Ciclo 2 — repetir Steps 1-6 con `lg-audit2-*.png`**

- [ ] **Step 8: Ciclo 3 (solo si sigue `PENDIENTE`) — repetir una vez más, prefijo `lg-audit3`. Cap duro: no seguir después de este.**

---

### Task 5: Gate final — verificación en el navegador real de Jose + reporte

**Files:**
- Ninguno (task de verificación + comunicación).

**Interfaces:**
- Consumes: el estado final de `SherwoodHome.tsx` y `LegendHome.tsx` tras Tasks 2 y 4.
- Produces: confirmación explícita en el navegador de Jose + resumen para él.

- [ ] **Step 1: Confirmar que ambas direcciones llegaron a `LIMPIO` (o documentar qué quedó pendiente)**

Si alguna de las dos se detuvo en ciclo 3 con `PENDIENTE`, preparar esa lista para mostrársela a Jose en vez de declarar "10/10".

- [ ] **Step 2: Navegar con `claude-in-chrome` (el Brave conectado de Jose) a `/v/sherwood`, scrollear por los beats clave, tomar screenshot**

Usar `mcp__claude-in-chrome__navigate` + `mcp__claude-in-chrome__computer` (scroll + screenshot) — cargar los tools vía `ToolSearch` si aparecen como deferred. Confirmar visualmente que coincide con lo verificado en el rig (mismos beats, sin sorpresas de extensiones/viewport real).

- [ ] **Step 3: Repetir Step 2 para `/v/legend`**

- [ ] **Step 4: Reportar a Jose**

Resumen conciso: qué se encontró y arregló en cada dirección (por ciclo), veredicto final de cada una, y si alguna quedó con pendientes tras el cap de 3 ciclos. Preguntar si con esto ya elige ganadora para el restyle de `/create`+`/claim`, o si quiere una ronda más en alguna.

- [ ] **Step 5: Mirror al vault (regla estándar del proyecto)**

Actualizar `C:\Users\PC\Obsidian\Proyectos\Crypto\DeFi\Fledge.md` con el resultado de este pase (qué se encontró, qué se arregló, veredicto final) y commit+push del vault.
