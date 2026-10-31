// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";

/// @title CinderRouter
/// @notice Takes a 0.5% fee from the input of every swap, splits it between the
///         buyback-and-burn vault, the staking vault, the treasury and an optional
///         referrer, then forwards the rest to PancakeSwap. The router never keeps
///         user funds between transactions.
contract CinderRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice Hard cap on the total fee, so it can never be raised above 1%.
    uint256 public constant MAX_FEE_BPS = 100;

    /// @notice Fee split in basis points of the swap amount. Defaults: 25 + 15 + 10 = 50 (0.5%).
    uint16 public burnBps = 25;
    uint16 public stakingBps = 15;
    uint16 public treasuryBps = 10;
    /// @notice Part of the treasury share paid to the referrer, when one is given.
    uint16 public referralBps = 5;

    IPancakeRouter02 public immutable pancake;
    address public immutable WBNB;

    address public buybackVault;
    address public stakingVault;
    address public treasury;

    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 fee,
        address referrer
    );
    event FeesUpdated(uint16 burnBps, uint16 stakingBps, uint16 treasuryBps, uint16 referralBps);
    event RecipientsUpdated(address buybackVault, address stakingVault, address treasury);

    error ZeroAddress();
    error FeeTooHigh();
    error BadPath();
    error SelfReferral();
    error TransferFailed();

    constructor(IPancakeRouter02 pancake_, address buybackVault_, address stakingVault_, address treasury_)
        Ownable(msg.sender)
    {
        if (address(pancake_) == address(0)) revert ZeroAddress();
        pancake = pancake_;
        WBNB = pancake_.WETH();
        _setRecipients(buybackVault_, stakingVault_, treasury_);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function totalFeeBps() public view returns (uint256) {
        return uint256(burnBps) + stakingBps + treasuryBps;
    }

    /// @notice Fee and the amount actually swapped for a given input.
    function quoteFee(uint256 amountIn) external view returns (uint256 fee, uint256 amountAfterFee) {
        fee = (amountIn * totalFeeBps()) / BPS;
        amountAfterFee = amountIn - fee;
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------

    /// @notice Token -> token. Output goes straight from PancakeSwap to the caller.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address referrer,
        uint256 deadline
    ) external nonReentrant {
        if (path.length < 2) revert BadPath();
        IERC20 tokenIn = IERC20(path[0]);
        uint256 received = _pull(tokenIn, amountIn);
        uint256 fee = _takeTokenFee(tokenIn, received, referrer);
        uint256 net = received - fee;

        tokenIn.forceApprove(address(pancake), net);
        pancake.swapExactTokensForTokensSupportingFeeOnTransferTokens(net, amountOutMin, path, msg.sender, deadline);

        emit Swapped(msg.sender, path[0], path[path.length - 1], received, fee, referrer);
    }

    /// @notice BNB -> token.
    function swapExactBNBForTokens(uint256 amountOutMin, address[] calldata path, address referrer, uint256 deadline)
        external
        payable
        nonReentrant
    {
        if (path.length < 2 || path[0] != WBNB) revert BadPath();
        uint256 fee = _takeBNBFee(msg.value, referrer);
        uint256 net = msg.value - fee;

        pancake.swapExactETHForTokensSupportingFeeOnTransferTokens{value: net}(
            amountOutMin, path, msg.sender, deadline
        );

        emit Swapped(msg.sender, address(0), path[path.length - 1], msg.value, fee, referrer);
    }

    /// @notice Token -> BNB.
    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address referrer,
        uint256 deadline
    ) external nonReentrant {
        if (path.length < 2 || path[path.length - 1] != WBNB) revert BadPath();
        IERC20 tokenIn = IERC20(path[0]);
        uint256 received = _pull(tokenIn, amountIn);
        uint256 fee = _takeTokenFee(tokenIn, received, referrer);
        uint256 net = received - fee;

        tokenIn.forceApprove(address(pancake), net);
        pancake.swapExactTokensForETHSupportingFeeOnTransferTokens(net, amountOutMin, path, msg.sender, deadline);

        emit Swapped(msg.sender, path[0], address(0), received, fee, referrer);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setFees(uint16 burnBps_, uint16 stakingBps_, uint16 treasuryBps_, uint16 referralBps_)
        external
        onlyOwner
    {
        if (uint256(burnBps_) + stakingBps_ + treasuryBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (referralBps_ > treasuryBps_) revert FeeTooHigh();
        burnBps = burnBps_;
        stakingBps = stakingBps_;
        treasuryBps = treasuryBps_;
        referralBps = referralBps_;
        emit FeesUpdated(burnBps_, stakingBps_, treasuryBps_, referralBps_);
    }

    function setRecipients(address buybackVault_, address stakingVault_, address treasury_) external onlyOwner {
        _setRecipients(buybackVault_, stakingVault_, treasury_);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _setRecipients(address b, address s, address t) internal {
        if (b == address(0) || s == address(0) || t == address(0)) revert ZeroAddress();
        buybackVault = b;
        stakingVault = s;
        treasury = t;
        emit RecipientsUpdated(b, s, t);
    }

    /// @dev Pulls tokens and returns what actually arrived (handles fee-on-transfer tokens).
    function _pull(IERC20 token, uint256 amount) internal returns (uint256) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        return token.balanceOf(address(this)) - before;
    }

    function _split(uint256 amount, address referrer)
        internal
        view
        returns (uint256 toBurn, uint256 toStaking, uint256 toTreasury, uint256 toReferrer)
    {
        if (referrer == msg.sender) revert SelfReferral();
        toBurn = (amount * burnBps) / BPS;
        toStaking = (amount * stakingBps) / BPS;
        toTreasury = (amount * treasuryBps) / BPS;
        if (referrer != address(0)) {
            toReferrer = (amount * referralBps) / BPS;
            toTreasury -= toReferrer;
        }
    }

    function _takeTokenFee(IERC20 token, uint256 amount, address referrer) internal returns (uint256 fee) {
        (uint256 b, uint256 s, uint256 t, uint256 r) = _split(amount, referrer);
        if (b > 0) token.safeTransfer(buybackVault, b);
        if (s > 0) token.safeTransfer(stakingVault, s);
        if (t > 0) token.safeTransfer(treasury, t);
        if (r > 0) token.safeTransfer(referrer, r);
        fee = b + s + t + r;
    }

    function _takeBNBFee(uint256 amount, address referrer) internal returns (uint256 fee) {
        (uint256 b, uint256 s, uint256 t, uint256 r) = _split(amount, referrer);
        _sendBNB(buybackVault, b);
        _sendBNB(stakingVault, s);
        _sendBNB(treasury, t);
        _sendBNB(referrer, r);
        fee = b + s + t + r;
    }

    function _sendBNB(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
