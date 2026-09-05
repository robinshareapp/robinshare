// contracts/scripts/mine-salt.mjs
//
// Mina un salt cuyo tax token V6 termine en el vanity 0x7777, 100% LOCAL (sin RPC).
//
// Derivacion verificada on-chain (ver contracts/README.md § Hallazgos):
//   tokenAddr = CREATE2(
//     deployer     = Portal 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09,
//     salt         = el salt raw,
//     initCodeHash = keccak(EIP-1167 minimal-proxy(TAX_TOKEN_V3_IMPL 0x7777..3333)))
//
// OJO: el vault se crea ANTES del check de vanity en el portal, asi que NO se puede
// minar por eth_call del launch (revierte con returndata vacia). Esta derivacion local
// es la unica forma correcta y ademas no necesita nodo.
//
// Uso:  node scripts/mine-salt.mjs [sufijoHex]      (default 7777)
// Salida (stdout, JSON):  {"salt":"0x..","token":"0x..","iterations":N}

import { getContractAddress, keccak256 } from "viem";

const PORTAL = "0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09";
const TAX_TOKEN_V3_IMPL = "0x7777C8743C88B3aff3cf262135beF2c8b2e83333";
const SUFFIX = (process.argv[2] ?? "7777").toLowerCase().replace(/^0x/, "");

// bytecode del minimal-proxy (EIP-1167) que apunta al impl -> su keccak es el initCodeHash
const proxyInitCode =
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73" +
  TAX_TOKEN_V3_IMPL.slice(2).toLowerCase() +
  "5af43d82803e903d91602b57fd5bf3";
const bytecodeHash = keccak256(proxyInitCode);

function predict(saltBigInt) {
  const salt = "0x" + saltBigInt.toString(16).padStart(64, "0");
  return getContractAddress({ opcode: "CREATE2", from: PORTAL, salt, bytecodeHash });
}

for (let i = 1n; ; i++) {
  const token = predict(i);
  if (token.toLowerCase().endsWith(SUFFIX)) {
    console.log(JSON.stringify({ salt: "0x" + i.toString(16).padStart(64, "0"), token, iterations: Number(i) }));
    process.exit(0);
  }
  if (i % 200000n === 0n) console.error(`probados ${i}...`);
}
