// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VelaCoreFaucet is Ownable {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable vecToken;
    
    uint256 public amountPerClaim = 5000 * 10**18; // 10,000 VEC fixed
    uint256 public cooldownPeriod = 86400; // 24 hours default
    uint256 public totalDistributed;
    uint256 public claimCount;
    
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public totalClaimedByUser;
    
    mapping(address => bool) public isWhitelisted;
    bool public whitelistEnabled = false; // Initially disabled
    
    event TokensClaimed(address indexed user, uint256 amount);
    event AmountPerClaimUpdated(uint256 oldAmount, uint256 newAmount);
    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event WhitelistToggled(bool enabled);
    event WhitelistUpdated(address indexed user, bool whitelisted);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event TokensDeposited(address indexed from, uint256 amount);
    event FaucetRefilled(uint256 amount);
    
    constructor(address _vecToken) Ownable(msg.sender) {
        require(_vecToken != address(0), "VEC_FAUCET: Invalid token address");
        
        vecToken = IERC20(_vecToken);
        
        isWhitelisted[msg.sender] = true;
        
        isWhitelisted[address(0)] = false;
    }
  
    function claimTokens() external {
        address user = msg.sender;
        
        if (whitelistEnabled) {
            require(isWhitelisted[user], "VEC_FAUCET: Address not whitelisted");
        }
        
        uint256 lastClaim = lastClaimTime[user];
        uint256 nextClaimTime = lastClaim + cooldownPeriod;
        
        require(
            block.timestamp >= nextClaimTime,
            string(
                abi.encodePacked(
                    "VEC_FAUCET: Cooldown active. Next claim at: ",
                    _toString(nextClaimTime)
                )
            )
        );
        
        uint256 faucetBalance = vecToken.balanceOf(address(this));
        require(
            faucetBalance >= amountPerClaim,
            "VEC_FAUCET: Faucet empty. Please try again later"
        );
        
        lastClaimTime[user] = block.timestamp;
        totalClaimedByUser[user] += amountPerClaim;
        totalDistributed += amountPerClaim;
        claimCount += 1;
        
        vecToken.safeTransfer(user, amountPerClaim);
        
        emit TokensClaimed(user, amountPerClaim);
    }

    function canClaim(address user) external view returns (bool canClaimNow, string memory reason) {
        if (whitelistEnabled && !isWhitelisted[user]) {
            return (false, "Address not whitelisted");
        }
        
        uint256 faucetBalance = vecToken.balanceOf(address(this));
        if (faucetBalance < amountPerClaim) {
            return (false, "Faucet empty");
        }
        
        uint256 nextClaimTime = lastClaimTime[user] + cooldownPeriod;
        if (block.timestamp < nextClaimTime) {
            return (false, string(abi.encodePacked("Cooldown active. Wait ", _toString(nextClaimTime - block.timestamp), " seconds")));
        }
        
        return (true, "Can claim");
    }

    function timeUntilNextClaim(address user) external view returns (uint256) {
        uint256 nextClaimTime = lastClaimTime[user] + cooldownPeriod;
        
        if (block.timestamp >= nextClaimTime) {
            return 0;
        }
        
        return nextClaimTime - block.timestamp;
    }

    function getFaucetStats() external view returns (
        uint256 currentBalance,
        uint256 distributedTotal,
        uint256 totalClaims,
        uint256 claimAmount,
        uint256 cooldown,
        bool isWhitelistActive,
        uint256 availableClaims
    ) {
        uint256 balance = vecToken.balanceOf(address(this));
        return (
            balance,
            totalDistributed,
            claimCount,
            amountPerClaim,
            cooldownPeriod,
            whitelistEnabled,
            balance / amountPerClaim
        );
    }

    function getUserStats(address user) external view returns (
        uint256 lastClaimTimestamp,
        uint256 totalClaimed,
        bool canClaimNow,
        uint256 secondsUntilNextClaim,
        string memory statusMessage
    ) {
        uint256 lastClaim = lastClaimTime[user];
        uint256 nextClaimTime = lastClaim + cooldownPeriod;
        
        bool eligible = true;
        string memory message = "Can claim";
        
        if (whitelistEnabled && !isWhitelisted[user]) {
            eligible = false;
            message = "Not whitelisted";
        }
        
        uint256 faucetBalance = vecToken.balanceOf(address(this));
        if (faucetBalance < amountPerClaim) {
            eligible = false;
            message = "Faucet empty";
        }
        
        if (block.timestamp < nextClaimTime) {
            eligible = false;
            message = string(abi.encodePacked("Cooldown active. Wait ", _toString(nextClaimTime - block.timestamp), "s"));
        }
        
        return (
            lastClaim,
            totalClaimedByUser[user],
            eligible,
            block.timestamp >= nextClaimTime ? 0 : nextClaimTime - block.timestamp,
            message
        );
    }
    

    function updateAmountPerClaim(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "VEC_FAUCET: Amount must be > 0");
        require(newAmount <= 100000 * 10**18, "VEC_FAUCET: Max 100,000 VEC per claim");
        
        uint256 oldAmount = amountPerClaim;
        amountPerClaim = newAmount;
        
        emit AmountPerClaimUpdated(oldAmount, newAmount);
    }

    function updateCooldownPeriod(uint256 newCooldown) external onlyOwner {
        require(newCooldown >= 3600, "VEC_FAUCET: Minimum 1 hour cooldown");
        require(newCooldown <= 7 days, "VEC_FAUCET: Maximum 7 days cooldown");
        
        uint256 oldCooldown = cooldownPeriod;
        cooldownPeriod = newCooldown;
        
        emit CooldownUpdated(oldCooldown, newCooldown);
    }

    function toggleWhitelist(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    function updateWhitelist(address user, bool whitelisted) external onlyOwner {
        require(user != address(0), "VEC_FAUCET: Invalid address");
        
        isWhitelisted[user] = whitelisted;
        emit WhitelistUpdated(user, whitelisted);
    }

    function batchUpdateWhitelist(
        address[] calldata users,
        bool[] calldata statuses
    ) external onlyOwner {
        require(users.length == statuses.length, "VEC_FAUCET: Arrays mismatch");
        require(users.length <= 100, "VEC_FAUCET: Too many addresses");
        
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] != address(0)) {
                isWhitelisted[users[i]] = statuses[i];
                emit WhitelistUpdated(users[i], statuses[i]);
            }
        }
    }
 
    function withdrawTokens(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "VEC_FAUCET: Invalid recipient");
        require(amount > 0, "VEC_FAUCET: Invalid amount");
        
        uint256 balance = vecToken.balanceOf(address(this));
        require(balance >= amount, "VEC_FAUCET: Insufficient balance");
        
        vecToken.safeTransfer(to, amount);
        
        emit TokensWithdrawn(to, amount);
    }

    function withdrawAllTokens(address to) external onlyOwner {
        require(to != address(0), "VEC_FAUCET: Invalid recipient");
        
        uint256 balance = vecToken.balanceOf(address(this));
        require(balance > 0, "VEC_FAUCET: No balance");
        
        vecToken.safeTransfer(to, balance);
        
        emit TokensWithdrawn(to, balance);
    }

    function depositTokens(uint256 amount) external {
        require(amount > 0, "VEC_FAUCET: Invalid amount");
        
        uint256 userBalance = vecToken.balanceOf(msg.sender);
        require(userBalance >= amount, "VEC_FAUCET: Insufficient user balance");
        
        uint256 allowance = vecToken.allowance(msg.sender, address(this));
        require(allowance >= amount, "VEC_FAUCET: Insufficient allowance. Please approve tokens first");
        
        vecToken.safeTransferFrom(msg.sender, address(this), amount);
        
        emit TokensDeposited(msg.sender, amount);
    }

    function refillFaucet(uint256 amount) external onlyOwner {
        require(amount > 0, "VEC_FAUCET: Invalid amount");
        
        uint256 ownerBalance = vecToken.balanceOf(msg.sender);
        require(ownerBalance >= amount, "VEC_FAUCET: Insufficient owner balance");
        
        uint256 allowance = vecToken.allowance(msg.sender, address(this));
        require(allowance >= amount, "VEC_FAUCET: Insufficient allowance. Please approve tokens first");
        
        vecToken.safeTransferFrom(msg.sender, address(this), amount);
        
        emit FaucetRefilled(amount);
    }

    function emergencyStop() external onlyOwner {
        cooldownPeriod = 365 days; // Set cooldown to 1 year
        emit CooldownUpdated(cooldownPeriod, 365 days);
    }

    function resumeFaucet(uint256 newCooldown) external onlyOwner {
        require(newCooldown >= 3600, "VEC_FAUCET: Minimum 1 hour");
        cooldownPeriod = newCooldown;
        emit CooldownUpdated(365 days, newCooldown);
    }
    

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        
        uint256 temp = value;
        uint256 digits;
        
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }

    function getContractInfo() external view returns (
        address tokenAddress,
        string memory tokenSymbol,
        uint256 tokenDecimals,
        uint256 faucetBalance,
        uint256 claimAmount,
        uint256 cooldown,
        uint256 availableClaims
    ) {
        uint256 balance = vecToken.balanceOf(address(this));
        return (
            address(vecToken),
            "VEC", // Hardcoded since we know it's VEC
            18,    // Hardcoded since VEC uses 18 decimals
            balance,
            amountPerClaim,
            cooldownPeriod,
            balance / amountPerClaim
        );
    }
}
