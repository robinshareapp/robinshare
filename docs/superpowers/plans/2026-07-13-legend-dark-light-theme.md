# Legend Dark/Light Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dar a Legend (la dirección ganadora de FLEDGE/RobinShare) un tema oscuro y uno claro con
toggle persistente, oscuro por defecto en la primera visita, sin flash del tema equivocado al
cargar.

**Architecture:** Los 7 tokens de color de Legend (`PAPER`, `INK`, `GREEN_TEXT`, `GREEN_CTA`,
`DIM`, `FAINT`, `HAIR`) pasan de ser literales hex/rgba a ser **referencias a variables CSS**
(`var(--rs-paper)`, etc.) definidas en `globals.css` — oscuro en `:root`, claro bajo
`[data-robinshare-theme="light"]`. Un script inline bloqueante en `layout.tsx` fija el atributo
`data-robinshare-theme` en `<html>` ANTES de que React hidrate, leyendo `localStorage`. Esto hace
que el primer pintado sea correcto por CSS/cascada del navegador, sin depender del timing de
hidratación de React — evita el flash incluso para un usuario que ya eligió claro antes. React
solo necesita saber el tema para dibujar el ícono correcto del toggle (sol/luna), no para pintar
los colores (eso ya lo resuelve la cascada CSS).

**Tech Stack:** Next.js 16 / React 19 / CSS custom properties (sin dependencias nuevas, sin
Tailwind `dark:`, sin `next-themes`).

## Global Constraints

- Alcance **solo** `web/app/directions/legend/LegendHome.tsx` + los dos archivos compartidos que
  este spec toca (`globals.css`, `layout.tsx`). Ninguna otra dirección del bake-off se modifica.
- Primera visita (sin valor en `localStorage`) → **oscuro**.
- Clave de `localStorage`: `"robinshare-theme"`, valores `"dark"` | `"light"`.
- Paleta oscura ya verificada con la fórmula de contraste WCAG (ver spec):
  fondo `#0D120E`, texto `#F2F3EE` (~19:1), acento/CTA lima `#CCFF00` (~16:1), feed en vivo
  `#00C805` sin cambios (~8.3:1).
- El panel terminal (`fledge://tape`) sigue siendo siempre oscuro en los dos temas — no se toca.
- No renombrar copy a "RobinShare" en este plan (tarea aparte).
- Verificación final: chequeo visual en el Brave real de Jose (`claude-in-chrome`), no solo el rig
  propio (regla del proyecto).

---

### Task 1: Variables CSS de tema en `globals.css`

**Files:**
- Modify: `web/app/globals.css`

**Interfaces:**
- Produces: variables CSS `--rs-paper`, `--rs-ink`, `--rs-green-text`, `--rs-green-cta`,
  `--rs-green-cta-text`, `--rs-dim`, `--rs-faint`, `--rs-hair`, `--rs-nav-gradient`,
  `--rs-watermark`, `--rs-feather-ink-filter` — que Task 3 consume por nombre exacto.

- [ ] **Step 1: Agregar el bloque de variables al final de `globals.css`**

Abrir `web/app/globals.css` y agregar al final del archivo:

```css
/* RobinShare (Legend) — tema oscuro/claro. Oscuro es el default (:root);
   [data-robinshare-theme="light"] lo sobreescribe. El atributo lo fija
   un script bloqueante en layout.tsx ANTES de que React hidrate, así que
   la cascada CSS ya pinta el tema correcto en el primer frame. */
:root {
  --rs-paper: #0D120E;
  --rs-ink: #F2F3EE;
  --rs-green-text: #CCFF00;
  --rs-green-cta: #CCFF00;
  --rs-green-cta-text: #0D120E;
  --rs-dim: rgba(242, 243, 238, 0.65);
  --rs-faint: rgba(242, 243, 238, 0.5);
  --rs-hair: rgba(242, 243, 238, 0.14);
  --rs-nav-gradient: linear-gradient(to bottom, rgba(13, 18, 14, 0.97) 0%, rgba(13, 18, 14, 0.85) 60%, transparent);
  --rs-watermark: rgba(242, 243, 238, 0.045);
  --rs-feather-ink-filter: brightness(1.4) saturate(1.3) contrast(1.1);
}

[data-robinshare-theme="light"] {
  --rs-paper: #F7F8F4;
  --rs-ink: #0D120E;
  --rs-green-text: #087C2E;
  --rs-green-cta: #0B6B2E;
  --rs-green-cta-text: #FFFFFF;
  --rs-dim: rgba(13, 18, 14, 0.6);
  --rs-faint: rgba(13, 18, 14, 0.58);
  --rs-hair: rgba(13, 18, 14, 0.14);
  --rs-nav-gradient: linear-gradient(to bottom, rgba(247, 248, 244, 0.97) 0%, rgba(247, 248, 244, 0.85) 60%, transparent);
  --rs-watermark: rgba(13, 18, 14, 0.045);
  --rs-feather-ink-filter: saturate(0.6) brightness(0.78) contrast(1.05);
}
```

