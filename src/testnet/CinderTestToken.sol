// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for token A on BSC testnet. Fixed supply minted to the deployer.
contract CinderTestToken is ERC20 {
    constructor(uint256 supply) ERC20("Cinder Test Token", "tCNDR") {
        _mint(msg.sender, supply);
    }
}
