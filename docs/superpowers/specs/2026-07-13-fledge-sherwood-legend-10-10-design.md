# FLEDGE — Sherwood + Legend a 10/10 (pase de calidad final)

**Pedido (Jose, 2026-07-13):** "Sherwood y Legend son los mejores, enfoquemoslos en dejarlos 10/10
ahora sí." Del bake-off de 6 direcciones (sherwood/legend/hood/decree/terminal/manga), estas dos
quedan como ganadoras candidatas. Este spec cubre el pase de pulido final antes de que Jose elija
una para restyle de `/create`+`/claim`.

## Alcance

- **Solo desktop.** El overflow de texto en mobile (390px) detectado hoy en Legend queda en una
  tarea aparte ya spawneada — no se mezcla en este pase.
- **Solo Sherwood y Legend** (`web/app/directions/sherwood/SherwoodHome.tsx`,
  `web/app/directions/legend/LegendHome.tsx` + los componentes compartidos que tocan:
  `LiveVaultFeed`, `Reveal`, `globals.css`).
- **Copy/narrativa:** no se reescribe proactivamente. Solo se toca si el art-director lo señala
  como parte de "se siente demo" (placeholders, voz genérica, texto de relleno).

## Criterio de "10/10"

Auditoría **a ciegas** (sin pre-sesgar con mis propias sospechas) via el agente
`aegis-visual-director`, con **peso extra en un criterio específico**: ¿esto lee como producto
real de una empresa, o como demo generada por IA? — el mismo eje que hundió el bake-off v2
(Jose lo puntuó 3/10–4.5/10 ahí). El resto de la rúbrica del agente (composición, jerarquía,
contraste, motion, coherencia de marca) aplica normal.

## Proceso — loop iterativo por dirección

Sherwood primero, Legend después (secuencial, para no cruzar ediciones en los componentes
compartidos). Por cada dirección:

1. Capturar los beats narrativos actuales con el rig (`cd web && node scripts/_scrollshots.mjs
   http://localhost:3000/v/<dir> <prefix> <fracs>`) en los puntos de scroll clave de esa dirección.
2. Correr `aegis-visual-director` con esas capturas + el código fuente — auditoría a ciegas +
   peso en "real vs demo".
3. Implementar cada hallazgo P0/P1 (yo mismo — ninguna de las dos usa R3F desde el rebuild v3;
   es Next.js + Tailwind + CSS + imágenes con screen-blend, sin WebGL).
4. Re-capturar y re-auditar la MISMA dirección.
5. Repetir hasta veredicto limpio (sin P0/P1) antes de pasar a la otra dirección.

## Gate final

Cuando ambas direcciones estén "limpias" según el art-director: verificación en **el Brave real
de Jose** (claude-in-chrome), no solo en mi rig — regla ya establecida este sprint (extensiones,
viewport real y feel del scroll solo existen donde mira el usuario). El "10/10" no se declara sin
que Jose lo haya visto funcionando en su propio navegador.

## Fuera de alcance

- Overflow mobile (tarea aparte, ya spawneada: `task_1db78961`).
- Las otras 4 direcciones del bake-off (decree/terminal/manga/hood) — no se tocan en este pase.
- Reescritura de copy no vinculada a un hallazgo concreto del art-director.
- Video teaser / Seedance — sigue pendiente de que Jose elija ganadora, no es parte de este pase.
