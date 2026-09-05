# FLEDGE — Bake-off premium de 3 mundos (spec de diseño)

**Fecha:** 2026-07-11 · **Diseño:** Fable 5 (brief sintetizado por workflow desde el vault) · **Decisiones:** Jose
**Decisiones fijadas:** landing completa premium + create/claim pulidos con el sistema del ganador · personaje ligado a Robin Hood (petirrojo/"robin" aprobado) · **3 direcciones en subdominios** (patrón PACOI: elegir con los ojos) · assets con Gemini (navegador de Jose) ANTES de construir.

## Qué se construye

Tres landings completas, cada una un **mundo comprometido** (tipografía, paleta, materiales, motion y copy propios — no recolores), en un solo repo:

- `web/components/nest/NestHome.tsx` → **fledge-nest.vercel.app**
- `web/components/skywriter/SkyHome.tsx` → **fledge-sky.vercel.app**
- `web/components/avion/AvionHome.tsx` → **fledge-avion.vercel.app**

`app/page.tsx` elige el árbol por `NEXT_PUBLIC_DIRECTION` (`nest` | `sky` | `avion`), como PACOI con `NEXT_PUBLIC_THEME`. Cada landing integra el **lookup funcional intacto** (select github/twitter/wallet + input + `identityHashFor`/`getVaults` + lista con pending y links a claim). `/create` y `/claim` NO se triplican: siguen funcionando igual y