// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Standard OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VelaCore Token (VEC)
 * @dev BEP-20 (ERC-20 compatible) token.
 * Token Name: VelaCore, Symbol: VEC
 * Total Supply: 200,000,000 VEC
 * Decimals: 18
 */
contract VelaCore is ERC20, Ownable {
    
    // Ownable(msg.sender) ensures the deployer is the owner.
    constructor() ERC20("VelaCore", "VEC") Ownable(msg.sender) {
        // Mint 200,000,000 tokens to the deployer
        _mint(msg.sender, 200_000_000 * 1e18);
    }

    /**
     * @dev Owner can mint more tokens (REMOVE this for Mainnet).
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
