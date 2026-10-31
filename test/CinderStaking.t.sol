// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CinderStaking} from "../src/CinderStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CinderStakingTest is Test {
    CinderStaking staking;
    MockERC20 tokenA;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeSource = makeAddr("router");

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA");
        staking = new CinderStaking(IERC20(address(tokenA)), 100 ether);
        for (uint256 i; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            tokenA.mint(u, 10_000 ether);
            vm.prank(u);
            tokenA.approve(address(staking), type(uint256).max);
        }
        vm.deal(feeSource, 100 ether);
    }

    function _reward(uint256 amount) internal {
        vm.prank(feeSource);
        (bool ok,) = address(staking).call{value: amount}("");
        assertTrue(ok);
    }

    function test_belowMinimumReverts() public {
        vm.prank(alice);
        vm.expectRevert(CinderStaking.BelowMinimum.selector);
        staking.stake(99 ether, 0);
    }

    function test_rewardsSplitByWeight() public {
        vm.prank(alice);
        staking.stake(1_000 ether, 0); // weight 1000
        vm.prank(bob);
        staking.stake(1_000 ether, 2); // weight 2000
        _reward(3 ether);
        assertApproxEqAbs(staking.totalPending(alice), 1 ether, 10);
        assertApproxEqAbs(staking.totalPending(bob), 2 ether, 10);
    }

    function test_queuedRewardGoesToFirstStaker() public {
        _reward(1 ether);
        vm.prank(alice);
        staking.stake(500 ether, 0);
        assertApproxEqAbs(staking.totalPending(alice), 1 ether, 10);
    }

    function test_claimPaysBNB() public {
        vm.prank(alice);
        staking.stake(1_000 ether, 0);
        _reward(1 ether);
        vm.prank(alice);
        staking.claim();
        assertApproxEqAbs(alice.balance, 1 ether, 10);
        assertEq(staking.totalPending(alice), 0);
    }

    function test_lockedPositionCannotRequestUnstake() public {
        vm.prank(alice);
        staking.stake(1_000 ether, 1);
        vm.prank(alice);
        vm.expectRevert(CinderStaking.Locked.selector);
        staking.requestUnstake(0);
        vm.warp(block.timestamp + 90 days);
        vm.prank(alice);
        staking.requestUnstake(0);
    }

    function test_cooldownStopsRewardsAndTakes30Days() public {
        vm.prank(alice);
        staking.stake(1_000 ether, 0);
        vm.prank(bob);
        staking.stake(1_000 ether, 0);
        _reward(2 ether);

        vm.prank(alice);
        staking.requestUnstake(0);
        _reward(2 ether); // all to bob now

        assertApproxEqAbs(staking.totalPending(alice), 1 ether, 10);
        assertApproxEqAbs(staking.totalPending(bob), 3 ether, 10);

        vm.prank(alice);
        vm.expectRevert(CinderStaking.CooldownActive.selector);
        staking.withdraw(0);

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        staking.withdraw(0);
        assertEq(tokenA.balanceOf(alice), 10_000 ether);
        assertApproxEqAbs(alice.balance, 1 ether, 10);
    }

    function test_instantExitBurnsTenPercent() public {
        vm.prank(alice);
        staking.stake(1_000 ether, 2);
        _reward(1 ether);
        vm.prank(alice);
        staking.instantExit(0);
        assertEq(tokenA.balanceOf(staking.DEAD()), 100 ether);
        assertEq(tokenA.balanceOf(alice), 9_900 ether);
        assertApproxEqAbs(alice.balance, 1 ether, 10);
        assertEq(staking.totalWeight(), 0);
    }

    function test_closedPositionReverts() public {
        vm.prank(alice);
        staking.stake(1_000 ether, 0);
        vm.prank(alice);
        staking.instantExit(0);
        vm.prank(alice);
        vm.expectRevert(CinderStaking.Closed.selector);
        staking.instantExit(0);
    }

    function test_badTierReverts() public {
        vm.prank(alice);
        vm.expectRevert(CinderStaking.BadTier.selector);
        staking.stake(1_000 ether, 3);
    }
}
