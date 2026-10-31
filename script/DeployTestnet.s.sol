// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CinderRouter} from "../src/CinderRouter.sol";
import {CinderStaking} from "../src/CinderStaking.sol";
import {CinderFeeSink} from "../src/CinderFeeSink.sol";
import {CinderTestToken} from "../src/testnet/CinderTestToken.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";

interface IPancakeLiquidity {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

/// @notice Deploys the full Cinder stack on BSC testnet (chain 97).
///
/// forge script script/DeployTestnet.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
///   --broadcast --account <keystore-name>
///
/// Env:
///   TREASURY       fee wallet for the 0.10% share (required)
///   TOKEN_A        existing token A; if unset a test token is deployed
///   MIN_STAKE      minimum stake in token units (default 100e18)
///   LP_TOKENS      token A to seed a token A/WBNB pool with (default 0 = skip)
///   LP_BNB         testnet BNB for that pool, in wei (default 0 = skip)
contract DeployTestnet is Script {
    /// PancakeSwap V2 router on BSC testnet.
    address constant PANCAKE_TESTNET = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    function run() external {
        address treasury = vm.envAddress("TREASURY");
        address tokenA = vm.envOr("TOKEN_A", address(0));
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(100 ether));
        uint256 lpTokens = vm.envOr("LP_TOKENS", uint256(0));
        uint256 lpBnb = vm.envOr("LP_BNB", uint256(0));

        IPancakeRouter02 pancake = IPancakeRouter02(PANCAKE_TESTNET);

        vm.startBroadcast();

        if (tokenA == address(0)) {
            tokenA = address(new CinderTestToken(1_000_000_000 ether));
        }

        CinderStaking staking = new CinderStaking(IERC20(tokenA), minStake);
        CinderFeeSink stakingSink =
            new CinderFeeSink(pancake, IERC20(tokenA), CinderFeeSink.Mode.ForwardBNB, address(staking));
        CinderFeeSink burnSink = new CinderFeeSink(pancake, IERC20(tokenA), CinderFeeSink.Mode.BuyAndBurn, address(0));
        CinderRouter router = new CinderRouter(pancake, address(burnSink), address(stakingSink), treasury);

        if (lpTokens > 0 && lpBnb > 0) {
            IERC20(tokenA).approve(PANCAKE_TESTNET, lpTokens);
            IPancakeLiquidity(PANCAKE_TESTNET).addLiquidityETH{value: lpBnb}(
                tokenA, lpTokens, 0, 0, msg.sender, block.timestamp + 600
            );
        }

        vm.stopBroadcast();

        console2.log("tokenA      ", tokenA);
        console2.log("staking     ", address(staking));
        console2.log("stakingSink ", address(stakingSink));
        console2.log("burnSink    ", address(burnSink));
        console2.log("router      ", address(router));
    }
}
