# FLEDGE — Rediseño Premium (bake-off de 3 mundos en subdominios)

**Fecha:** 2026-07-11 · **Diseño:** Fable 5 (workflow de research + art-director) · **Codebase:** `C:\Users\PC\Flap\web`

## Objetivo

Elevar la web de FLEDGE de "Tailwind gris por defecto" a **premium con personalidad fuerte**, comprometiéndose a UNA dirección de arte por mundo (lección PACOI/FlapWorld: comprometerse > ofrecer switchers tibios). Alcance: **landing completa** (la pieza premium) + **create/claim reciben el mismo sistema visual** manteniendo su estructura funcional. Eje elegido por Jose: **Robin Hood / petirrojo (robin bird)**.

Metodología (como PACOI): **3 mundos genuinamente distintos**, cada uno en su **subdominio Vercel**, para comparar en vivo y elegir el ganador. No son recolores (tipografía + color + materiales + voz distintos en cada uno).

## Constraints madre (invariantes del repo)

- **Dark theme único** (se cambia QUÉ dark, no se sale de dark). Tailwind 4 via `@theme` en `globals.css`; tokens nuevos solo como CSS variables ahí.
- **Todo el markup visual es inline** en los page files → redesign barato, nada que desmontar (no hay sistema de diseño previo).
- **La máquina de estados wagmi/viem es INTOCABLE.** No puede romperse: lookup (select con values `github|twitter|wallet` que van on-chain), create secuencial (mina salt local, sube arte, `newTokenV6WithVault`), las 6 ramas del claim (wallet→sweep, github→OAuth+claimAndBind, twitter→tweet+x-prove+claimByProof, voucher-en-fragment, isBound→sweep, estados vacíos/error).
- **Copy en positivo** (comunica el mecanismo — de dónde salen los fees —, nunca la defensa). **Sin em-dashes. Sin Inter.** La UI jamás implica endorsement del receptor. Conservar el disclaimer "Not affiliated with Robinhood or Flap".
- **Higiene:** reemplazar `public/favicon.svg` (el morado `#863bff` del scaffold está prohibido); quitar deps muertas (`react-qr-code`, `@reclaimprotocol/js-sdk`).

## Las 3 direcciones

### A — THE NIGHT NEST (recomendada por el director) · hero generado
- **Mundo:** el observatorio de un naturalista a las 3am; un nido que la bandada alimenta gota a gota hasta que el pichón (petirrojo = robin = Robinhood) vuela al amanecer.
- **Tipografía:** Display **Fraunces** (una palabra en itálica por titular) · Body **Instrument Sans** · Mono **IBM Plex Mono**.
- **Paleta:** pine obsidian `#060A08` (dominante) + crema `#F5F1E8` (texto) + **ámbar `#FFAE45`** (acento: la gota, el huevo, la cifra del vault en GRANDE) + naranja pecho-de-petirrojo como segundo guiño (Robin Hood).
- **Hero:** asset generado (nido de cobre + huevo ámbar brillante), 2 capas 2.5D (plate de ramas desenfocadas atrás + nido nítido adelante), gota luminosa que cae al nido cada ~7s (los fees hechos visibles).
- **Motion:** preloader "INCUBATING 43%" → iris clip-path anclado al glow del huevo; scroll narrativo nido→gotas→ala→alba; ScrollReveal word-by-word. Micro-interacciones (máx 2): pulso de gota al hover del balance, odómetro del pending con meseta.
- **Textura:** grano 0.05 global + aberración HORNEADA en plates + niebla enmascarada en bordes de sección + haz vertical angosto sobre el nido.
- **Voz:** "Every trade drips into the nest. Only they can lift it out." / "Build a nest for the builder you admire." / "When they prove who they are, the nest opens."
- **Mapeo UI:** steps = egg/feed/fledge · vault card = el nido con su cifra · sweep = "flies to your wallet" · estado vacío = nido vacío · éxito del create = nace el pichón (reemplaza el emoji).

### B — SKYWRITER · tipográfica, CERO assets (fallback ejecutivo, shippea en 1 día)
- **Mundo:** cielo nocturno como jumbotron; cada launch es una dedicatoria gritada en tipografía gigante.
- **Tipografía:** Display **Anton** (clamp(3.5rem,12vw,11rem), uppercase) · Body **Archivo** · Mono **JetBrains Mono**.
- **Paleta:** obsidiana verde `#060907` + `#F4F7F2` (texto) + **signal green `#00FF85`** (acento que grita) + 1-2 secciones full-bleed INVERTIDAS (fondo verde, tipografía negra).
- **Hero:** 100% tipográfico. "LAUNCH A COIN / FOR SOMEONE / WHO SHIPS." (FOR pasa de contorno a relleno con scroll) + typewriter que cicla `for @dev`, `for @designer`, `for @maintainer`. Mark SVG propio: pájaro origami de 2 trazos a 3 escalas.
- **Motion:** stagger Framer easing [0.16,1,0.3,1] · ScrollReveal · secciones invertidas con clipPath scrubbed · ticker de vaults recientes. Micro: typewriter + split RGB 1px on-hover de titulares.
- **Textura:** grano 0.06 + viñeta. Sin fog (no hay assets que atmosferizar).
- **Voz:** "Someone you follow ships every day. Pay their rent." / "Launch their coin. Every trade feeds them." / "Only they can claim it. That is the whole point."
- El formato dedicatoria **"FOR: @handle"** es EL motivo del sistema (hero, vault card, claim, éxito).

