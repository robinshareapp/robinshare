# RobinShare (Legend) — modo oscuro/claro con toggle

**Contexto (Jose, 2026-07-13):** Legend ganó el bake-off tras el pase de auditoría 10/10 (ambas
direcciones LIMPIAS, verificadas en su Brave). El proyecto se llamará **RobinShare** (cuenta X
`@RobinShareApp` ya creada, bio: "Launch tokens on Robinhood's network and route fees to the
people you choose."). Jose pidió: "hazla en modo oscuro también, empieza con negro y que luego
puedan ponerlo en modo light es decir blanco" — Legend necesita los dos temas, con oscuro como
default de primera visita.

## Alcance

- **Solo Legend** (`web/app/directions/legend/LegendHome.tsx`). No se toca ninguna otra dirección
  del bake-off (quedan archivadas ahora que hay ganadora).
- El rename de copy/logo a "RobinShare" (nav, `<title>`, `package.json`, footer) es una tarea
  **aparte**, no incluida en este spec — se coordina por separado.
- El panel terminal (`fledge://tape`) sigue siendo **siempre oscuro** en los dos temas — ya lo es
  hoy en el modo claro, no cambia.

## Paleta oscura (variante aprobada tras preview en vivo)

Verificada con la misma fórmula de contraste WCAG usada en la auditoría 10/10:

| Rol | Claro (hoy) | Oscuro (nuevo) | Contraste oscuro |
|---|---|---|---|
| Fondo | `PAPER` `#F7F8F4` | `#0D120E` (la tinta actual) | — |
| Texto/ink | `INK` `#0D120E` | `#F2F3EE` (crema) | ~19:1 vs fondo |
| Titulares/CTA de marca | `GREEN_TEXT` `#087C2E` | **lima** `#CCFF00` (el de la imagen ya publicada en `@RobinShareApp`) | ~16:1 vs fondo — muy por arriba del mínimo AA |
| Feed en vivo / dot del terminal | `GREEN` `#00C805` (sin cambios) | `#00C805` (sin cambios) | ~8.3:1 vs fondo oscuro |
| Labels/eyebrows | `FAINT`/`DIM` (tinta a 0.5-0.6) | mismo alpha, base crema | — |

El feed en vivo se queda en el verde Robinhood puro en los dos temas — es el color de "dato en
vivo", distinto del lima que es el acento de marca/CTA. Mismo principio que ya aplicamos en el
modo claro (un color por rol, no todo el mismo verde).

## Toggle

- Ícono sol/luna en el nav, junto a "Launch a coin". Visible, clickeable.
- Persiste en `localStorage` (clave `robinshare-theme`, valores `"dark"`/`"light"`).
- **Primera visita (sin valor guardado): oscuro.**
- **Anti-flash:** un script inline en `<head>` (antes de que React hidrate) lee `localStorage` y
  aplica el tema de entrada — evita el parpadeo típico de "carga claro, salta a oscuro" que se ve
  en implementaciones de dark-mode mal hechas.

## Arquitectura

Legend ya define sus colores como constantes JS (`PAPER`, `INK`, `GREEN_TEXT`, `GREEN_CTA`, `DIM`,
`FAINT`, `HAIR`) usadas directo en `style={{}}` a lo largo del archivo — no hay sistema de CSS
variables ni Tailwind `dark:` hoy. En vez de reescribir esas ~40 líneas de estilos inline a un
sistema nuevo (riesgo alto, fuera de alcance), el cambio mínimo es:

1. Un hook `useTheme()` que expone `{ theme, toggle }`, inicializado desde `localStorage` (con el
   script anti-flash cubriendo el primer paint).
2. Las constantes de color pasan a ser una función `colorsFor(theme)` que devuelve el set correcto
   — el resto del archivo no cambia (sigue usando `PAPER`, `INK`, etc. como antes, ahora derivados
   del theme activo en vez de hardcodeados).
3. El toggle vive en el nav, llama a `toggle()` del hook.

Esto mantiene el patrón existente del archivo (colores como valores JS, no clases Tailwind) en vez
de introducir una segunda convención de theming en el mismo componente.

## Asset: pluma de tinta (aprobado)

`feather-ink.png` hoy usa `filter: saturate(0.6) brightness(0.78) contrast(1.05)` — afinado para
leerse como tinta oscura sobre papel claro. Sobre fondo oscuro ese mismo filtro la vuelve casi
invisible (verde oscuro sobre fondo oscuro). Fix: **el mismo PNG, dos presets de filtro** — uno
por tema (el actual para claro; uno más brillante/saturado, sin oscurecer, para oscuro), elegido
según `theme` igual que el resto de los colores. No hace falta regenerar el asset.

## Fuera de alcance

- Rename de copy a "RobinShare" (tarea aparte).
- Toggle o modo oscuro en las otras 8 direcciones del bake-off (archivadas).
- Cambios a `/create` o `/claim` (pendientes de que se aplique el sistema visual ganador, tarea
  posterior a este spec).

## Verificación

- Contraste de cada color oscuro verificado con la fórmula WCAG antes de este spec (ver tabla).
- Toggle probado: oscuro→claro→oscuro, recarga de página mantiene el último elegido, primera
  visita (localStorage vacío) entra en oscuro.
- Sin flash de tema incorrecto al cargar (verificar visualmente con throttling/recarga dura).
- Verificación final en el Brave real de Jose antes de dar por cerrado, como el resto de este
  proyecto.