- [ ] **Step 2: Verificar que no rompe nada (el resto del sitio no referencia estas variables todavía)**

Run: `cd web && npx tsc --noEmit 2>&1 | grep -v "routes.test.ts"`
Expected: sin salida (CSS puro, no afecta TypeScript).

- [ ] **Step 3: Commit**

```bash
git add web/app/globals.css
git commit -m "feat(theme): variables CSS de tema oscuro/claro para Legend (RobinShare)"
```

---

### Task 2: Script anti-flash en `layout.tsx`

**Files:**
- Modify: `web/app/layout.tsx`

**Interfaces:**
- Consumes: clave `localStorage` `"robinshare-theme"` (Global Constraints).
- Produces: atributo `data-robinshare-theme="dark"|"light"` en `document.documentElement`,
  fijado ANTES del primer pintado — Task 1 lo consume vía el selector `[data-robinshare-theme=...]`,
  Task 4 lo consume/actualiza desde `useTheme()`.

- [ ] **Step 1: Leer el archivo actual para confirmar la estructura**

El archivo hoy (`web/app/layout.tsx`) es:

```tsx
export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col" suppressHydrationWarning>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
```

- [ ] **Step 2: Agregar el script bloqueante como primer hijo de `<body>`**

Reemplazar el `return` de `RootLayout` por:

```tsx
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col" suppressHydrationWarning>
        {/* RobinShare (Legend): fija data-robinshare-theme ANTES de que React
            hidrate, leyendo localStorage. Sin esto, un usuario que ya eligió
            "light" vería un flash de oscuro (el default) antes de corregirse
            cuando React monta. Script síncrono e inline = bloquea el pintado
            hasta terminar, por eso corre a tiempo. Inocuo para el resto de
            las direcciones del bake-off (nadie más lee este atributo). */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              '(function(){try{var t=localStorage.getItem("robinshare-theme");' +
              'document.documentElement.setAttribute("data-robinshare-theme",' +
              '(t==="light"||t==="dark")?t:"dark");}catch(e){}})();',
          }}
        />
        <Providers>{children}</Providers>
      </body>
    </html>
  );
```

- [ ] **Step 3: Verificar tipos**

Run: `cd web && npx tsc --noEmit 2>&1 | grep -v "routes.test.ts"`
Expected: sin salida.

- [ ] **Step 4: Verificar en el navegador que el atributo se fija**

Con el dev server corriendo (`npm run dev` en `web/`), abrir `http://localhost:3000/v/legend`,
abrir devtools → Elements, confirmar que `<html>` tiene `data-robinshare-theme="dark"` (primera
visita, sin nada en localStorage todavía).

- [ ] **Step 5: Commit**

```bash
git add web/app/layout.tsx
git commit -m "feat(theme): script anti-flash que fija data-robinshare-theme antes de hidratar"
```

---

### Task 3: Convertir los tokens de color de Legend a variables CSS

**Files:**
- Modify: `web/app/directions/legend/LegendHome.tsx`

**Interfaces:**
- Consumes: variables de Task 1 (`--rs-paper`, `--rs-ink`, `--rs-green-text`, `--rs-green-cta`,
  `--rs-green-cta-text`, `--rs-dim`, `--rs-faint`, `--rs-hair`, `--rs-nav-gradient`,
  `--rs-watermark`, `--rs-feather-ink-filter`).
