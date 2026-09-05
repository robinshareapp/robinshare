# FLEDGE — deploy del bake-off (3 subdominios)

Tres direcciones de arte, cada una en su subdominio, para elegir la ganadora.
El código es **uno solo**; la dirección se fija en build con `NEXT_PUBLIC_DIRECTION`.

| Dir     | Mundo                                   | Subdominio propuesto            |
|---------|-----------------------------------------|---------------------------------|
| `sky`   | Skywriter — verde ácido, brutalista     | https://fledge-sky.vercel.app   |
| `nest`  | Night Nest — petirrojo cinematográfico  | https://fledge-nest.vercel.app  |
| `avion` | Par Avion — postal, papel, sello de cera| https://fledge-avion.vercel.app |

## Paso único que requiere tu cuenta (una sola vez)

```bash
npx vercel login        # elegí tu método (GitHub / email). Es interactivo.
```

Yo no puedo hacer login por vos (no ingreso credenciales). Con eso hecho, el resto es autónomo.

## Deploy de las 3 (desde la raíz del repo)

```bash
# git-bash:
./scripts/deploy-bakeoff.sh
# o PowerShell:
./scripts/deploy-bakeoff.ps1
```

## Manual (si preferís controlar cada paso), desde `web/`

```bash
npx vercel deploy --prod --yes \
  --build-env NEXT_PUBLIC_DIRECTION=<sky|nest|avion> \
  --build-env NEXT_PUBLIC_FACTORY_ADDRESS=<factory>
# La primera vez pregunta el nombre del proyecto → usá fledge-<dir>.
```

## Nota sobre el factory

`NEXT_PUBLIC_FACTORY_ADDRESS` es **placeholder** hasta el launch de FLEDGE en Robinhood Chain.
Las landing renderizan perfecto sin factory real; el lookup solo lo usa cuando el usuario
hace clic en "buscar". Al desplegar el contrato real, re-deployá con la dirección verdadera.
