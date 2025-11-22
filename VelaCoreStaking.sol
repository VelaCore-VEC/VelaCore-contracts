// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VelaCoreStaking
 * @dev Simple staking contract for the VelaCore (VEC) token.
 */
contract VelaCoreStaking is Ownable {
    // VEC token contract ka address jisko hum stake kar rahe hain.
    IERC20 public immutable stakingToken;

    // Har user ka kitna amount stake hua hai, uska record.
    mapping(address => uint256) public stakedBalances;

    // --- Events ---
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);

    /**
     * @dev Constructor mein VEC token contract ka address set karte hain.
     * @param _stakingToken Aapke deployed VelaCore token contract ka address.
     */
    constructor(address _stakingToken) Ownable(msg.sender) {
        // Token address zero nahi hona chahiye
        require(_stakingToken != address(0), "Invalid token address");
        stakingToken = IERC20(_stakingToken);
    }

    /**
     * @dev Users ko VEC tokens stake karne ki ijazat deta hai.
     * Zaroori: User ko pehle is contract ko token spend karne ki ijazat (approve) deni hogi.
     * @param amount Kitne VEC tokens stake karne hain.
     */
    function stake(uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");

        // Tokens user ke wallet se is contract mein transfer karein.
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Token transfer failed (check allowance)");

        // User ka staked balance update karein
        stakedBalances[msg.sender] += amount;

        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Users ko apne VEC tokens unstake (wapas nikalne) ki ijazat deta hai.
     * @param amount Kitne VEC tokens unstake karne hain.
     */
    function unstake(uint256 amount) external {
        // Check karein ke user ke paas utna balance hai ya nahi
        require(amount > 0, "Amount must be greater than zero");
        require(stakedBalances[msg.sender] >= amount, "Insufficient staked balance");

        // User ka staked balance kam karein
        stakedBalances[msg.sender] -= amount;

        // Tokens is contract se wapas user ko transfer karein.
        bool success = stakingToken.transfer(msg.sender, amount);
        require(success, "Token transfer failed");

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev User ka maujooda staked balance check karne ke liye.
     * @return Caller ka staked VEC amount.
     */
    function getStakedBalance() external view returns (uint256) {
        return stakedBalances[msg.sender];
    }
}