- Produces: las MISMAS constantes (`PAPER`, `INK`, `GREEN_TEXT`, `GREEN_CTA`, `DIM`, `FAINT`,
  `HAIR`) que ya usa el resto del archivo — ningún otro sitio de uso cambia, solo estas 7 líneas
  de definición. Task 4 consume `GREEN_CTA_TEXT` (nueva constante) para el color de texto de los
  botones.

- [ ] **Step 1: Reemplazar el bloque de constantes de color**

En `web/app/directions/legend/LegendHome.tsx`, el bloque actual es:

```tsx
const PAPER = "#F7F8F4";
const INK = "#0D120E";
const GREEN = "#00C805";
// #00C805 sobre papel ronda 2.1:1 de contraste — ilegible como texto (falla
// incluso el 3:1 de WCAG para texto grande). Mismo hue, oscurecido a ~5:1
// para titulares/labels; el verde puro queda para fills/dots donde no carga texto.
const GREEN_TEXT = "#087C2E";
// mismo hallazgo, otro angulo: #00C805 a plena saturacion en los FILLS de CTA
// lee "app de trading retail", no "brokerage suizo solemne" (audit ciclo 3).
// El verde puro queda exclusivo del tape en vivo (dot + LiveVaultFeed) donde
// el neon SI lee como señal; los botones sobre papel usan este verde-bosque
// mas oscuro + texto blanco (~6.6:1 — INK sobre este tono ya no alcanza 4.5:1).
const GREEN_CTA = "#0B6B2E";
const DIM = "rgba(13,18,14,0.6)";
// 0.42 rondaba ~2.7:1 sobre PAPER (fallaba AA hasta en texto grande) — los
// eyebrows/labels de dato son parte del sistema editorial, no decoracion.
const FAINT = "rgba(13,18,14,0.58)";
const HAIR = "rgba(13,18,14,0.14)";
const ZERO = "0x0000000000000000000000000000000000000000";
```

Reemplazarlo por:

```tsx
// Los 7 tokens de color ahora son referencias a variables CSS (ver
// web/app/globals.css) en vez de literales — el navegador resuelve el valor
// correcto por la cascada CSS según el atributo data-robinshare-theme del
// <html>, que un script bloqueante en layout.tsx fija ANTES de que React
// hidrate. Ningún otro sitio de uso de estas constantes cambia.
const PAPER = "var(--rs-paper)";
const INK = "var(--rs-ink)";
const GREEN = "#00C805"; // sin variar por tema: color de "dato en vivo" (dot + feed)
const GREEN_TEXT = "var(--rs-green-text)";
const GREEN_CTA = "var(--rs-green-cta)";
const GREEN_CTA_TEXT = "var(--rs-green-cta-text)";
const DIM = "var(--rs-dim)";
const FAINT = "var(--rs-faint)";
const HAIR = "var(--rs-hair)";
const ZERO = "0x0000000000000000000000000000000000000000";
```

- [ ] **Step 2: Reemplazar `color: "#fff"` por `GREEN_CTA_TEXT` en los 4 botones simples**

Confirmar primero cuántas ocurrencias hay de la cadena exacta `color: "#fff"` en el archivo:

Run: `grep -c 'color: "#fff"' web/app/directions/legend/LegendHome.tsx`
Expected: `5`

