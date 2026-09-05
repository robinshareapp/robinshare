#!/usr/bin/env bash
# deploy-factory.sh — el deploy de la RobinShareVaultFactory, en un solo comando.
#
#   cd /c/Users/PC/Flap && bash deploy-factory.sh
#
# ── SOBRE LA PRIVATE KEY ────────────────────────────────────────────────────────────────────────
# La pide `read -s` de bash: se escribe a ciegas y NO queda en el historial del shell, ni en un
# archivo, ni en una variable de entorno exportada, ni en este repo.
#
# SI queda, por unos segundos, en los argumentos del proceso `forge` (o sea visible para otro
# proceso del MISMO usuario que corra `ps` en ese instante). Es el unico camino que foundry ofrece
# para una llave cruda: `--private-key` no tiene equivalente por env var, y el prompt interactivo
# de foundry (`--interactives`) NO FUNCIONA bajo Git Bash — MSYS no le da una consola real al
# binario de Windows, asi que el prompt nunca aparece y el comando queda colgado para siempre.
# Eso ya paso una vez; por eso esta version usa lo que se pudo probar de verdad.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Direcciones publicas decididas (PENDIENTES 3). Aca no hay secretos.
export ATTESTER_ADDRESS=0x1E047B17BF45aE7D29287bd6389De4982C343f0A
export ATTESTER_ADMIN=0x53C4656E84999960daE7f7C39513BfF3C8057E5C
DEPLOYER=0x7dB192cE69C1D6c0fA6d6CA27953c24f380014F0
RPC="${RPC:-https://rpc.mainnet.chain.robinhood.com}"   # el alias `robinhood` solo existe dentro de contracts/; la URL explicita funciona desde cualquier dir

echo "== 1/4 - la rama =="
RAMA="$(git -C "$RAIZ" rev-parse --abbrev-ref HEAD)"
case "$RAMA" in feat/pons-web|main) ;; *) false;; esac || { echo "   estas en '$RAMA'; corre: git checkout feat/pons-web"; exit 1; }
echo "   ok: $RAMA"

echo
echo "== 2/4 - se puede lanzar hoy? =="
( cd "$RAIZ/web" && DEPLOYER_ADDRESS="$DEPLOYER" node scripts/preflight.mjs ) \
  || { echo; echo "   El preflight encontro un bloqueante. No deployo."; exit 1; }

echo
echo "== 3/4 - el deploy =="
echo "   Esto GASTA ETH y es IRREVERSIBLE: attesterAdmin y xVerifier quedan grabados."
printf "   Escribi SI para continuar: "
read -r OK
[ "$OK" = "SI" ] || { echo "   cancelado."; exit 1; }

echo
printf "   Pega la private key del deployer y Enter (no se va a ver nada): "
read -s -r PK
echo
[ -n "$PK" ] || { echo "   no escribiste nada. cancelado."; exit 1; }

# LIMPIEZA Y DIAGNOSTICO ANTES DE PASARSELA A FOUNDRY.
#
# Pegar en una terminal de Windows arrastra basura invisible: un `` del portapapeles, un espacio
# al final, comillas si la copiaste de un JSON. Foundry entonces tira "Failed to decode private
# key", que no dice NADA sobre que arreglar — y como la llave no se ve mientras se pega, no hay
# forma de darse cuenta mirando.
#
# Aca se limpia lo limpiable y, si igual no cierra, se dice EXACTAMENTE que se recibio SIN mostrar
# la llave: cuantos caracteres y si son todos hexadecimales.
PK="$(printf '%s' "$PK" | tr -d '[:space:]"'"'"'`')"
case "$PK" in 0x*|0X*) PK="0x${PK#0[xX]}" ;; *) PK="0x$PK" ;; esac
HEX="${PK#0x}"
if [ "${#HEX}" -ne 64 ]; then
  echo "   ESA NO PARECE UNA PRIVATE KEY."
  echo "     recibi ${#HEX} caracteres (sin contar el 0x); una private key tiene 64."
  if [ "${#HEX}" -gt 64 ]; then
    echo "     de mas: puede que hayas pegado dos veces, o que se colara algo del portapapeles."
  elif [ "${#HEX}" -eq 0 ]; then
    echo "     vacio: en Git Bash el pegado NO es Ctrl+V. Usa CLICK DERECHO o Shift+Insert."
  else
    echo "     de menos: se pego cortada. En Git Bash pega con CLICK DERECHO o Shift+Insert."
  fi
  echo "     (si lo que tenes es una frase de 12/24 palabras, eso es una SEED, no una private key:"
  echo "      exporta la private key desde tu wallet)"
  unset PK HEX; exit 1
fi
case "$HEX" in
  *[!0-9a-fA-F]*)
    echo "   ESA NO PARECE UNA PRIVATE KEY."
    echo "     tiene 64 caracteres pero alguno no es hexadecimal (solo valen 0-9 y a-f)."
    unset PK HEX; exit 1 ;;
esac
unset HEX

# Que la llave sea la del deployer que el preflight acaba de aprobar. Sin esto, una llave
# equivocada deploya una factory perfecta desde la wallet equivocada — y hay que redeployar.
DIR="$(cast wallet address --private-key "$PK")"
if [ "${DIR,,}" != "${DEPLOYER,,}" ]; then
  echo "   ESA NO ES LA LLAVE DEL DEPLOYER."
  echo "     da:      $DIR"
  echo "     esperaba: $DEPLOYER"
  unset PK; exit 1
fi
echo "   llave ok: $DIR"
echo

cd "$RAIZ/contracts"
# --compute-units-per-second 40: el RPC publico esta detras de Cloudflare y corta las rafagas.
# Sin esto la simulacion se arrastra o devuelve HTML en vez de JSON.
forge script script/DeployPons.s.sol --rpc-url "$RPC" --broadcast \
  --compute-units-per-second 40 --private-key "$PK"
unset PK

echo
echo "== 4/4 - que quedo en la cadena =="
FACTORY="$(python -c "
import json
d=json.load(open('broadcast/DeployPons.s.sol/4663/run-latest.json'))
print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='RobinShareVaultFactory'][0])
")"
echo "   FACTORY: $FACTORY"
echo
for f in attester attesterAdmin feeEscrow ponsFactory xVerifier; do
  printf "   %-14s %s\n" "$f" "$(cast call "$FACTORY" "$f()(address)" --rpc-url "$RPC")"
done
echo
echo "   Pasale esta direccion a Claude para que la verifique: $FACTORY"
echo "   Y despues corre:  bash preparar-vercel.sh"
