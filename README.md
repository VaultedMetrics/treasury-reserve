# VaultedMetrics Treasury Reserve

An autonomous, ownerless on-chain treasury for an ERC-20 token on Ethereum. Every 12 hours it buys the token from its Uniswap V2 pool, pairs part of the purchase with ETH as permanent liquidity, burns the liquidity tokens, and sends a share of the purchase to reward wallets. Ownership was renounced on September 27, 2026; since then no one can withdraw, pause, modify or stop it. It runs until its ETH is spent.

This repository is the verified source exactly as deployed. Anyone can rebuild the bytecode and compare it to the contract on Ethereum mainnet.

- Contract: `0x76371561F18f3f5B4ed85a251ac9b245864b8a2A` — https://etherscan.io/address/0x76371561F18f3f5B4ed85a251ac9b245864b8a2A#code
- Renounce transaction: `0xdfe8511e40ee99e16a92347e4845ac5ea9f9f0cb7b53953845a9e85ae7a37b0f` (September 27, 2026)
- Token it serves: VM888 `0x062570121e9519C77CB71C7936B6C1f76C7B1119` (fixed supply, ownership renounced March 13, 2026)
- Pool: Uniswap V2 pair `0xdfad37E05c4a203cd9aCa0f856407a0634f5b467`
- Audits (Cyberscope): https://www.cyberscope.io/audits/vm888 — reports at https://github.com/cyberscope-io/audits/tree/main/vm888
- Live statistics read from the chain: https://vaultedmetrics.io/terminal/

## What one Beat does

A Beat is one call of `performUpkeep(bytes)` by any address, allowed once every 12 hours (`BEAT_INTERVAL`). Calls alternate between two chamber patterns:

1. FLOOR + REWARD — buy from the pool, add half as permanent liquidity (LP tokens sent to the dead address), send the reward share to the staking and ecosystem wallets.
2. FLOOR + SHIELD — buy from the pool, add permanent liquidity, hold the rest as a shield that deploys as liquidity when the price falls hard.

The size of each buy is set by an on-chain exponential moving average of the pool price (`EMA_ALPHA_BPS`), bounded against manipulation (`MAX_PRICE_DEVIATION_BPS`) and a 30-minute TWAP check. Four bands — rising, stable, falling, crash — spend more ETH as the price falls (`BUY_*_MIN/MAX` constants), never more than the contract holds above `MIN_ETH_RESERVE`.

ETH enters only through `deposit()` from the whitelisted treasury wallets or through `receive()`; tokens never leave to any owner. After renouncement the `onlyOwner` functions (`setInitialEMA`, `setShieldLiquidityHelper`, `emergencyWithdrawETH`, `emergencyWithdrawTokens`) can no longer be called by anyone — `owner()` is the zero address.

## Verify it yourself

Compiler `v0.8.20+commit.a1b79de6`, optimizer off, EVM version `shanghai`, no constructor arguments. The sources under `src/` are the exact files Etherscan verified (Solidity Standard JSON, 14 files including the OpenZeppelin 5.x contracts it imports). Compile with those settings and compare the deployed bytecode at the address above.

## Reuse it

The contract is MIT-licensed. To run the same pattern for another token: change the token, router and pair constants, the five wallet constants, and the buy-band amounts; deploy; seed it with ETH from a whitelisted wallet; set the initial EMA from a reliable price; schedule two `performUpkeep` calls a day; renounce ownership once it has run correctly. The reference deployment has executed its 12-hour cycle without interruption since July 2026.

## Files

- `src/VaultedMetricsReserve.sol` — the Reserve and its `ShieldLiquidityHelper`
- `src/@openzeppelin/…` — the exact OpenZeppelin files compiled with it
- `abi.json` — the ABI as published on Etherscan
- `DEPLOYMENT.md` — compiler settings, addresses, the renounce transaction, the audit trail

VaultedMetrics LLC, Ohio, United States. If we believe it, then it's built into our code.
