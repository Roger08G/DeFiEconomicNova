// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SynthToken.sol";

/**
 * @title MultiPoolRewards
 * @notice Multi-pool liquidity mining contract for the NovaSynth protocol.
 * @dev    Each pool tracks its own stake token, per-second reward rate, and
 *         a monotonically increasing accumulator (`accRewardPerShare`) that
 *         represents cumulative rewards per staked token since pool creation.
 *
 *         Architecture follows the MasterChef v1 pattern:
 *         - `accRewardPerShare` is updated lazily on every user interaction.
 *         - A user's claimable reward = `amount × accRewardPerShare - rewardDebt`.
 *         - `rewardDebt` is snapshotted at each deposit/withdrawal to isolate
 *           only the rewards accrued during the user's own staking period.
 *
 *         The owner may add pools via {addPool} and adjust per-pool reward
 *         emission rates via {setPoolRewardRate} at any time. Stake tokens and
 *         the reward token ({SynthToken}) must be pre-approved by callers.
 *
 * @custom:security-contact security@novasynth.fi
 */
contract MultiPoolRewards {
    SynthToken public rewardToken;
    address public owner;

    struct PoolInfo {
        SynthToken stakeToken;
        uint256 totalStaked;
        uint256 rewardPerSecond;
        uint256 accRewardPerShare; // Cumulative rewards per staked token, scaled by ACC_PRECISION
        uint256 lastRewardTime;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt; // accRewardPerShare at last user action
    }

    // Pool registry (append-only)
    PoolInfo[] public pools;
    // poolId => user => info
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    uint256 public constant ACC_PRECISION = 1e12;

    event PoolAdded(uint256 indexed pid, address stakeToken, uint256 rewardPerSecond);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Unstaked(uint256 indexed pid, address indexed user, uint256 amount);
    event Claimed(uint256 indexed pid, address indexed user, uint256 reward);
    event RewardRateChanged(uint256 indexed pid, uint256 oldRate, uint256 newRate);

    modifier onlyOwner() {
        require(msg.sender == owner, "MultiPool: not owner");
        _;
    }

    constructor(address _rewardToken) {
        rewardToken = SynthToken(_rewardToken);
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Register a new staking pool.
     * @dev    Initialises `lastRewardTime` to the current timestamp so the
     *         accumulator begins accruing from the moment the pool is live.
     *         Only the owner may call this function.
     * @param  _stakeToken       Address of the ERC-20 token users will stake.
     * @param  _rewardPerSecond  Initial reward emission rate in SYNTH per second.
     */
    function addPool(address _stakeToken, uint256 _rewardPerSecond) external onlyOwner {
        pools.push(
            PoolInfo({
                stakeToken: SynthToken(_stakeToken),
                totalStaked: 0,
                rewardPerSecond: _rewardPerSecond,
                accRewardPerShare: 0,
                lastRewardTime: block.timestamp
            })
        );

        emit PoolAdded(pools.length - 1, _stakeToken, _rewardPerSecond);
    }

    /**
     * @notice Update the reward emission rate for pool `pid`.
     * @dev    Applies the new rate immediately; the accumulator is not
     *         settled prior to the change. Only the owner may call this.
     * @param  pid      Index of the pool to update.
     * @param  newRate  New reward emission rate in SYNTH per second.
     */
    function setPoolRewardRate(uint256 pid, uint256 newRate) external onlyOwner {
        uint256 oldRate = pools[pid].rewardPerSecond;
        pools[pid].rewardPerSecond = newRate;
        emit RewardRateChanged(pid, oldRate, newRate);
    }

    // ═══════════════════════════════════════════════════════════════
    // STAKING
    // ═══════════════════════════════════════════════════════════════

    function stake(uint256 pid, uint256 amount) external {
        require(pid < pools.length, "MultiPool: invalid pool");
        require(amount > 0, "MultiPool: zero amount");

        // Synchronise all pool accumulators before modifying state
        massUpdatePools();

        PoolInfo storage pool = pools[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        // Settle pending rewards
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
            if (pending > 0) {
                rewardToken.transfer(msg.sender, pending);
                emit Claimed(pid, msg.sender, pending);
            }
        }

        pool.stakeToken.transferFrom(msg.sender, address(this), amount);
        user.amount += amount;
        pool.totalStaked += amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;

        emit Staked(pid, msg.sender, amount);
    }

    function unstake(uint256 pid, uint256 amount) external {
        require(pid < pools.length, "MultiPool: invalid pool");
        UserInfo storage user = userInfo[pid][msg.sender];
        require(user.amount >= amount, "MultiPool: insufficient stake");

        // Synchronise all pool accumulators before modifying state
        massUpdatePools();

        PoolInfo storage pool = pools[pid];

        // Settle pending
        uint256 pending = (user.amount * pool.accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        if (pending > 0) {
            rewardToken.transfer(msg.sender, pending);
            emit Claimed(pid, msg.sender, pending);
        }

        user.amount -= amount;
        pool.totalStaked -= amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;

        pool.stakeToken.transfer(msg.sender, amount);

        emit Unstaked(pid, msg.sender, amount);
    }

    function claim(uint256 pid) external {
        require(pid < pools.length, "MultiPool: invalid pool");

        _updatePool(pid);

        PoolInfo storage pool = pools[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        uint256 pending = (user.amount * pool.accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;

        if (pending > 0) {
            rewardToken.transfer(msg.sender, pending);
            emit Claimed(pid, msg.sender, pending);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // POOL UPDATES
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Advance the accumulator for every registered pool.
     * @dev    Called automatically by {stake} and {unstake} to ensure all
     *         pools are up-to-date before any user state is modified.
     *         Gas cost scales linearly with the number of registered pools.
     */
    function massUpdatePools() public {
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; pid++) {
            _updatePool(pid);
        }
    }

    function _updatePool(uint256 pid) internal {
        PoolInfo storage pool = pools[pid];

        if (block.timestamp <= pool.lastRewardTime) return;
        if (pool.totalStaked == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - pool.lastRewardTime;
        uint256 reward = elapsed * pool.rewardPerSecond;

        pool.accRewardPerShare += (reward * ACC_PRECISION) / pool.totalStaked;
        pool.lastRewardTime = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function pendingReward(uint256 pid, address account) external view returns (uint256) {
        PoolInfo storage pool = pools[pid];
        UserInfo storage user = userInfo[pid][account];

        uint256 accReward = pool.accRewardPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward = elapsed * pool.rewardPerSecond;
            accReward += (reward * ACC_PRECISION) / pool.totalStaked;
        }

        return (user.amount * accReward) / ACC_PRECISION - user.rewardDebt;
    }

    function getPoolInfo(uint256 pid)
        external
        view
        returns (address stakeToken, uint256 totalStaked, uint256 rewardPerSecond, uint256 accRewardPerShare)
    {
        PoolInfo storage pool = pools[pid];
        return (address(pool.stakeToken), pool.totalStaked, pool.rewardPerSecond, pool.accRewardPerShare);
    }
}
