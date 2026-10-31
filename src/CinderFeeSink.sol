// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";

/// @title CinderFeeSink
/// @notice Collects one fee share from CinderRouter in any token, converts it to BNB in
///         batches, then either forwards the BNB (staking share) or buys token A and
///         burns it (buyback share). Batching keeps gas off every swap and makes each
///         buyback large enough to be worth it.
contract CinderFeeSink is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Mode {
        ForwardBNB,
        BuyAndBurn
    }

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPancakeRouter02 public immutable pancake;
    address public immutable WBNB;
    IERC20 public immutable tokenA;
    Mode public immutable mode;
    /// @notice Where BNB goes in ForwardBNB mode (the staking contract).
    address public target;

    mapping(address => bool) public keepers;
    uint256 public totalBurned;

    event Converted(address indexed token, uint256 amountIn, uint256 bnbOut);
    event Forwarded(address indexed target, uint256 amount);
    event BoughtAndBurned(uint256 bnbIn, uint256 tokenABurned);
    event KeeperSet(address indexed keeper, bool allowed);
    event TargetSet(address indexed target);

    error NotKeeper();
    error WrongMode();
    error ZeroAddress();
    error TransferFailed();

    modifier onlyKeeper() {
        if (!keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(IPancakeRouter02 pancake_, IERC20 tokenA_, Mode mode_, address target_) Ownable(msg.sender) {
        if (address(pancake_) == address(0) || address(tokenA_) == address(0)) revert ZeroAddress();
        if (mode_ == Mode.ForwardBNB && target_ == address(0)) revert ZeroAddress();
        pancake = pancake_;
        WBNB = pancake_.WETH();
        tokenA = tokenA_;
        mode = mode_;
        target = target_;
    }

    receive() external payable {}

    /// @notice Swap the whole balance of `token` to BNB.
    function convert(address token, uint256 minBnbOut, uint256 deadline) external onlyKeeper nonReentrant {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;
        uint256 before = address(this).balance;
        IERC20(token).forceApprove(address(pancake), amount);
        pancake.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, minBnbOut, path, address(this), deadline);
        emit Converted(token, amount, address(this).balance - before);
    }

    /// @notice ForwardBNB: send all BNB to the staking contract.
    function forward() external onlyKeeper nonReentrant {
        if (mode != Mode.ForwardBNB) revert WrongMode();
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        (bool ok,) = target.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Forwarded(target, amount);
    }

    /// @notice BuyAndBurn: buy token A with all BNB and send it straight to the dead address.
    function buyAndBurn(uint256 minTokenOut, uint256 deadline) external onlyKeeper nonReentrant {
        if (mode != Mode.BuyAndBurn) revert WrongMode();
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(tokenA);
        uint256 before = tokenA.balanceOf(DEAD);
        pancake.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(minTokenOut, path, DEAD, deadline);
        uint256 burned = tokenA.balanceOf(DEAD) - before;
        totalBurned += burned;
        emit BoughtAndBurned(amount, burned);
    }

    /// @notice BuyAndBurn: fees already paid in token A are burned without a swap.
    function burnTokenA() external onlyKeeper nonReentrant {
        if (mode != Mode.BuyAndBurn) revert WrongMode();
        uint256 amount = tokenA.balanceOf(address(this));
        if (amount == 0) return;
        tokenA.safeTransfer(DEAD, amount);
        totalBurned += amount;
        emit BoughtAndBurned(0, amount);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setTarget(address target_) external onlyOwner {
        if (target_ == address(0)) revert ZeroAddress();
        target = target_;
        emit TargetSet(target_);
    }
}
