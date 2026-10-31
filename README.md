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
- `CinderStaking`: stake token A for a share of fees in BNB. Tiers: flexible 1x, 90 days 1.5x, 180 days 2x. 30-day unstake cooldown, or instant exit with 10% burned.
- `CinderFeeSink`: collects a fee share in any token, converts it to BNB in batches, then forwards it to staking or buys token A and burns it.

## Develop

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge install foundry-rs/forge-std --no-git
forge test
```

## Deploy to BSC testnet

Get testnet BNB from https://testnet.bnbchain.org/faucet-smart, import a throwaway deployer key into a Foundry keystore (`cast wallet import deployer --interactive`), then:

```bash
TREASURY=0xYourFeeWallet LP_TOKENS=1000000000000000000000000 LP_BNB=100000000000000000 \
forge script script/DeployTestnet.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --account deployer
```

Never commit a private key. `.env` is gitignored.
