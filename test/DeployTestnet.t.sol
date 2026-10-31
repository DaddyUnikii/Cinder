// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CinderTestToken} from "../src/testnet/CinderTestToken.sol";

contract CinderTestTokenTest is Test {
    function test_supplyMintedToDeployer() public {
        CinderTestToken t = new CinderTestToken(1_000 ether);
        assertEq(t.balanceOf(address(this)), 1_000 ether);
        assertEq(t.symbol(), "tCNDR");
    }
}
