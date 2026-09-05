#!/usr/bin/env bash
# Deploy del bake-off FLEDGE: 3 direcciones de arte -> 3 proyectos Vercel.
# Requisito previo (una sola vez):  npx vercel login
set -euo pipefail
cd "$(dirname "$0")/../web"

FACTORY="${NEXT_PUBLIC_FACTORY_ADDRESS:-0x0000000000000000000000000000000000000000}"
DIRS=(sherwood legend hood sky nest avion)

for d in "${DIRS[@]}"; do
  echo "▶ deploying fledge-$d ..."
  # linkea (o crea) el proyecto fledge-$d apuntando a esta carpeta web/
  npx vercel link --yes --project "fledge-$d" >/dev/null
  npx vercel deploy --prod --yes \
    --build-env "NEXT_PUBLIC_DIRECTION=$d" \
    --build-env "NEXT_PUBLIC_FACTORY_ADDRESS=$FACTORY"
done

rm -rf .vercel   # limpiar el link local tras el último deploy
echo "✔ listo → fledge-sky / fledge-nest / fledge-avion .vercel.app"
