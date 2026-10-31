#!/usr/bin/env bash
# Cinder keeper: turns accumulated fees into burns and staker rewards.
# Usage: RPC=... KEEPER_ARGS="--keystore <file> --password-file <file>" scripts/keeper.sh deployments/bsc-testnet.json
# Any wallet registered with setKeeper (or the sink owner) can run it.
set -euo pipefail
CFG=${1:-deployments/bsc-testnet.json}
RPC=${RPC:?set RPC}
SLIPPAGE_BPS=${SLIPPAGE_BPS:-300}       # 3% max slippage on keeper swaps
MIN_BNB=${MIN_BNB:-10000000000000}      # skip dust below 0.00001 BNB
j() { jq -r ".$1" "$CFG"; }
PANCAKE=$(j pancakeRouterV2); WBNB=$(j WBNB); TOKEN=$(j tokenA)
STAKE_SINK=$(j stakingSink); BURN_SINK=$(j burnSink)
DEADLINE=$(( $(date +%s) + 600 ))

send() { echo "> $*"; cast send "$@" --rpc-url "$RPC" $KEEPER_ARGS --json | jq -r '"  status=\(.status) tx=\(.transactionHash)"'; }
quote() { # quote <amountIn> <from> <to> -> min out after slippage
  local out; out=$(cast call "$PANCAKE" "getAmountsOut(uint256,address[])(uint256[])" "$1" "[$2,$3]" --rpc-url "$RPC" --json | python3 -c "import sys,json; print(int(json.load(sys.stdin, parse_float=str)[0][-1]))")
  python3 -c "print($out * (10000 - $SLIPPAGE_BPS) // 10000)"
}
bal() { cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | awk '{print $1}'; }
bnb() { cast balance "$1" --rpc-url "$RPC"; }

# 1. Staking sink: token A fees -> BNB, then all BNB -> staking contract.
t=$(bal "$STAKE_SINK")
if [ "$t" != "0" ]; then send "$STAKE_SINK" "convert(address,uint256,uint256)" "$TOKEN" "$(quote "$t" "$TOKEN" "$WBNB")" "$DEADLINE"; fi
b=$(bnb "$STAKE_SINK")
if python3 -c "exit(0 if $b >= $MIN_BNB else 1)"; then send "$STAKE_SINK" "forward()"; else echo "staking sink: nothing to forward"; fi

# 2. Burn sink: token A fees burned directly, BNB fees buy token A and burn it.
t=$(bal "$BURN_SINK")
if [ "$t" != "0" ]; then send "$BURN_SINK" "burnTokenA()"; fi
b=$(bnb "$BURN_SINK")
if python3 -c "exit(0 if $b >= $MIN_BNB else 1)"; then send "$BURN_SINK" "buyAndBurn(uint256,uint256)" "$(quote "$b" "$WBNB" "$TOKEN")" "$DEADLINE"; else echo "burn sink: nothing to buy"; fi

echo "total burned: $(cast call "$BURN_SINK" "totalBurned()(uint256)" --rpc-url "$RPC")"