Una de esas 5 está dentro del ternario del botón "Check balance" y se trata aparte en el Step 2b
(porque esa misma línea también necesita otro cambio). Las otras 4 son idénticas en forma —
`style={{ background: GREEN_CTA, color: "#fff" }}` — y aparecen en: el CTA del nav ("Launch a
coin"), el CTA del hero ("Launch a coin"), el botón "Claim" de la lista de resultados del ledger,
y el CTA final ("Launch a coin for someone"). En las 4, reemplazar `color: "#fff"` por
`color: GREEN_CTA_TEXT`, dejando `background: GREEN_CTA` y el resto de cada línea intacto. Ejemplo
del CTA del nav:

```tsx
// antes
<Link href="/create" className="rounded-full px-4 py-1.5 text-sm font-bold" style={{ background: GREEN_CTA, color: "#fff" }}>

// después
<Link href="/create" className="rounded-full px-4 py-1.5 text-sm font-bold" style={{ background: GREEN_CTA, color: GREEN_CTA_TEXT }}>
```

Aplicar el mismo reemplazo textual (`color: "#fff"` → `color: GREEN_CTA_TEXT`) en las otras 3
líneas que comparten exactamente el patrón `style={{ background: GREEN_CTA, color: "#fff" }}` —
verificar con el mismo grep del principio de este step que ahora da `1` (solo queda la del
ternario, que se arregla en el Step 2b).

- [ ] **Step 2b: Corregir el color de texto del botón "Check balance" habilitado**

El ternario actual del botón "Check balance" es:

```tsx
style={
  loading || !value
    ? { background: "transparent", borderColor: "rgba(13,18,14,0.3)", color: FAINT }
    : { background: GREEN_CTA, borderColor: GREEN_CTA, color: "#fff" }
}
```

Reemplazar por:

```tsx
style={
  loading || !value
    ? { background: "transparent", borderColor: "rgba(13,18,14,0.3)", color: FAINT }
    : { background: GREEN_CTA, borderColor: GREEN_CTA, color: GREEN_CTA_TEXT }
}
```

(La rama `disabled` con `borderColor: "rgba(13,18,14,0.3)"` queda hardcodeada a tinta oscura a
propósito — es un borde MUY sutil pensado para el fondo claro; sobre fondo oscuro un borde de
tinta oscura casi no se ve. Ver Step 2c.)

- [ ] **Step 2c: Hacer visible el borde del estado disabled en modo oscuro**

Mismo bloque del Step 2b — el borde `"rgba(13,18,14,0.3)"` (tinta oscura) es invisible sobre el
fondo oscuro nuevo. Reemplazar por la constante `FAINT` (ya es variable, resuelve claro en los dos
temas, y ya tiene suficiente presencia como borde — a diferencia de `HAIR`, que a 0.14 es
demasiado sutil para un borde de botón). Usar directamente:

```tsx
    ? { background: "transparent", borderColor: FAINT, color: FAINT }
```

(Reemplaza `borderColor: "rgba(13,18,14,0.3)"` por `borderColor: FAINT` — `FAINT` ya resuelve a un
tono con suficiente presencia en los dos temas, y evita un literal hardcodeado más.)

- [ ] **Step 3: Arreglar el gradiente del nav (no seguía las constantes)**

Buscar:

```tsx
style={{
  background: "linear-gradient(to bottom, rgba(247,248,244,0.97) 0%, rgba(247,248,244,0.85) 60%, transparent)",
  transform: navHidden ? "translateY(-100%)" : "none",
}}
```

Reemplazar por:

```tsx
style={{
  background: "var(--rs-nav-gradient)",
  transform: navHidden ? "translateY(-100%)" : "none",
}}
```

- [ ] **Step 4: Arreglar el watermark "FLEDGE" del footer**

Buscar:

```tsx
style={{
  fontFamily: "var(--f-display)",
  fontSize: "clamp(6rem,18vw,15rem)",
  color: "rgba(13,18,14,0.045)",
  letterSpacing: "-0.02em",
}}
```

Reemplazar `color: "rgba(13,18,14,0.045)"` por `color: "var(--rs-watermark)"`.

- [ ] **Step 5: Aplicar el filtro de tema a la pluma de tinta**

Buscar el `<img>` de `feather-ink.png`:

```tsx
<img
  src="/legend/feather-ink.png"
  alt=""
  className="w-full opacity-80"
  style={{
    filter: "saturate(0.6) brightness(0.78) contrast(1.05)",
    maskImage: "radial-gradient(64% 70% at 54% 48%, black 50%, transparent 85%)",
    WebkitMaskImage: "radial-gradient(64% 70% at 54% 48%, black 50%, transparent 85%)",
  }}
  draggable={false}
/>
```

Reemplazar la línea de `filter` por:

```tsx
    filter: "var(--rs-feather-ink-filter)",
```

(El resto —`maskImage`— no depende del tema, se deja igual.)

- [ ] **Step 6: Verificar tipos y lint**

Run: `cd web && npx tsc --noEmit 2>&1 | grep -v "routes.test.ts" && npm run lint 2>&1 | grep -A5 LegendHome`
Expected: tsc sin salida; lint solo el error preexistente de `useReducedMotion` (línea ~51,
`Avoid calling setState() directly within an effect`) — nada nuevo introducido por este task.

- [ ] **Step 7: Verificación visual — tema oscuro (default) se ve bien**

Con el dev server corriendo:

```bash
cd web
SCR="<scratchpad de la sesión actual>"
node scripts/_scrollshots.mjs http://localhost:3000/v/legend "$SCR/rs-dark" "0,0.3,0.42,0.55,0.72,0.9" "1440x900"
```

Leer cada captura (`Read` tool) y confirmar: fondo oscuro, titulares/CTA en lima legible, feed en
vivo en verde Robinhood, pluma de tinta visible (no invisible sobre el fondo oscuro), nav con
gradiente oscuro (no una franja clara pegada arriba).

- [ ] **Step 8: Commit**

```bash
git add web/app/directions/legend/LegendHome.tsx
git commit -m "feat(theme): tokens de color de Legend via variables CSS + fixes de nav/watermark/pluma"
```

---

### Task 4: Toggle sol/luna en el nav

**Files:**
- Modify: `web/app/directions/legend/LegendHome.tsx`

**Interfaces:**
- Consumes: atributo `data-robinshare-theme` en `document.documentElement` (fijado por Task 2).
- Produces: hook `useTheme()` → `{ theme: "dark"|"light", toggle: () => void }`, usado solo dentro
  de este archivo.

- [ ] **Step 1: Agregar el hook `useTheme` (junto a `useReducedMotion`, mismo archivo)**

Ubicar la función `useReducedMotion` (cerca de la línea 47) y agregar inmediatamente después:

```tsx
type Theme = "dark" | "light";

// Lee el tema real recién en el efecto (igual que useReducedMotion) — el
// valor inicial "dark" coincide con el default de primera visita, así que
// no hay mismatch de hidratación. El script anti-flash de layout.tsx ya
// pintó el color correcto por CSS antes de este punto; este hook solo
// necesita saber el tema para dibujar el ícono correcto del toggle.
function useTheme() {
  const [theme, setTheme] = useState<Theme>("dark");

  useEffect(() => {
    const attr = document.documentElement.getAttribute("data-robinshare-theme");
    if (attr === "light" || attr === "dark") setTheme(attr);
  }, []);

  const toggle = () => {
    setTheme((prev) => {
      const next: Theme = prev === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-robinshare-theme", next);
      try {
        localStorage.setItem("robinshare-theme", next);
      } catch {
        // localStorage puede fallar en modo privado — el toggle sigue
        // funcionando para esta sesión, solo no persiste.
      }
      return next;
    });
  };

  return { theme, toggle };
}
```

- [ ] **Step 2: Usar el hook dentro de `LegendHome`**

Ubicar el inicio de `export function LegendHome()`:

```tsx
export function LegendHome() {
  useScrollSync();
  const navHidden = useHideNav();
  const reduce = useReducedMotion();
  const { type, setType, value, setValue, rows, error, loading, lookup } = useVaultLookup();
  const inkFeather = useRef<HTMLDivElement>(null);
```

Agregar la línea del hook después de `useReducedMotion()`:

```tsx
export function LegendHome() {
  useScrollSync();
  const navHidden = useHideNav();
  const reduce = useReducedMotion();
  const { theme, toggle: toggleTheme } = useTheme();
  const { type, setType, value, setValue, rows, error, loading, lookup } = useVaultLookup();
  const inkFeather = useRef<HTMLDivElement>(null);
```

- [ ] **Step 3: Agregar el botón de toggle en el nav**

Ubicar el nav (dentro de `<div className="flex items-center gap-5">`, justo antes del `<Link
href="/create">` de "Launch a coin"):

```tsx
          <div className="flex items-center gap-5">
            <a href="#ledger" className="hidden text-sm font-medium underline-offset-4 hover:underline sm:block" style={{ color: DIM }}>
              Check a balance
            </a>
            <Link href="/create" className="rounded-full px-4 py-1.5 text-sm font-bold" style={{ background: GREEN_CTA, color: GREEN_CTA_TEXT }}>
              Launch a coin
            </Link>
          </div>
```

Insertar el botón de toggle ANTES del `<a href="#ledger">`:

```tsx
          <div className="flex items-center gap-5">
            <button
              type="button"
              onClick={toggleTheme}
              aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
              className="flex h-8 w-8 items-center justify-center rounded-full transition-colors"
              style={{ color: INK }}
            >
              {theme === "dark" ? (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden>
                  <circle cx="12" cy="12" r="4.5" stroke="currentColor" strokeWidth="1.6" />
                  <path d="M12 2v2.5M12 19.5V22M4.2 4.2l1.8 1.8M18 18l1.8 1.8M2 12h2.5M19.5 12H22M4.2 19.8L6 18M18 6l1.8-1.8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
                </svg>
              ) : (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden>
                  <path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
                </svg>
              )}
            </button>
            <a href="#ledger" className="hidden text-sm font-medium underline-offset-4 hover:underline sm:block" style={{ color: DIM }}>
              Check a balance
            </a>
            <Link href="/create" className="rounded-full px-4 py-1.5 text-sm font-bold" style={{ background: GREEN_CTA, color: GREEN_CTA_TEXT }}>
              Launch a coin
            </Link>
          </div>
```

(Sol = tema oscuro activo, click para pasar a claro; luna = tema claro activo, click para pasar a
oscuro — la convención habitual es mostrar el ícono del modo AL QUE SE VA, no el actual; si Jose
prefiere la convención inversa avisar y se invierte el `theme === "dark" ? ... : ...`.)

- [ ] **Step 4: Verificar tipos y lint**

Run: `cd web && npx tsc --noEmit 2>&1 | grep -v "routes.test.ts" && npm run lint 2>&1 | grep -A5 LegendHome`
Expected: igual que Task 3 Step 6 (solo el warning preexistente de `useReducedMotion`).

- [ ] **Step 5: Commit**

```bash
git add web/app/directions/legend/LegendHome.tsx
git commit -m "feat(theme): toggle sol/luna en el nav de Legend"
```

---

### Task 5: Verificación end-to-end + gate en el navegador real de Jose

**Files:**
- Ninguno (task de verificación).

- [ ] **Step 1: Ciclo completo del toggle**

Con el dev server corriendo, en `http://localhost:3000/v/legend`: confirmar que carga en oscuro
(primera visita), click en el toggle → pasa a claro (fondo papel, verde-bosque en botones), click
de nuevo → vuelve a oscuro. Recargar la página (F5) en modo claro → debe seguir en claro (leyó
`localStorage`), no volver a oscuro.

- [ ] **Step 2: Confirmar que no hay flash al recargar en modo claro**

Con el tema en claro guardado, recargar la página varias veces seguidas mirando el primer frame —
no debe aparecer ni una fracción de segundo de fondo oscuro antes de mostrar claro. Si hay
throttling de CPU disponible en devtools, probar con 4x-6x slowdown para exagerar cualquier flash.

- [ ] **Step 3: Re-capturar y re-leer las 6 fracciones de Task 3 Step 7, esta vez en modo CLARO**

```bash
cd web
SCR="<scratchpad de la sesión actual>"
node scripts/_scrollshots.mjs http://localhost:3000/v/legend "$SCR/rs-light" "0,0.3,0.42,0.55,0.72,0.9" "1440x900"
```

Confirmar que el modo claro se ve exactamente igual que antes de este plan (mismo look que ya
pasó la auditoría 10/10) — este plan no debe haber alterado nada del modo claro existente.

- [ ] **Step 4: Verificación en el Brave real de Jose**

Usar `claude-in-chrome` (ya conectado esta sesión) para navegar a `http://localhost:3000/v/legend`
en su navegador real, probar el toggle ahí, y confirmar visualmente los dos temas — regla del
proyecto: el veredicto final no se da por bueno solo con el rig propio.

- [ ] **Step 5: Reportar a Jose**

Resumen: toggle funcionando, oscuro por defecto en primera visita, sin flash, modo claro intacto.
Preguntar si el ícono sol/luna representa el modo correcto (activo vs. "al que se va") a su gusto.
