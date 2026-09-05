# Deploy del bake-off FLEDGE: 3 direcciones de arte -> 3 proyectos Vercel.
# Requisito previo (una sola vez):  npx vercel login
$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\..\web"

$factory = if ($env:NEXT_PUBLIC_FACTORY_ADDRESS) { $env:NEXT_PUBLIC_FACTORY_ADDRESS } else { "0x0000000000000000000000000000000000000000" }

foreach ($d in @("sherwood", "legend", "hood", "sky", "nest", "avion")) {
  Write-Host "Deploying fledge-$d ..."
  npx vercel link --yes --project "fledge-$d" | Out-Null
  npx vercel deploy --prod --yes --build-env "NEXT_PUBLIC_DIRECTION=$d" --build-env "NEXT_PUBLIC_FACTORY_ADDRESS=$factory"
}

Remove-Item -Recurse -Force .vercel -ErrorAction SilentlyContinue
Write-Host "Listo -> fledge-sky / fledge-nest / fledge-avion .vercel.app"
