// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CinderStaking
/// @notice Stake token A, earn the stakers' share of swap fees in BNB.
///         - Lock tiers: flexible (1x), 90 days (1.5x), 180 days (2x).
///         - Normal exit: request unstake after the lock ends, wait 30 days, withdraw.
///           Rewards stop during the cooldown.
///         - Instant exit at any time: 10% of the stake is burned.
contract CinderStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant COOLDOWN = 30 days;
    uint256 public constant PENALTY_BPS = 1_000; // 10%
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable token;
    /// @notice Minimum stake in token units. Kept near $100 by the owner.
    uint256 public minStake;

    uint256 public totalWeight;
    uint256 public accRewardPerWeight;
    /// @notice BNB received while nobody was staking, paid out with the next deposit.
    uint256 public queuedReward;

    struct Position {
        uint128 amount;
        uint128 weight;
        uint64 lockEnd;
        uint64 cooldownEnd; // 0 = not unstaking
        uint256 rewardDebt;
        uint256 pending;
    }

    mapping(address => Position[]) public positions;

    event Staked(address indexed user, uint256 indexed id, uint256 amount, uint8 tier);
    event UnstakeRequested(address indexed user, uint256 indexed id, uint256 cooldownEnd);
    event Withdrawn(address indexed user, uint256 indexed id, uint256 amount);
    event InstantExit(address indexed user, uint256 indexed id, uint256 returned, uint256 burned);
    event Claimed(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);
    event MinStakeUpdated(uint256 minStake);

    error BelowMinimum();
    error BadTier();
    error Locked();
    error NotUnstaking();
    error CooldownActive();
    error AlreadyUnstaking();
    error Closed();
    error TransferFailed();

    constructor(IERC20 token_, uint256 minStake_) Ownable(msg.sender) {
        token = token_;
        minStake = minStake_;
    }

    // ------------------------------------------------------------------
    // Rewards in
    // ------------------------------------------------------------------

    receive() external payable {
        _addReward(msg.value);
    }

    function _addReward(uint256 amount) internal {
        if (amount == 0) return;
        if (totalWeight == 0) {
            queuedReward += amount;
        } else {
            accRewardPerWeight += (amount * PRECISION) / totalWeight;
        }
        emit RewardAdded(amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function tierInfo(uint8 tier) public pure returns (uint64 lockDays, uint16 multiplierBps) {
        if (tier == 0) return (0, 10_000);
        if (tier == 1) return (90, 15_000);
        if (tier == 2) return (180, 20_000);
        revert BadTier();
    }

    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function pendingReward(address user, uint256 id) public view returns (uint256) {
        Position storage p = positions[user][id];
        return p.pending + (uint256(p.weight) * accRewardPerWeight) / PRECISION - p.rewardDebt;
    }

    function totalPending(address user) external view returns (uint256 sum) {
        uint256 n = positions[user].length;
        for (uint256 i; i < n; ++i) sum += pendingReward(user, i);
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function stake(uint256 amount, uint8 tier) external nonReentrant returns (uint256 id) {
        if (amount < minStake) revert BelowMinimum();
        (uint64 lockDays, uint16 mult) = tierInfo(tier);

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received < minStake) revert BelowMinimum();

        uint256 weight = (received * mult) / 10_000;
        totalWeight += weight;

        id = positions[msg.sender].length;
        positions[msg.sender].push(
            Position({
                amount: uint128(received),
                weight: uint128(weight),
                lockEnd: uint64(block.timestamp + uint256(lockDays) * 1 days),
                cooldownEnd: 0,
                rewardDebt: (weight * accRewardPerWeight) / PRECISION,
                pending: 0
            })
        );
        emit Staked(msg.sender, id, received, tier);

        // Rewards that arrived while nobody was staking go to the stakers present now.
        if (queuedReward > 0) {
            accRewardPerWeight += (queuedReward * PRECISION) / totalWeight;
            queuedReward = 0;
        }
    }

    /// @notice Start the 30-day cooldown. Rewards stop from now.
    function requestUnstake(uint256 id) external nonReentrant {
        Position storage p = _open(msg.sender, id);
        if (p.cooldownEnd != 0) revert AlreadyUnstaking();
        if (block.timestamp < p.lockEnd) revert Locked();
        _settle(p);
        totalWeight -= p.weight;
        p.weight = 0;
        p.rewardDebt = 0;
        p.cooldownEnd = uint64(block.timestamp + COOLDOWN);
        emit UnstakeRequested(msg.sender, id, p.cooldownEnd);
    }

    function withdraw(uint256 id) external nonReentrant {
        Position storage p = _open(msg.sender, id);
        if (p.cooldownEnd == 0) revert NotUnstaking();
        if (block.timestamp < p.cooldownEnd) revert CooldownActive();
        uint256 amount = p.amount;
        uint256 reward = p.pending;
        p.amount = 0;
        p.pending = 0;
        token.safeTransfer(msg.sender, amount);
        _sendBNB(msg.sender, reward);
        emit Withdrawn(msg.sender, id, amount);
        if (reward > 0) emit Claimed(msg.sender, reward);
    }

    /// @notice Leave now, from any state. 10% of the stake is burned; earned rewards are kept.
    function instantExit(uint256 id) external nonReentrant {
        Position storage p = _open(msg.sender, id);
        if (p.weight > 0) {
            _settle(p);
            totalWeight -= p.weight;
            p.weight = 0;
            p.rewardDebt = 0;
        }
        uint256 amount = p.amount;
        uint256 burned = (amount * PENALTY_BPS) / 10_000;
        uint256 reward = p.pending;
        p.amount = 0;
        p.pending = 0;
        token.safeTransfer(DEAD, burned);
        token.safeTransfer(msg.sender, amount - burned);
        _sendBNB(msg.sender, reward);
        emit InstantExit(msg.sender, id, amount - burned, burned);
        if (reward > 0) emit Claimed(msg.sender, reward);
    }

    function claim() external nonReentrant {
        Position[] storage list = positions[msg.sender];
        uint256 total;
        for (uint256 i; i < list.length; ++i) {
            Position storage p = list[i];
            if (p.amount == 0) continue;
            _settle(p);
            total += p.pending;
            p.pending = 0;
        }
        _sendBNB(msg.sender, total);
        emit Claimed(msg.sender, total);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setMinStake(uint256 minStake_) external onlyOwner {
        minStake = minStake_;
        emit MinStakeUpdated(minStake_);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _open(address user, uint256 id) internal view returns (Position storage p) {
        p = positions[user][id];
        if (p.amount == 0) revert Closed();
    }

    function _settle(Position storage p) internal {
        uint256 accrued = (uint256(p.weight) * accRewardPerWeight) / PRECISION;
        p.pending += accrued - p.rewardDebt;
        p.rewardDebt = accrued;
    }

    function _sendBNB(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
