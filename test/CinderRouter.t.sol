// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CinderRouter} from "../src/CinderRouter.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPancakeRouter} from "./mocks/MockPancakeRouter.sol";

contract CinderRouterTest is Test {
    CinderRouter router;
    MockPancakeRouter pancake;
    MockERC20 usdt;
    MockERC20 tokenA;
    MockERC20 wbnb;

    address buyback = makeAddr("buyback");
    address staking = makeAddr("staking");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address ref = makeAddr("ref");

    function setUp() public {
        usdt = new MockERC20("Tether", "USDT");
        tokenA = new MockERC20("Token A", "TKA");
        wbnb = new MockERC20("Wrapped BNB", "WBNB");
        pancake = new MockPancakeRouter(address(wbnb));
        router = new CinderRouter(IPancakeRouter02(address(pancake)), buyback, staking, treasury);

        usdt.mint(alice, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(address(pancake), 100 ether);
        vm.prank(alice);
        usdt.approve(address(router), type(uint256).max);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function test_defaultFeeIsHalfPercent() public view {
        assertEq(router.totalFeeBps(), 50);
        (uint256 fee, uint256 net) = router.quoteFee(1_000 ether);
        assertEq(fee, 5 ether);
        assertEq(net, 995 ether);
    }

    function test_tokenSwapSplitsFee() public {
        vm.prank(alice);
        router.swapExactTokensForTokens(1_000 ether, 0, _path(address(usdt), address(tokenA)), address(0), block.timestamp);

        assertEq(usdt.balanceOf(buyback), 2.5 ether);
        assertEq(usdt.balanceOf(staking), 1.5 ether);
        assertEq(usdt.balanceOf(treasury), 1 ether);
        assertEq(tokenA.balanceOf(alice), 995 ether);
        assertEq(usdt.balanceOf(address(router)), 0);
    }

    function test_referrerTakesPartOfTreasuryShare() public {
        vm.prank(alice);
        router.swapExactTokensForTokens(1_000 ether, 0, _path(address(usdt), address(tokenA)), ref, block.timestamp);

        assertEq(usdt.balanceOf(ref), 0.5 ether);
        assertEq(usdt.balanceOf(treasury), 0.5 ether);
        assertEq(usdt.balanceOf(buyback), 2.5 ether);
        assertEq(usdt.balanceOf(staking), 1.5 ether);
    }

    function test_selfReferralReverts() public {
        vm.prank(alice);
        vm.expectRevert(CinderRouter.SelfReferral.selector);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(usdt), address(tokenA)), alice, block.timestamp);
    }

    function test_bnbSwapSplitsFee() public {
        vm.prank(alice);
        router.swapExactBNBForTokens{value: 1 ether}(0, _path(address(wbnb), address(tokenA)), address(0), block.timestamp);

        assertEq(buyback.balance, 0.0025 ether);
        assertEq(staking.balance, 0.0015 ether);
        assertEq(treasury.balance, 0.001 ether);
        assertEq(tokenA.balanceOf(alice), 0.995 ether);
        assertEq(address(router).balance, 0);
    }

    function test_tokenToBNBSplitsFee() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        router.swapExactTokensForBNB(100 ether, 0, _path(address(usdt), address(wbnb)), address(0), block.timestamp);

        assertEq(alice.balance - before, 99.5 ether);
        assertEq(usdt.balanceOf(buyback), 0.25 ether);
    }

    function test_badPathReverts() public {
        vm.prank(alice);
        vm.expectRevert(CinderRouter.BadPath.selector);
        router.swapExactBNBForTokens{value: 1 ether}(0, _path(address(usdt), address(tokenA)), address(0), block.timestamp);
    }

    function test_feeCappedAtOnePercent() public {
        vm.expectRevert(CinderRouter.FeeTooHigh.selector);
        router.setFees(60, 30, 20, 5);
    }

    function test_onlyOwnerCanChangeFees() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setFees(25, 15, 10, 5);
    }

    function testFuzz_feeNeverExceedsHalfPercent(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 1_000 ether);
        vm.prank(alice);
        router.swapExactTokensForTokens(amount, 0, _path(address(usdt), address(tokenA)), ref, block.timestamp);
        uint256 fee = usdt.balanceOf(buyback) + usdt.balanceOf(staking) + usdt.balanceOf(treasury) + usdt.balanceOf(ref);
        assertLe(fee, (uint256(amount) * 50) / 10_000);
        assertEq(tokenA.balanceOf(alice) + fee, amount);
    }
}
