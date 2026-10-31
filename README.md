# Cinder

Swap aggregator on BNB Chain where every swap feeds the fire.

Each swap pays a 0.5% fee:
- 0.25% buys back token A and burns it
- 0.15% goes to token A stakers, paid in BNB
- 0.10% goes to the treasury (referrers earn 0.05% of this)

Liquidity comes from PancakeSwap. Cinder holds no pools.

> Status: early development, testnet only. Not audited. Do not use with real funds.

## Contracts

- `CinderRouter`: takes the fee from the swap input, splits it, forwards the rest to PancakeSwap V2. Fee is hard-capped at 1%.

## Develop

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge install foundry-rs/forge-std --no-git
forge test
```
