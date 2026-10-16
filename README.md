# Pangea Multichain Hook

The Uniswap v4 hook used by every [Pangea](https://pangea.trade) launch pool, and the liquidity locker
that holds every launch's liquidity. Pangea is a launchpad: each token it launches trades on Ethereum,
BNB Chain, Base, Robinhood Chain and Solana. On the four EVM chains each token trades in a Uniswap v4
pool (native coin / token) that uses this hook, with its liquidity held by this locker.

This repository holds exactly the sources of the deployed contracts — `src/venues/PangeaFeeHook.sol`,
`src/venues/LiquidityLocker.sol`, the Pangea files they import (`src/FactoryList.sol`,
`src/venues/OpeningDust.sol`, `src/venues/SingleSidedMath.sol`) and the Uniswap v4-core and
OpenZeppelin files they import — byte-for-byte as compiled. `forge build` reproduces the deployed
bytecode of both; the metadata hash at the end of each contract's runtime code matches the chain.

## Deployments

Both are at the same address on all four chains:

| Contract | Address |
|---|---|
| PangeaFeeHook | **`0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc`** |
| LiquidityLocker | **`0xbebe68fBfB62E18FBFEbf4365970D192C5f34DC1`** |

| Chain | Chain id | Verified source (hook) | Verified source (locker) |
|---|---|---|---|
| Ethereum | 1 | [etherscan.io](https://etherscan.io/address/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc#code) · [Sourcify](https://repo.sourcify.dev/1/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc) | [etherscan.io](https://etherscan.io/address/0xbebe68fBfB62E18FBFEbf4365970D192C5f34DC1#code) |
| BNB Chain | 56 | [bscscan.com](https://bscscan.com/address/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc#code) · [Sourcify](https://repo.sourcify.dev/56/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc) | [bscscan.com](https://bscscan.com/address/0xbebe68fBfB62E18FBFEbf4365970D192C5f34DC1#code) |
| Base | 8453 | [basescan.org](https://basescan.org/address/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc#code) · [Sourcify](https://repo.sourcify.dev/8453/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc) | [basescan.org](https://basescan.org/address/0xbebe68fBfB62E18FBFEbf4365970D192C5f34DC1#code) |
| Robinhood Chain | 4663 | [explorer](https://robinhoodchain.blockscout.com/address/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc) · [Sourcify](https://repo.sourcify.dev/4663/0x15e5E7206C661a1E881F5CD33A94eAF2328FA8cc) | [Sourcify](https://repo.sourcify.dev/4663/0xbebe68fBfB62E18FBFEbf4365970D192C5f34DC1) |

Constructor arguments. Hook: `(poolManager, deployer, devBuyer, locker)`; locker: `(poolManager, deployer)`.
The deployer is `0x7794De82aa21CE22863102fB07E319daf85dd1c5` and the locker is `0xbebe…4DC1` on every chain.

| Chain | `poolManager` | `devBuyer` (the chain's LaunchFeeCollector) | Launch factories (`factories()`) |
|---|---|---|---|
| Ethereum | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0x79d9a01B6ADB4938761e7D4fb29a802ea709F0Ec` | `0x00F6c53704e089C946671AdC09110b09244bC07B`, `0x1D583e6eA4AA7c5e167a7E69B07b83DD5B813f53` |
| BNB Chain | `0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF` | `0xcDB037B5B4b58e3C89d632463656D889123a7c04` | `0x7808344Fc0A43e6a5D0E9cB565A13eF9618d61b5`, `0xd1454764E8D87B117a23491E77cAfcCC50430256` |
| Base | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x7cb08218648433bbC9671f885E15954756717BCa` | `0x025f893Bdcd7978232C211e3A28610FC6d8B8970`, `0xba4beE425F268f7Dc0F7e5457d14320d5A64cd06` |
| Robinhood Chain | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0xcDB037B5B4b58e3C89d632463656D889123a7c04` | `0x7808344Fc0A43e6a5D0E9cB565A13eF9618d61b5`, `0x8A1F3e1DB07048c007F6d9ab924494C77c0DBa65` |

`factoryAdmin` on both contracts, on every chain, is Pangea's admin key `0x93620a4A7d45A770ff2e801eB84b03a7630ae8B6`.

## What the hook does

Hook permissions (`0x28CC`): `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta`, `afterSwapReturnDelta`.

- **A fixed trading fee in the native coin, on buys and on sells.** Each pool is registered once by
  a launch factory with a fee between 0.3% and 5% (Pangea launches use 1%) and a fee destination
  (that token's own fee splitter: creator + platform). The fee is taken from the native side of every
  swap through the return deltas, so fees are always paid in ETH/BNB, never in the token. Exact-in
  and exact-out swaps pay the same rate. The pool's own LP fee is 0.
- **A pool's terms never change after registration.** No owner, no proxy, no pause; a pool's fee and
  fee destination are fixed for its life, recorded with the factory that registered it (`factoryOf`).
- **The launch's first buy is fee-free**: swaps made by `devBuyer` (the chain's LaunchFeeCollector,
  which makes a launch's dev buy or opening buy inside the launch transaction) pay no fee.
- **Liquidity is added only by the locker** (`beforeAddLiquidity`), or by an address the admin has
  allowed with `setLiquidityAdder` (none is set).
- **Swaps cannot end past the launch range's edge**, so the pool never leaves its liquidity.
- **No `hookData`** is read.

## The factory list (what is new in this hook)

The previous hook (`0x5B58…e8cc`, [pangea-fee-hook](https://github.com/nightcode112/pangea-fee-hook))
served exactly one launch factory, so every new factory meant a new hook at a new address. This one
keeps an append-only list of factories (`src/FactoryList.sol`), so the hook keeps its address.

- **What an added factory can do:** register NEW pools and seed NEW launches, as the first one can.
- **What it cannot do:** touch any existing pool or launch. Every pool is recorded once, by the factory
  that created it, with its fee and rules fixed then; nothing lets any factory write to it afterwards.
  Factories are never removed or replaced.
- **Who adds one:** `factoryAdmin`, the platform admin key, with no timelock. It is a power over new
  launches only. The same key can allow an extra liquidity adder (`setLiquidityAdder`).

## What the locker does

- **One locker per chain holds every launch's position**, each pool's position separate (the v4
  position salt is the pool id).
- **There is no function that removes liquidity.** The only liquidity writes are the one-time seed
  (positive liquidity, factory-only, once per pool) and fee collection (zero liquidity delta).
- **No owner, no proxy, no upgrade.** Its factory list works as the hook's.
- `collect(poolId)` is permissionless and pays that pool's fees only to that pool's own fee splitter,
  recorded at seeding. Fees never mix between pools.

## Build

```
forge build
```

Compiler settings (also in the metadata files): solc 0.8.30, optimizer 200 runs, via-IR, EVM `cancun`.
`remappings.txt` is the full list the deployed build was compiled with, so the metadata hash and
therefore the bytecode match exactly.

## Licences

`src/venues/PangeaFeeHook.sol`, `src/venues/LiquidityLocker.sol` and the Pangea files they import are
published as source for review and verification; all rights reserved. The files under
`lib/uniswap-v4-core/` are Uniswap Labs' v4-core sources under their own SPDX licences (MIT, and
BUSL-1.1 for `Position.sol`); the files under `lib/openzeppelin-contracts/` are OpenZeppelin's (MIT).
