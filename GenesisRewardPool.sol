// SPDX-License-Identifier: MIT

/**
 * @title GenesisRewardPool
 * @notice A short-term reward pool to bootstrap the initial supply of the peg token
 * @dev This contract runs for 7 days and allows users to stake tokens to earn peg token rewards
 */
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract GenesisRewardPool is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /**
     * @dev Address that can perform administrative functions
     */
    address public operator;

    /**
     * @dev Info structure for each user in a specific pool
     * @param amount How many LP tokens the user has provided
     * @param rewardDebt Used to calculate the correct reward amount
     */
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    /**
     * @dev Info structure for each reward pool
     * @param token Token that can be staked in this pool
     * @param depFee Deposit fee charged when users deposit tokens (in basis points)
     * @param allocPoint Allocation points assigned to this pool, determines reward distribution
     * @param lastRewardTime Last timestamp when rewards were distributed
     * @param accRewardsPerShare Accumulated rewards per share, times 1e18
     * @param isStarted Flag indicating if rewards have started for this pool
     * @param totalStaked Total tokens staked in this pool
     */
    struct PoolInfo {
        IERC20 token;
        uint256 depFee;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accRewardsPerShare;
        bool isStarted;
        uint256 totalStaked;
    }

    /**
     * @dev Duration of the genesis pool
     */
    uint256 public immutable RUNNING_TIME;

    /**
     * @dev The reward token
     */
    IERC20 public rewardToken;

    /**
     * @dev Development fund that receives fees
     */
    address public devFund;

    /**
     * @dev Array of all reward pools
     */
    PoolInfo[] public poolInfo;

    /**
     * @dev Mapping of user info for each pool
     */
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /**
     * @dev Total allocation points among all pools
     */
    uint256 public totalAllocPoint = 0;

    /**
     * @dev The time when reward mining starts
     */
    uint256 public poolStartTime;

    /**
     * @dev The time when reward mining ends
     */
    uint256 public poolEndTime;

    /**
     * @dev Total rewards distributed per second
     */
    uint256 public totalRewards;

    /**
     * @dev Rewards tokens distributed per second
     */
    uint256 public rewardsPerSecond;

    /**
     * @dev Emitted when a user deposits tokens
     */
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    /**
     * @dev Emitted when a user withdraws tokens
     */
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /**
     * @dev Emitted when a user performs an emergency withdrawal
     */
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /**
     * @dev Emitted when rewards are paid to a user
     */
    event RewardPaid(address indexed user, uint256 amount);

    /**
     * @dev Emitted when a new pool is added
     */
    event PoolAdded(uint256 indexed pid, address indexed token, uint256 allocPoint, uint256 depFee);

    /**
     * @dev Emitted when pool parameters are updated
     */
    event PoolUpdated(
        uint256 indexed pid, uint256 oldAllocPoint, uint256 newAllocPoint, uint256 oldDepFee, uint256 newDepFee
    );

    /**
     * @dev Emitted when dev fund address is updated
     */
    event DevFundUpdated(address indexed oldDevFund, address indexed newDevFund);

    /**
     * @dev Emitted when operator is updated
     */
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    /**
     * @dev Emitted when tokens are recovered
     */
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @dev Constructor to initialize the genesis reward pool
     * @param _rewardToken Address of the rewardToken
     * @param _devFund Address that receives fees
     * @param _poolStartTime Unix timestamp when the reward distribution starts
     * @param _runningTime The duration in seconds how long the pool is going to run
     */
    constructor(address _rewardToken, address _devFund, uint256 _poolStartTime, uint256 _runningTime) {
        require(block.timestamp < _poolStartTime, "pool cannot be started in the past");
        if (_rewardToken != address(0)) rewardToken = IERC20(_rewardToken);
        if (_devFund != address(0)) devFund = _devFund;

        RUNNING_TIME = _runningTime;

        poolStartTime = _poolStartTime;
        poolEndTime = _poolStartTime + _runningTime;
        operator = msg.sender;
        devFund = _devFund;
    }

    /**
     * @dev Modifier to restrict functions to the operator
     */
    modifier onlyOperator() {
        require(operator == msg.sender, "GenesisRewardPool: caller is not the operator");
        _;
    }

    /**
     * @dev Returns the number of pools in the contract
     * @return Number of pools
     */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @dev This function is called to calculate the rewardsPerSeconds off the rewardTokenBalance
     * @notice The logic in this function is not in the constructor as we need to transfer the reward tokens in first (rewardToken.distributeRewards())
     */
    function initializeRewards() external onlyOperator {
        require(totalRewards == 0, "Rewards already initialized");
        uint256 contractBalance = rewardToken.balanceOf(address(this));
        require(contractBalance > 0, "No rewards in contract");
        totalRewards = contractBalance;
        rewardsPerSecond = totalRewards / RUNNING_TIME;
    }

    /**
     * @dev Helper function to check if a token is already used in a pool
     * @param _token Token to check for duplicates
     */
    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "GenesisRewardPool: existing pool");
        }
    }

    /**
     * @dev Bulk add multiple pools at once
     * @param _allocPoints Array of allocation points for each pool
     * @param _depFees Array of deposit fees for each pool
     * @param _tokens Array of token addresses for each pool
     * @param _withUpdate Whether to update all pools
     * @param _lastRewardTime Last reward time for all pools
     */
    function addBulk(
        uint256[] calldata _allocPoints,
        uint256[] calldata _depFees,
        address[] calldata _tokens,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) external onlyOperator {
        require(
            _allocPoints.length == _depFees.length && _allocPoints.length == _tokens.length,
            "GenesisRewardPool: invalid length"
        );
        for (uint256 i = 0; i < _allocPoints.length; i++) {
            add(_allocPoints[i], _depFees[i], _tokens[i], _withUpdate, _lastRewardTime);
        }
    }

    /**
     * @dev Add a new token to the reward pool system
     * @param _allocPoint Allocation points for the new pool
     * @param _depFee Deposit fee in basis points (1 = 0.01%)
     * @param _token Token to be staked
     * @param _withUpdate Whether to update all pools
     * @param _lastRewardTime Last reward time for this pool
     */
    function add(uint256 _allocPoint, uint256 _depFee, address _token, bool _withUpdate, uint256 _lastRewardTime)
        public
        onlyOperator
    {
        checkPoolDuplicate(IERC20(_token));
        require(_depFee < 200, "GenesisRewardPool: deposit fee too high"); // deposit fee can't be more than 2%

        if (_withUpdate) {
            massUpdatePools();
        }

        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);

        uint256 pid = poolInfo.length;

        poolInfo.push(
            PoolInfo({
                token: IERC20(_token),
                depFee: _depFee,
                allocPoint: _allocPoint,
                lastRewardTime: _lastRewardTime,
                accRewardsPerShare: 0,
                isStarted: _isStarted,
                totalStaked: 0
            })
        );

        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }

        emit PoolAdded(pid, _token, _allocPoint, _depFee);
    }

    /**
     * @dev Update a pool's reward allocation points and deposit fee
     * @param _pid Pool ID to update
     * @param _allocPoint New allocation points
     * @param _depFee New deposit fee in basis points
     */
    function set(uint256 _pid, uint256 _allocPoint, uint256 _depFee) public onlyOperator {
        massUpdatePools();

        PoolInfo storage pool = poolInfo[_pid];
        require(_depFee < 200, "GenesisRewardPool: deposit fee too high"); // deposit fee can't be more than 2%

        uint256 oldAllocPoint = pool.allocPoint;
        uint256 oldDepFee = pool.depFee;

        pool.depFee = _depFee;

        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;

        emit PoolUpdated(_pid, oldAllocPoint, _allocPoint, oldDepFee, _depFee);
    }

    /**
     * @dev Bulk update multiple pools at once
     * @param _pids Array of pool IDs to update
     * @param _allocPoints Array of new allocation points
     * @param _depFees Array of new deposit fees
     */
    function bulkSet(uint256[] calldata _pids, uint256[] calldata _allocPoints, uint256[] calldata _depFees)
        external
        onlyOperator
    {
        require(
            _pids.length == _allocPoints.length && _pids.length == _depFees.length, "GenesisRewardPool: invalid length"
        );
        for (uint256 i = 0; i < _pids.length; i++) {
            set(_pids[i], _allocPoints[i], _depFees[i]);
        }
    }

    /**
     * @dev Calculate accumulated rewards over a given time period
     * @param _fromTime Start time to calculate rewards from
     * @param _toTime End time to calculate rewards to
     * @return Total rewards generated during this period
     */
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(rewardsPerSecond);
            return poolEndTime.sub(_fromTime).mul(rewardsPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(rewardsPerSecond);
            return _toTime.sub(_fromTime).mul(rewardsPerSecond);
        }
    }

    /**
     * @dev View function to see pending rewards for a user
     * @param _pid Pool ID
     * @param _user Address of the user
     * @return Pending rewards for the user
     */
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardsPerShare = pool.accRewardsPerShare;
        uint256 tokenSupply = pool.totalStaked;
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _rewards = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accRewardsPerShare = accRewardsPerShare.add(_rewards.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accRewardsPerShare).div(1e18).sub(user.rewardDebt);
    }

    /**
     * @dev Update all pools to distribute pending rewards
     */
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * @dev Update a range of pools to save gas compared to updating all pools
     * @param _fromPid Starting pool ID (inclusive)
     * @param _toPid Ending pool ID (inclusive)
     */
    function massUpdatePoolsInRange(uint256 _fromPid, uint256 _toPid) public {
        require(_fromPid <= _toPid, "GenesisRewardPool: invalid range");
        for (uint256 pid = _fromPid; pid <= _toPid; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * @dev Update reward variables for a specific pool
     * @param _pid Pool ID to update
     */
    function updatePool(uint256 _pid) private {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.totalStaked;
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _rewards = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accRewardsPerShare = pool.accRewardsPerShare.add(_rewards.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * @dev Update the dev fund address
     * @param _devFund New dev fund address
     */
    function setDevFund(address _devFund) public onlyOperator {
        address oldDevFund = devFund;
        devFund = _devFund;
        emit DevFundUpdated(oldDevFund, _devFund);
    }

    /**
     * @dev Allow users to deposit tokens and earn rewards
     * @param _pid Pool ID to deposit into
     * @param _amount Amount of tokens to deposit
     */
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accRewardsPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeRewardTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            uint256 depositDebt = _amount.mul(pool.depFee).div(10000);
            user.amount = user.amount.add(_amount.sub(depositDebt));
            pool.totalStaked = pool.totalStaked.add(_amount.sub(depositDebt));
            pool.token.safeTransfer(devFund, depositDebt);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    /**
     * @dev Allow users to withdraw tokens
     * @param _pid Pool ID to withdraw from
     * @param _amount Amount of tokens to withdraw
     */
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accRewardsPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeRewardTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalStaked = pool.totalStaked.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    /**
     * @dev Emergency withdraw without caring about rewards
     * @param _pid Pool ID to withdraw from
     */
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        pool.totalStaked = pool.totalStaked.sub(_amount);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    /**
     * @dev Safe rewardToken transfer function to prevent rounding errors
     * @param _to Recipient address
     * @param _amount Amount to transfer
     */
    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 _rewardTokenBal = rewardToken.balanceOf(address(this));
        if (_rewardTokenBal > 0) {
            if (_amount > _rewardTokenBal) {
                rewardToken.safeTransfer(_to, _rewardTokenBal);
            } else {
                rewardToken.safeTransfer(_to, _amount);
            }
        }
    }

    /**
     * @dev Returns the pool IDs and amounts for all pools where the user has deposits
     * @param _user Address of the user
     * @return pids Array of pool IDs where the user has deposits
     * @return amounts Array of amounts the user has deposited in each pool
     * @return pendingRewardsArray Array of pending rewards for each pool
     */
    function getUserPools(address _user)
        external
        view
        returns (uint256[] memory pids, uint256[] memory amounts, uint256[] memory pendingRewardsArray)
    {
        uint256 length = poolInfo.length;
        uint256 count = 0;

        // First count active pools to avoid excessive memory allocation
        for (uint256 pid = 0; pid < length; ++pid) {
            UserInfo storage user = userInfo[pid][_user];
            if (user.amount > 0) {
                count++;
            }
        }

        // Create arrays of exact size needed
        pids = new uint256[](count);
        amounts = new uint256[](count);
        pendingRewardsArray = new uint256[](count);

        // Fill arrays with user's pool data
        count = 0;
        for (uint256 pid = 0; pid < length; ++pid) {
            UserInfo storage user = userInfo[pid][_user];

            if (user.amount > 0) {
                pids[count] = pid;
                amounts[count] = user.amount;

                // Use the exact same logic as pendingRewards() for consistency
                PoolInfo storage pool = poolInfo[pid];
                uint256 accRewardsPerShare = pool.accRewardsPerShare;
                uint256 tokenSupply = pool.totalStaked;

                if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
                    uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
                    uint256 _rewards = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
                    accRewardsPerShare = accRewardsPerShare.add(_rewards.mul(1e18).div(tokenSupply));
                }

                pendingRewardsArray[count] = user.amount.mul(accRewardsPerShare).div(1e18).sub(user.rewardDebt);
                count++;
            }
        }

        return (pids, amounts, pendingRewardsArray);
    }

    /**
     * @dev Allows users to claim rewards from all pools they have deposits in with a single transaction
     * @return totalUserRewards Total rewards claimed across all pools
     */
    function claimAll() external nonReentrant returns (uint256 totalUserRewards) {
        address _sender = msg.sender;
        totalUserRewards = 0;
        uint256 length = poolInfo.length;

        // Process each pool the user has deposits in
        for (uint256 pid = 0; pid < length; ++pid) {
            UserInfo storage user = userInfo[pid][_sender];

            if (user.amount > 0) {
                // Update the pool - this follows the same pattern as deposit() and withdraw()
                updatePool(pid);

                PoolInfo storage pool = poolInfo[pid];

                // Calculate pending rewards (identical to deposit/withdraw)
                uint256 _pending = user.amount.mul(pool.accRewardsPerShare).div(1e18).sub(user.rewardDebt);

                if (_pending > 0) {
                    totalUserRewards = totalUserRewards.add(_pending);

                    // For detailed reporting, emit an event per pool with rewards
                    emit RewardPaid(_sender, _pending);
                }

                // Update user's reward debt regardless of pending amount
                user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
            }
        }

        // Transfer total rewards in one operation if there are any
        if (totalUserRewards > 0) {
            safeRewardTransfer(_sender, totalUserRewards);
        }

        return totalUserRewards;
    }

    /**
     * @dev Update the operator address
     * @param _operator New operator address
     */
    function setOperator(address _operator) external onlyOperator {
        require(_operator != address(0), "operator cannot be zero address");
        address oldOperator = operator;
        operator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }

    /**
     * @dev Governance function to recover unsupported tokens
     * @notice This does not allow to recover any pool tokens for 14 days
     * @param _token Token to recover
     * @param amount Amount to recover
     * @param to Recipient address
     */
    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        // Never allow recovery of the reward token
        require(_token != rewardToken, "token cannot be reward token");

        if (block.timestamp < poolEndTime + 14 days) {
            // do not allow to recover tokens if less than 14 days after pool ends
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "token cannot be pool token");
            }
        }

        _token.safeTransfer(to, amount);
        emit TokensRecovered(address(_token), to, amount);
    }
}
