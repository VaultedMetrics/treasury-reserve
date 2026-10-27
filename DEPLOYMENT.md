# Deployment record — VaultedMetrics Treasury Reserve

| Item | Value |
|---|---|
| Network | Ethereum mainnet (chain id 1) |
| Contract | 0x76371561F18f3f5B4ed85a251ac9b245864b8a2A |
| Contract name | VaultedMetricsReserve (v3.0, corrected for the Cyberscope re-audit, April 2, 2026) |
| Compiler | solc v0.8.20+commit.a1b79de6 |
| Optimizer | off (runs 200 setting unused) |
| EVM version | shanghai |
| Constructor arguments | none |
| License | MIT (SPDX in source) |
| Deployed | July 2026 |
| Ownership renounced | September 27, 2026 — tx 0xdfe8511e40ee99e16a92347e4845ac5ea9f9f0cb7b53953845a9e85ae7a37b0f |
| Owner today | 0x0000000000000000000000000000000000000000 |

## Fixed addresses inside the contract

| Constant | Address | Role |
|---|---|---|
| VM888_TOKEN | 0x062570121e9519C77CB71C7936B6C1f76C7B1119 | the token bought and burned-into-liquidity |
| UNISWAP_ROUTER | 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D (Uniswap V2 Router 02) | swaps and liquidity adds |
| UNISWAP_PAIR | 0xdfad37E05c4a203cd9aCa0f856407a0634f5b467 | the VM888/WETH pool |
| DEAD_ADDRESS | 0x000000000000000000000000000000000000dEaD | receives all LP tokens (liquidity is burned, not locked) |
| FOUNDERS_WALLET | 0x9E5ef891a89e57FaF907670e97005f91751F578c | one-time seed deposit |
| TREASURY_A | 0x011fC8Ca3553C4Ab7460ae50BB833bC398AACbe4 | ongoing fuel deposits |
| TREASURY_B | 0xeF9CF6F30950E8707A35Db1F2890a30dc79625C8 | backup fuel deposits |
| STAKING_WALLET | 0x40bA7dB618BD9eE95E9745D598629c0fF69c84eE | reward share |
| ECOSYSTEM_WALLET | 0x6a8D23738B76faFd8b14eB89308e9e437C3976F6 | reward share |

## Audit trail

- Cyberscope initial audit, March 27, 2026 — findings listed in the contract header, each resolved in v3.0.
- Cyberscope re-audit of v3.0 — report: https://github.com/cyberscope-io/audits/tree/main/vm888
- Cyberscope Reserve report with acknowledgements, July 27, 2026 and update October 5, 2026.
- Public audit page: https://www.cyberscope.io/audits/vm888

## How to confirm the bytecode

1. Put the `src/` tree into a Solidity Standard JSON input with the settings above (optimizer disabled, evmVersion shanghai).
2. Compile with solc 0.8.20.
3. Compare `evm.deployedBytecode` of `VaultedMetricsReserve` with `eth_getCode` at the contract address (metadata hash at the tail may be ignored if your toolchain appends a different one).
