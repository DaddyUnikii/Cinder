// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Swaps 1:1 by minting the output token. Native output is paid from its own balance.
contract MockPancakeRouter {
    address public immutable WETH;

    constructor(address weth) {
        WETH = weth;
    }

    receive() external payable {}

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        require(amountIn >= amountOutMin, "slippage");
        MockERC20(path[path.length - 1]).mint(to, amountIn);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable {
        require(msg.value >= amountOutMin, "slippage");
        MockERC20(path[path.length - 1]).mint(to, msg.value);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        require(amountIn >= amountOutMin, "slippage");
        (bool ok,) = to.call{value: amountIn}("");
        require(ok, "send");
    }
}
