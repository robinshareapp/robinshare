# FLEDGE — "Tres registros": diferenciación real de las 3 direcciones (v4)

**Problema (Jose, 2026-07-12):** las tres direcciones v3 "se sienten literalmente muy similares".
Diagnóstico: compartían paleta (dark + #00C805 + oro), esqueleto de secciones, gramática de motion
(dolly + oscurecer) y hasta el gesto tipográfico (outline+sólido). Es la lección PACOI otra vez:
skins de una página ≠ direcciones. Los assets Gemini NO son el problema (la dirección foto-first
fue la mejor puntuada); el sistema de diseño repetido sí.

**Esquema aprobado (opción A): tres registros.** Lo ÚNICO común: la historia del producto
(hero → mecanismo → prueba → ledger/claim → CTA), la marca FLEDGE, y que el verde `#00C805`
existe en las tres — con ROL distinto en cada una.

## 1 · SHERWOOD — el santuario (oscuro-frío, solemne)

- **Queda** como está (catedral esmeralda + Instrument Serif + dolly lento + payoff oro).
- Poda: el titular pierde el outline+sólido (pasa a serif pura regular+itálica) — ese gesto
  queda EXCLUSIVO de ninguna (muere; Legend usa peso, Hood usa oro).
- Rol del verde: **la luz del mundo** (los rayos de la foto), no un color de UI.
- Motion: lento y solemne. Voz: juramento.

## 2 · LEGEND — el brokerage (CLARO, suizo, snappy)

- **Flip total a modo claro**: fondo papel `#F7F8F4`, tinta `#0D120E`, gris fintech
  `rgba(13,18,14,0.55)`, hairlines `rgba(13,18,14,0.14)`.
- Type: Archivo Black display NEGRO gigante sobre blanco; Archivo body; IBM Plex Mono datos.
- Rol del verde: **color de acción** — CTAs, deltas, sparkline, nada más.
- Layout: grid suizo denso. Hero: titular negro izquierda + **panel TERMINAL oscuro** derecha
  (la única zona oscura de la página; adentro: la pluma de luz con screen-blend + feed
  verde-fósforo). Tape ticker claro con bordes; steps como fila de cards con hairlines; stats
  en negro gigante; form de brokerage claro (labels mono grises, inputs subrayado negro, CTA
  verde); footer claro con pluma fantasma gris.
- Motion: **snappy** — cero dolly, count-ups, hovers marcados; la pluma solo flota DENTRO de
  su panel. Voz: brokerage ("Route fees to builders. Automatically.").
- Grain global: casi imperceptible en claro (el body::after existente actúa igual).

## 3 · HOOD — la película dorada (oscuro-cálido, centrado)

- Sigue el film (letterbox + title card + Cinzel + actos + arquero + cofre + two-shot).
- **Grade ámbar por CSS** en los plates (`sepia/hue-rotate/saturate`) — sin regenerar assets.
- Rol del color: **ORO dominante** (`#F0B750`/`#D9A441`) — acentos, numerales, y el CTA pasa a
  negro-sobre-oro (única página sin CTA verde). El verde queda SOLO en la estela de la flecha.
- Layout: centrado simétrico de póster en todo. Voz: taglines de cine.

## Assets

- Esta fase: **cero assets nuevos** (grade por CSS).
- Fase siguiente (calidad): **Higgsfield** para re-shoot de los stills cinematográficos clave
  (decisión: Higgsfield = finales; Gemini = iteración; ChatGPT descartado como principal).
  Bloqueado en: Jose debe loguearse una vez en higgsfield.ai en su Brave. Dato: Higgsfield
  tiene "MCP & CLI" para Claude — evaluar para automatizar la generación sin clicks.

## Verificación

- Build + rig GPU propio para iterar + **pasada final por el Brave de Jose** (regla nueva del
  vault: extensiones, viewport real y feel solo existen donde mira el usuario).
- Test de diferenciación: las 3 en miniatura lado a lado deben distinguirse al instante
  (claro / oscuro-frío / oscuro-cálido).