### C — PAR AVION · hero generado + sistema postal
- **Mundo:** oficina de correos de medianoche sobre la chain; cada coin es correo certificado, solo el destinatario firma.
- **Tipografía:** Display **Staatliches** · Body **Spectral** · Mono **Courier Prime**.
- **Paleta:** night ink `#0B0E12` + `#F5EFE2` (texto) + **postal vermilion `#FF4B2E`**. Excepción con motivo: los vouchers/slips del claim en papel crema sólido con borde perforado (son comprobantes).
- **Hero:** asset generado (paquete kraft + lacre bajo spotlight; plate de fondo = paloma mensajera desenfocada). Motivo asesino: **el avatar de GitHub del receptor se vuelve una ESTAMPILLA perforada** (máscara CSS) en /create y el header del claim; postmark con el tx hash.
- **Motion:** eyebrows con efecto sello de goma (scale+rotación+settle); submit del create = el sobre se sella + postmark con hash real; parallax. Micro: tilt de estampilla on-hover + botón Copy que estampa "FRANKED".
- **Voz:** "Registered on-chain. Addressee only." / "Send a coin to someone who never asked. They sign for it whenever." / "No middlemen touch the mail. The chain holds it until they show ID."
- Mapea la invariante madre del contrato (el ETH solo va a quien probó identidad) a un lenguaje universal (correo certificado). recoverUnclaimed = "return to sender".

## Fundación compartida (las 3 la respetan)

- Grano óptico global (un wrapper `::after` fixed) + viñeta. Fuentes reales vía `next/font` (jamás horneadas en píxeles).
- Motion: respeta `prefers-reduced-motion` (set al estado final); `body { overflow-x: clip }`. Máx 2 micro-interacciones por dirección.
- Grid asimétrico (regla de tercios), `max-w-5xl` con offsets, padding de sección `clamp(96px,14vh,160px)`, escala base 4px. Hairlines que mueren a los lados.
- Eyebrows mono 11px tracking 0.22em MAYÚS unificados; addresses y cifras en mono `tabular-nums`.
- CTAs: pill SÓLIDO (nunca glass translúcido).
- QA: juez de arte aprueba el COMPOSITE renderizado (rig Playwright si el preview MCP falla) con checklist "¿se ve caro?" + anti-mockup, antes de cada deploy.

## Assets a generar con Gemini (Nano-Banana, navegador logueado de Jose)

Curar el mejor de ~varios; limpiar watermark (clone-stamp / inpainting dirigido según fondo); cutouts con rembg; aberración con `bake_chroma.py`.

**Night Nest (4):** (1) nido de cobre + huevo ámbar brillante, luz dura única, macro, fondo negro → cutout; (2) plate: ramas desenfocadas contra cielo casi-negro; (3) plate del alba (payoff del claim); (4) pluma con rim-light cálido → cutout. Petirrojo opcional como 5º (robin de pecho naranja posado, editorial, no cartoon).

**Par Avion (4):** (1) paquete kraft + lacre bajo spotlight → cutout; (2) plate: interior de oficina de correos nocturna desenfocada; (3) macro del lacre con relieve de pájaro → cutout (mark a escalas); (4) silueta de paloma en vuelo. Estampillas/postmarks/airmail = CSS, no imágenes.

**Skywriter:** cero assets generados (solo el mark SVG vectorial a mano).

## Deploy / bake-off

3 proyectos Vercel bajo `0xkeezy-3892`: `fledge-nest`, `fledge-sky`, `fledge-avion` (o subdominios `nest./sky./avion.`). Cada uno con el mismo `NEXT_PUBLIC_FACTORY_ADDRESS`. Jose elige el ganador en vivo → ese pasa a producción. Las direcciones no ganadoras quedan archivadas (git) como material para productos hermanos.

## Plan de ejecución (subsistemas)

1. **Assets** (navegador Gemini) → limpiar → a `web/public/`.
2. **Fundación compartida** (globals.css tokens, grano, motion utils, fuentes) — una vez, reusada.
3. **3 landings** (Skywriter no depende de assets; Nest/Avion sobre el arte real).
4. **Create/claim** con el sistema visual del ganador (o del que se vaya construyendo).
5. **QA de arte** por dirección + deploy a subdominios.
