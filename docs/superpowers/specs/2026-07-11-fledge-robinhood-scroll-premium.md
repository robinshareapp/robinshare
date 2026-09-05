# FLEDGE — landing scroll-driven premium, temática Robin Hood (v2 del rediseño)

**Feedback de Jose (2026-07-11 noche):** el bake-off v1 quedó corto — 2 de 3 no van con la temática,
y esperaba *scroll motion, movement, un producto realmente premium* como lo aprendido en Aegis.
La temática Robin Hood es **principalmente verde**: hay quien referencia al *personaje* (Sherwood,
arquero, capucha) y quien referencia a la *empresa* (Robinhood, verde eléctrico `#00C805`, pluma).
Pide varias versiones dentro de esa temática y que le entregue lo mejor.

**Grounding de marca (verificado):** verde Robinhood `#00C805` (elegido para lectura joven/eléctrica);
la pluma del logo = pluma de la gorra de Robin Hood y a la vez flecha hacia arriba. Robinhood Chain
(donde FLEDGE vive, chainId 4663) se lanzó 2026-07-01, keynote "The World is Flat".

**La tesis narrativa:** FLEDGE *es* la historia de Robin Hood contada en serio — una tajada de cada
trade se toma del flujo y se jura a un builder; solo esa persona puede reclamarla. El scroll ES la
flecha: el usuario dispara al scrollear y la página cuenta el viaje del fee hasta su blanco.

## Dirección A — SHERWOOD (la leyenda, cinemática)

- **Mundo:** bosque de Sherwood de noche iluminado por verde eléctrico. Pino-negro `#050d08`,
  verdes profundos `#0d2818 / #14532d`, señal `#00C805` como color de LUZ (no de pintura),
  oro viejo `#d4a24e` para las monedas/fees, papel `#f2f0e4` para el tipo.
- **Tipo:** Instrument Serif como display gigante (clamp 4–9rem, leading apretado, itálicas como
  énfasis), Instrument Sans cuerpo, IBM Plex Mono datos.
- **Narrativa por scroll (actos):**
  1. **Hero** — claro del bosque WebGL: niebla por capas, god-rays verdes, luciérnagas/motas.
     Display: la promesa ("A slice of every trade, sworn to the builder.").
  2. **El disparo** — al scrollear, una FLECHA se lanza y viaja por el bosque (cámara dolly
     siguiéndola); al pasar "trades" (partículas/tickers), va desprendiendo chispas doradas (los fees).
  3. **El blanco** — la flecha clava en una diana/cofre: ahí vive el lookup ("Were you the mark?").
  4. **La prueba** — identidades (GitHub/X/wallet) como tres actos de identidad + CTA create.
- **WebGL:** R3F canvas fijo + scroll nativo (backbone del vault), fog + planos de niebla,
  partículas instanciadas, flecha con curva (getPointAt en Curve), DPR cap, reduced-motion fallback.

## Dirección B — FEATHER (la empresa, fintech premium)

- **Mundo:** casi-negro `#0a0a0a` limpísimo, `#00C805` puro como único acento, blanco tipográfico.
- **Motivo:** una PLUMA (la de la gorra / el logo) que cae y flota con el scroll a través de las
  secciones — la pluma que escribe el nombre del builder en el escrow. Al final se posa y se vuelve
  la flecha del CTA.
- **Tipo:** grotesk contundente (Archivo Black / Geist-like) + mono. Contadores de stats, botones
  magnéticos, hairlines. La vibra de la página de Robinhood Legend pero elevada con WebGL.
- **Scroll:** pluma 3D (o plate 2.5D con máscara) con física de caída suave ligada a scroll velocity;
  secciones que se apilan con parallax de 3 capas.

## Reglas de ejecución (lecciones previas)

- **Un solo mundo por versión, ejecutado hondo** (lección PACOI: recolor ≠ dirección).
- Hero asset generado puede ser el 80% del wow (lección Aegis) — plates de bosque via Gemini/Brave
  si el 3D puro no llega al listón; híbrido plate + atmósfera WebGL es válido y más barato.
- QA con `_scrollshots.mjs` (posiciones de scroll, canvas sanity, channel chrome GPU).
- Juez: agente `aegis-visual-director` frame-by-frame vs benchmark antes de mostrar a Jose.
- Las 3 direcciones v1 (sky/nest/avion) quedan archivadas en `/v/<dir>` como referencia.

## Técnicas del vault (a llenar con el output del workflow de lectores)

*(pendiente al cierre del workflow `fledge-premium-recipes`)*
