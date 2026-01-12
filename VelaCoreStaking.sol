// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VelaCoreStaking is Ownable, Pausable, ReentrancyGuard {
    // ========== CONSTANTS ==========
    uint256 public constant PRECISION_FACTOR = 1e12;
    uint256 public constant MAX_BPS = 10000;          // 100% = 10000 basis points
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant BSC_BLOCKS_PER_DAY = 28800; // 3 second blocks
    uint256 public constant BSC_BLOCKS_PER_YEAR = BSC_BLOCKS_PER_DAY * 365;
    
    // Early withdrawal penalties
    uint256 public constant PENALTY_30_DAYS = 2500;   // 25%
    uint256 public constant PENALTY_90_DAYS = 2000;   // 20%
    uint256 public constant PENALTY_180_DAYS = 1500;  // 15%
    uint256 public constant PENALTY_270_DAYS = 1000;  // 10%
    uint256 public constant PENALTY_360_DAYS = 500;   // 5%

    // ========== ENUMS ==========
    enum LockupPeriod {
        THIRTY_DAYS,      // 30 days
        NINETY_DAYS,      // 90 days
        ONE_EIGHTY_DAYS,  // 180 days
        TWO_SEVENTY_DAYS, // 270 days
        THREE_SIXTY_DAYS  // 360 days
    }
    
    // ========== STRUCTS ==========
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 stakeTime;
        uint256 unlockTime;
        uint256 totalRewardsClaimed;
        uint256 penaltyAmount;
        LockupPeriod lockupPeriod;
        bool isActive;
    }
    
    struct LockupConfig {
        uint256 duration;      // in seconds
        uint256 multiplierBPS; // 10000 = 1x
        uint256 penaltyBPS;    // Early withdrawal penalty
        uint256 projectedAPY;  // For display
    }
    
    struct Timelock {
        uint256 timestamp;
        uint256 newValue;
        address newAddress;
    }
    
    // ========== STATE VARIABLES ==========
    address public immutable vecToken;
    
    // Staking metrics
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    uint256 public totalPenaltiesCollected;
    uint256 public totalStakers;
    
    // Reward system
    uint256 public rewardPerBlock;
    uint256 public lastRewardBlock;
    uint256 public accRewardPerShare;
    
    // Limits & protections
    uint256 public minStakeAmount;
    uint256 public maxStakeAmount;
    uint256 public maxTotalStake;
    
    // Emergency state
    bool public emergencyMode;
    uint256 public emergencyActivatedAt;
    
    // Configuration
    mapping(LockupPeriod => LockupConfig) public lockupConfigs;
    mapping(address => StakeInfo) public stakes;
    mapping(address => uint256) public lastStakeTime;
    mapping(address => bool) public isBlacklisted;
    mapping(bytes32 => Timelock) public timelocks;
    
    // ========== EVENTS ==========
    event Staked(
        address indexed user,
        uint256 amount,
        LockupPeriod lockupPeriod,
        uint256 unlockTime,
        uint256 projectedAPY
    );
    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 penalty,
        bool earlyWithdrawal
    );
    event RewardClaimed(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event LockupConfigUpdated(LockupPeriod period, LockupConfig config);
    event StakeLimitsUpdated(uint256 min, uint256 max, uint256 maxTotal);
    event PenaltyCollected(address indexed from, uint256 amount);
    event TokensRecovered(address indexed token, uint256 amount);
    event AddressBlacklisted(address indexed account, bool blacklisted);
    event EmergencyModeActivated(uint256 timestamp);
    event EmergencyModeDeactivated(uint256 timestamp);
    event TimelockInitiated(bytes32 indexed operation, uint256 timestamp);
    event TimelockExecuted(bytes32 indexed operation);
    
    // ========== MODIFIERS ==========
    modifier updateReward() {
        _updateReward();
        _;
    }
    
    modifier notInEmergency() {
        require(!emergencyMode, "VEC_STAKING: Emergency mode active");
        _;
    }
    
    modifier validAddress(address addr) {
        require(addr != address(0), "VEC_STAKING: Zero address");
        require(!isBlacklisted[addr], "VEC_STAKING: Blacklisted");
        _;
    }
    
    modifier timelocked(bytes32 operation) {
        Timelock storage timelock = timelocks[operation];
        require(timelock.timestamp > 0, "VEC_STAKING: Timelock not set");
        require(block.timestamp >= timelock.timestamp, "VEC_STAKING: Timelock active");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    constructor(
        address _vecToken,
        uint256 _rewardPerBlock,
        uint256 _minStakeAmount,
        uint256 _maxStakeAmount,
        uint256 _maxTotalStake
    ) Ownable(msg.sender) {
        require(_vecToken != address(0), "VEC_STAKING: Invalid token");
        require(_rewardPerBlock > 0, "VEC_STAKING: Invalid reward rate");
        require(_minStakeAmount > 0, "VEC_STAKING: Invalid min stake");
        require(_maxStakeAmount > _minStakeAmount, "VEC_STAKING: Invalid max stake");
        require(_maxTotalStake >= _maxStakeAmount, "VEC_STAKING: Invalid total stake limit");
        
        vecToken = _vecToken;
        rewardPerBlock = _rewardPerBlock;
        minStakeAmount = _minStakeAmount;
        maxStakeAmount = _maxStakeAmount;
        maxTotalStake = _maxTotalStake;
        lastRewardBlock = block.number;
        
        // Initialize lockup configurations
        _initializeLockupConfigs();
    }
    
    // ========== PUBLIC FUNCTIONS ==========
    
    function stake(uint256 amount, LockupPeriod lockupPeriod)
        external
        nonReentrant
        whenNotPaused
        notInEmergency
        validAddress(msg.sender)
        updateReward
    {
        require(amount >= minStakeAmount, "VEC_STAKING: Below minimum");
        require(amount <= maxStakeAmount, "VEC_STAKING: Above maximum");
        require(totalStaked + amount <= maxTotalStake, "VEC_STAKING: Contract limit");
        require(uint8(lockupPeriod) <= 4, "VEC_STAKING: Invalid lockup");
        
        StakeInfo storage userStake = stakes[msg.sender];
        require(!userStake.isActive, "VEC_STAKING: Already staking");
        
        LockupConfig memory config = lockupConfigs[lockupPeriod];
        require(config.duration > 0, "VEC_STAKING: Config not set");
        
        // Transfer tokens from user (VelaCoreToken compatible)
        (bool success, ) = vecToken.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                amount
            )
        );
        require(success, "VEC_STAKING: Token transfer failed");
        
        // Calculate unlock time
        uint256 unlockTime = block.timestamp + config.duration;
        
        // Update stake info
        userStake.amount = amount;
        userStake.rewardDebt = (amount * accRewardPerShare) / PRECISION_FACTOR;
        userStake.stakeTime = block.timestamp;
        userStake.unlockTime = unlockTime;
        userStake.lockupPeriod = lockupPeriod;
        userStake.isActive = true;
        lastStakeTime[msg.sender] = block.timestamp;
        
        // Update totals
        totalStaked += amount;
        totalStakers += 1;
        
        // Calculate projected APY
        uint256 projectedAPY = calculateAPYForPeriod(lockupPeriod);
        
        emit Staked(msg.sender, amount, lockupPeriod, unlockTime, projectedAPY);
    }

    function withdraw()
        external
        nonReentrant
        whenNotPaused
        updateReward
    {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.isActive, "VEC_STAKING: No active stake");
        require(userStake.amount > 0, "VEC_STAKING: No balance");
        
        // Claim pending rewards first
        _claimRewards(msg.sender);
        
        uint256 amount = userStake.amount;
        uint256 penalty = 0;
        bool earlyWithdrawal = false;
        
        // Check if early withdrawal
        if (block.timestamp < userStake.unlockTime) {
            LockupConfig memory config = lockupConfigs[userStake.lockupPeriod];
            penalty = (amount * config.penaltyBPS) / MAX_BPS;
            earlyWithdrawal = true;
            
            // Update penalty tracking
            userStake.penaltyAmount = penalty;
            totalPenaltiesCollected += penalty;
            
            emit PenaltyCollected(msg.sender, penalty);
        }
        
        uint256 withdrawAmount = amount - penalty;
        
        // Reset user stake
        userStake.amount = 0;
        userStake.rewardDebt = 0;
        userStake.isActive = false;
        userStake.penaltyAmount = 0;
        
        // Update totals
        totalStaked -= amount;
        totalStakers -= 1;
        
        // Transfer tokens to user
        if (withdrawAmount > 0) {
            (bool success, ) = vecToken.call(
                abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    msg.sender,
                    withdrawAmount
                )
            );
            require(success, "VEC_STAKING: Withdrawal failed");
        }
        
        emit Withdrawn(msg.sender, withdrawAmount, penalty, earlyWithdrawal);
    }

    function claimRewards()
        external
        nonReentrant
        whenNotPaused
        updateReward
    {
        _claimRewards(msg.sender);
    }

    function emergencyWithdraw()
        external
        nonReentrant
    {
        require(paused() || emergencyMode, "VEC_STAKING: Not in emergency");
        
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.isActive, "VEC_STAKING: No active stake");
        require(userStake.amount > 0, "VEC_STAKING: No balance");
        
        uint256 amount = userStake.amount;
        
        // Reset stake (no rewards, full penalty)
        userStake.amount = 0;
        userStake.rewardDebt = 0;
        userStake.isActive = false;
        
        totalStaked -= amount;
        totalStakers -= 1;
        
        // Transfer back tokens
        (bool success, ) = vecToken.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                msg.sender,
                amount
            )
        );
        require(success, "VEC_STAKING: Emergency withdrawal failed");
        
        emit EmergencyWithdrawn(msg.sender, amount);
    }
    
    // ========== VIEW FUNCTIONS ==========
    function pendingRewards(address user) public view returns (uint256) {
        StakeInfo storage userStake = stakes[user];
        if (!userStake.isActive || userStake.amount == 0) return 0;
        
        uint256 _accRewardPerShare = accRewardPerShare;
        
        if (block.number > lastRewardBlock && totalStaked > 0) {
            uint256 blocksPassed = block.number - lastRewardBlock;
            uint256 reward = blocksPassed * rewardPerBlock;
            _accRewardPerShare += (reward * PRECISION_FACTOR) / totalStaked;
        }
        
        uint256 pending = (userStake.amount * _accRewardPerShare) / PRECISION_FACTOR;
        
        if (pending > userStake.rewardDebt) {
            pending -= userStake.rewardDebt;
            
            // Apply lockup multiplier
            LockupConfig memory config = lockupConfigs[userStake.lockupPeriod];
            pending = (pending * config.multiplierBPS) / MAX_BPS;
            
            return pending;
        }
        
        return 0;
    }
    
    function calculateAPYForPeriod(LockupPeriod period) public view returns (uint256) {
        // Calculate base APY (without multiplier)
        uint256 annualRewardPerToken = rewardPerBlock * BSC_BLOCKS_PER_YEAR;
        uint256 baseAPYBPS = (annualRewardPerToken * MAX_BPS) / 1e18;
        
        // Apply lockup multiplier
        LockupConfig memory config = lockupConfigs[period];
        uint256 apyWithMultiplier = (baseAPYBPS * config.multiplierBPS) / MAX_BPS;
        
        return apyWithMultiplier;
    }
    
    function getUserStakeInfo(address user)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 pendingReward,
            uint256 stakeTime,
            uint256 unlockTime,
            uint256 totalClaimedRewards,
            uint256 timeRemaining,
            uint256 penaltyAmount,
            uint256 lockupPeriod,
            uint256 projectedAPY,
            bool isActive,
            bool canWithdraw
        )
    {
        StakeInfo storage userStake = stakes[user];
        stakedAmount = userStake.amount;
        pendingReward = pendingRewards(user);
        stakeTime = userStake.stakeTime;
        unlockTime = userStake.unlockTime;
        totalClaimedRewards = userStake.totalRewardsClaimed;
        penaltyAmount = userStake.penaltyAmount;
        lockupPeriod = uint8(userStake.lockupPeriod);
        isActive = userStake.isActive;
        projectedAPY = calculateAPYForPeriod(userStake.lockupPeriod);
        
        if (block.timestamp < unlockTime) {
            timeRemaining = unlockTime - block.timestamp;
            canWithdraw = false;
        } else {
            timeRemaining = 0;
            canWithdraw = true;
        }
    }
    
    function getStats()
        external
        view
        returns (
            uint256 totalStakedTokens,
            uint256 totalDistributedRewards,
            uint256 totalPenalties,
            uint256 activeStakers,
            uint256 currentRewardRate,
            uint256 baseAPY
        )
    {
        totalStakedTokens = totalStaked;
        totalDistributedRewards = totalRewardsDistributed;
        totalPenalties = totalPenaltiesCollected;
        activeStakers = totalStakers;
        currentRewardRate = rewardPerBlock;
        baseAPY = calculateAPYForPeriod(LockupPeriod.THIRTY_DAYS);
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function updateRewardRate(uint256 newRate)
        external
        onlyOwner
        timelocked(keccak256(abi.encodePacked("rewardRate", newRate)))
    {
        require(newRate > 0, "VEC_STAKING: Invalid rate");
        
        _updateReward();
        
        uint256 oldRate = rewardPerBlock;
        rewardPerBlock = newRate;
        
        emit RewardRateUpdated(oldRate, newRate);
    }
    
    function initiateRewardRateChange(uint256 newRate) external onlyOwner {
        require(newRate > 0, "VEC_STAKING: Invalid rate");
        
        bytes32 operation = keccak256(abi.encodePacked("rewardRate", newRate));
        timelocks[operation] = Timelock({
            timestamp: block.timestamp + TIMELOCK_DURATION,
            newValue: newRate,
            newAddress: address(0)
        });
        
        emit TimelockInitiated(operation, block.timestamp + TIMELOCK_DURATION);
    }
    
    function updateLockupConfig(LockupPeriod period, LockupConfig calldata config)
        external
        onlyOwner
    {
        require(config.duration >= 30 days, "VEC_STAKING: Duration too short");
        require(config.duration <= 365 days, "VEC_STAKING: Duration too long");
        require(config.multiplierBPS >= MAX_BPS, "VEC_STAKING: Multiplier < 1x");
        require(config.multiplierBPS <= MAX_BPS * 3, "VEC_STAKING: Multiplier > 3x");
        require(config.penaltyBPS <= MAX_BPS / 2, "VEC_STAKING: Penalty > 50%");
        
        lockupConfigs[period] = config;
        
        emit LockupConfigUpdated(period, config);
    }
    
    function updateStakeLimits(
        uint256 newMin,
        uint256 newMax,
        uint256 newMaxTotal
    ) external onlyOwner {
        require(newMin > 0, "VEC_STAKING: Min must be > 0");
        require(newMax > newMin, "VEC_STAKING: Max must be > Min");
        require(newMaxTotal >= newMax, "VEC_STAKING: Total must be >= Max");
        require(newMaxTotal >= totalStaked, "VEC_STAKING: Cannot reduce below current");
        
        minStakeAmount = newMin;
        maxStakeAmount = newMax;
        maxTotalStake = newMaxTotal;
        
        emit StakeLimitsUpdated(newMin, newMax, newMaxTotal);
    }
    
    function setBlacklist(address account, bool blacklisted)
        external
        onlyOwner
        validAddress(account)
    {
        require(account != owner(), "VEC_STAKING: Cannot blacklist owner");
        
        isBlacklisted[account] = blacklisted;
        emit AddressBlacklisted(account, blacklisted);
    }
    
    function activateEmergencyMode() external onlyOwner {
        require(!emergencyMode, "VEC_STAKING: Already active");
        
        emergencyMode = true;
        emergencyActivatedAt = block.timestamp;
        
        emit EmergencyModeActivated(block.timestamp);
    }
    
    function deactivateEmergencyMode() external onlyOwner {
        require(emergencyMode, "VEC_STAKING: Not active");
        require(
            block.timestamp >= emergencyActivatedAt + 7 days,
            "VEC_STAKING: 7 day lock"
        );
        
        emergencyMode = false;
        
        emit EmergencyModeDeactivated(block.timestamp);
    }
    
    function recoverTokens(address token, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(token != vecToken, "VEC_STAKING: Cannot recover VEC");
        
        (bool success, ) = token.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                owner(),
                amount
            )
        );
        require(success, "VEC_STAKING: Recovery failed");
        
        emit TokensRecovered(token, amount);
    }
    
    function withdrawPenalties() external onlyOwner nonReentrant {
        require(totalPenaltiesCollected > 0, "VEC_STAKING: No penalties");
        require(
            block.timestamp >= emergencyActivatedAt + 90 days,
            "VEC_STAKING: 90 day lock"
        );
        
        uint256 amount = totalPenaltiesCollected;
        totalPenaltiesCollected = 0;
        
        (bool success, ) = vecToken.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                owner(),
                amount
            )
        );
        require(success, "VEC_STAKING: Penalty withdrawal failed");
    }
    
    function addRewardTokens(uint256 amount) external onlyOwner nonReentrant {
        (bool success, ) = vecToken.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                amount
            )
        );
        require(success, "VEC_STAKING: Add rewards failed");
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    function _updateReward() internal {
        if (block.number > lastRewardBlock && totalStaked > 0) {
            uint256 blocksPassed = block.number - lastRewardBlock;
            uint256 reward = blocksPassed * rewardPerBlock;
            accRewardPerShare += (reward * PRECISION_FACTOR) / totalStaked;
            lastRewardBlock = block.number;
        }
    }
    
    function _claimRewards(address user) internal {
        StakeInfo storage userStake = stakes[user];
        require(userStake.isActive, "VEC_STAKING: No active stake");
        
        uint256 pending = pendingRewards(user);
        if (pending > 0) {
            // Update user state
            userStake.totalRewardsClaimed += pending;
            userStake.rewardDebt = (userStake.amount * accRewardPerShare) / PRECISION_FACTOR;
            
            // Transfer rewards
            (bool success, ) = vecToken.call(
                abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    user,
                    pending
                )
            );
            require(success, "VEC_STAKING: Reward transfer failed");
            
            totalRewardsDistributed += pending;
            
            emit RewardClaimed(user, pending);
        }
    }
    
    function _initializeLockupConfigs() internal {
        // 30 Days
        lockupConfigs[LockupPeriod.THIRTY_DAYS] = LockupConfig({
            duration: 30 days,
            multiplierBPS: 10000,   // 1.0x
            penaltyBPS: PENALTY_30_DAYS,
            projectedAPY: 1500      // 15%
        });
        
        // 90 Days
        lockupConfigs[LockupPeriod.NINETY_DAYS] = LockupConfig({
            duration: 90 days,
            multiplierBPS: 11500,   // 1.15x
            penaltyBPS: PENALTY_90_DAYS,
            projectedAPY: 1725      // 17.25%
        });
        
        // 180 Days
        lockupConfigs[LockupPeriod.ONE_EIGHTY_DAYS] = LockupConfig({
            duration: 180 days,
            multiplierBPS: 13500,   // 1.35x
            penaltyBPS: PENALTY_180_DAYS,
            projectedAPY: 2025      // 20.25%
        });
        
        // 270 Days
        lockupConfigs[LockupPeriod.TWO_SEVENTY_DAYS] = LockupConfig({
            duration: 270 days,
            multiplierBPS: 16000,   // 1.6x
            penaltyBPS: PENALTY_270_DAYS,
            projectedAPY: 2400      // 24%
        });
        
        // 360 Days
        lockupConfigs[LockupPeriod.THREE_SIXTY_DAYS] = LockupConfig({
            duration: 360 days,
            multiplierBPS: 20000,   // 2.0x
            penaltyBPS: PENALTY_360_DAYS,
            projectedAPY: 3000      // 30%
        });
    }
}
