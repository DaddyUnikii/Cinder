// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CinderFeeSink} from "../src/CinderFeeSink.sol";
import {CinderRouter} from "../src/CinderRouter.sol";
import {CinderStaking} from "../src/CinderStaking.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPancakeRouter} from "./mocks/MockPancakeRouter.sol";

contract CinderFeeSinkTest is Test {
    MockPancakeRouter pancake;
    MockERC20 usdt;
    MockERC20 tokenA;
    MockERC20 wbnb;
    CinderStaking staking;
    CinderFeeSink stakingSink;
    CinderFeeSink burnSink;
    CinderRouter router;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address dead = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        usdt = new MockERC20("Tether", "USDT");
        tokenA = new MockERC20("Token A", "TKA");
        wbnb = new MockERC20("Wrapped BNB", "WBNB");
        pancake = new MockPancakeRouter(address(wbnb));
        vm.deal(address(pancake), 1_000 ether);

        staking = new CinderStaking(IERC20(address(tokenA)), 100 ether);
        stakingSink = new CinderFeeSink(
            IPancakeRouter02(address(pancake)), IERC20(address(tokenA)), CinderFeeSink.Mode.ForwardBNB, address(staking)
        );
        burnSink = new CinderFeeSink(
            IPancakeRouter02(address(pancake)), IERC20(address(tokenA)), CinderFeeSink.Mode.BuyAndBurn, address(0)
        );
        router = new CinderRouter(IPancakeRouter02(address(pancake)), address(burnSink), address(stakingSink), treasury);
        stakingSink.setKeeper(keeper, true);
        burnSink.setKeeper(keeper, true);

        tokenA.mint(alice, 1_000 ether);
        usdt.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        tokenA.approve(address(staking), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        staking.stake(1_000 ether, 0);
        vm.stopPrank();
    }

    function _swapUsdt(uint256 amount) internal {
        address[] memory p = new address[](2);
        p[0] = address(usdt);
        p[1] = address(tokenA);
        vm.prank(alice);
        router.swapExactTokensForTokens(amount, 0, p, address(0), block.timestamp);
    }

    function test_fullLoop_stakersEarnBNB() public {
        _swapUsdt(10_000 ether); // 15 USDT to staking sink
        vm.startPrank(keeper);
        stakingSink.convert(address(usdt), 0, block.timestamp);
        stakingSink.forward();
        vm.stopPrank();
        assertApproxEqAbs(staking.totalPending(alice), 15 ether, 10);
    }

    function test_fullLoop_buybackBurnsTokenA() public {
        _swapUsdt(10_000 ether); // 25 USDT to burn sink
        uint256 deadBefore = tokenA.balanceOf(dead);
        vm.startPrank(keeper);
        burnSink.convert(address(usdt), 0, block.timestamp);
        burnSink.buyAndBurn(0, block.timestamp);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(dead) - deadBefore, 25 ether);
        assertEq(burnSink.totalBurned(), 25 ether);
    }

    function test_tokenAFeesBurnDirectly() public {
        tokenA.mint(address(burnSink), 7 ether);
        vm.prank(keeper);
        burnSink.burnTokenA();
        assertEq(tokenA.balanceOf(dead), 7 ether);
    }

    function test_strangerCannotRunKeeperCalls() public {
        vm.prank(alice);
        vm.expectRevert(CinderFeeSink.NotKeeper.selector);
        burnSink.buyAndBurn(0, block.timestamp);
    }

    function test_wrongModeReverts() public {
        vm.prank(keeper);
        vm.expectRevert(CinderFeeSink.WrongMode.selector);
        stakingSink.buyAndBurn(0, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(CinderFeeSink.WrongMode.selector);
        burnSink.forward();
    }
}
