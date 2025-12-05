// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract VelaCoreToken {
    string public constant name = "VelaCore";
    string public constant symbol = "VEC";
    uint8 public constant decimals = 18;
    
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    address public owner;
    
    uint256 public constant TOTAL_FEE = 100;    // 1% = 100 basis points
    uint256 public constant LP_FEE = 80;        // 0.8% to LP wallet
    uint256 public constant BURN_FEE = 20;      // 0.2% burned
    uint256 private constant MAX_BPS = 10000;   // 100% = 10000 basis points
    
    address public liquidityWallet;
    
    mapping(address => bool) public isFeeExempt;
    
    bool private _locked;                     // Reentrancy guard
    bool public transfersPaused;              // Emergency pause
    mapping(address => bool) private _blacklist; // Blacklist for malicious addresses
    
    struct Timelock {
        uint256 timestamp;
        address newAddress;
        uint256 amount;
    }
    
    mapping(bytes32 => Timelock) public timelocks;
    uint256 public constant TIMELOCK_DURATION = 2 days;
 
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event LiquidityWalletChanged(address indexed oldWallet, address indexed newWallet);
    event FeeExemptionUpdated(address indexed account, bool exempt);
    event TokensBurned(address indexed from, uint256 amount);
    event LPFeeCollected(address indexed to, uint256 amount);
    event TokensRescued(address indexed token, uint256 amount, address indexed to);
    event EmergencyBurnExecuted(address indexed by, uint256 amount);
    event TransfersPaused(address indexed by, bool paused);
    event AddressBlacklisted(address indexed account, bool blacklisted);
    event TimelockInitiated(bytes32 indexed operation, address indexed newAddress, uint256 timestamp);
    event TimelockExecuted(bytes32 indexed operation);
        
    modifier onlyOwner() {
        require(msg.sender == owner, "VEC: caller is not the owner");
        _;
    }
    
    modifier validAddress(address addr) {
        require(addr != address(0), "VEC: zero address not allowed");
        require(!_blacklist[addr], "VEC: address is blacklisted");
        _;
    }
    
    modifier nonReentrant() {
        require(!_locked, "VEC: reentrancy guard");
        _locked = true;
        _;
        _locked = false;
    }
    
    modifier whenNotPaused() {
        require(!transfersPaused, "VEC: transfers are paused");
        _;
    }
        
    constructor(address _liquidityWallet) {
        require(_liquidityWallet != address(0), "VEC: zero liquidity wallet");
        
        owner = msg.sender;
        liquidityWallet = _liquidityWallet;
        
        isFeeExempt[msg.sender] = true;
        isFeeExempt[address(this)] = true;
        isFeeExempt[_liquidityWallet] = true;
        
        _validateFeeConfig();
        
        uint256 initialAmount = 200_000_000 * (10 ** decimals);
        totalSupply = initialAmount;
        balanceOf[msg.sender] = initialAmount;
        
        emit Transfer(address(0), msg.sender, initialAmount);
        emit OwnershipTransferred(address(0), msg.sender);
    }
        
    function transfer(address to, uint256 amount) 
        external 
        validAddress(to)
        whenNotPaused
        nonReentrant
        returns (bool) 
    {
        return _transfer(msg.sender, to, amount);
    }
    
    function transferFrom(address from, address to, uint256 amount) 
        external 
        validAddress(from)
        validAddress(to)
        whenNotPaused
        nonReentrant
        returns (bool) 
    {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "VEC: insufficient allowance");
        
        if (currentAllowance != type(uint256).max) {
            _approve(from, msg.sender, currentAllowance - amount);
        }
        
        return _transfer(from, to, amount);
    }
    
    function approve(address spender, uint256 amount) 
        external 
        validAddress(spender)
        returns (bool) 
    {
        _approve(msg.sender, spender, amount);
        return true;
    }
        
    function increaseAllowance(address spender, uint256 addedValue) 
        external 
        validAddress(spender)
        returns (bool) 
    {
        uint256 currentAllowance = allowance[msg.sender][spender];
        uint256 newAllowance = currentAllowance + addedValue;
        require(newAllowance >= currentAllowance, "VEC: allowance overflow");
        
        _approve(msg.sender, spender, newAllowance);
        return true;
    }
    
    function decreaseAllowance(address spender, uint256 subtractedValue) 
        external 
        validAddress(spender)
        returns (bool) 
    {
        uint256 currentAllowance = allowance[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "VEC: decreased allowance below zero");
        
        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) 
        internal 
        returns (bool) 
    {
        require(amount > 0, "VEC: transfer amount must be positive");
        require(from != to, "VEC: cannot transfer to self");
        
        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= amount, "VEC: insufficient balance");
        
        (uint256 lpFee, uint256 burnFee, uint256 transferAmount) = _calculateFees(amount);
        
        balanceOf[from] = fromBalance - amount;
        
        if (isFeeExempt[from] || isFeeExempt[to]) {
            balanceOf[to] += amount;
            emit Transfer(from, to, amount);
            return true;
        }
        
        balanceOf[to] += transferAmount;
        emit Transfer(from, to, transferAmount);
        
        if (lpFee > 0) {
            balanceOf[liquidityWallet] += lpFee;
            emit Transfer(from, liquidityWallet, lpFee);
            emit LPFeeCollected(liquidityWallet, lpFee);
        }
        
        if (burnFee > 0) {
            totalSupply -= burnFee;
            emit Transfer(from, address(0), burnFee);
            emit TokensBurned(from, burnFee);
        }
        
        return true;
    }
    
    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner != address(0), "VEC: approve from zero address");
        require(spender != address(0), "VEC: approve to zero address");
        
        allowance[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }
    
    function _calculateFees(uint256 amount) 
        internal 
        pure 
        returns (uint256 lpFee, uint256 burnFee, uint256 transferAmount) 
    {
        uint256 feeAmount = (amount * TOTAL_FEE) / MAX_BPS;
        lpFee = (amount * LP_FEE) / MAX_BPS;
        burnFee = (amount * BURN_FEE) / MAX_BPS;
        transferAmount = amount - feeAmount;
        
        require(feeAmount == lpFee + burnFee, "VEC: fee calculation error");
        require(transferAmount + feeAmount == amount, "VEC: amount calculation error");
    }
    
    function _validateFeeConfig() internal pure {
        require(TOTAL_FEE <= MAX_BPS, "VEC: total fee exceeds 100%");
        require(LP_FEE + BURN_FEE == TOTAL_FEE, "VEC: fee distribution error");
        require(TOTAL_FEE > 0, "VEC: fee must be positive");
        require(LP_FEE >= 0 && BURN_FEE >= 0, "VEC: negative fees not allowed");
    }
        
    function pauseTransfers(bool paused) external onlyOwner {
        transfersPaused = paused;
        emit TransfersPaused(msg.sender, paused);
    }
    
    function blacklistAddress(address account, bool blacklisted) external onlyOwner {
        require(account != address(0), "VEC: zero address");
        require(account != owner, "VEC: cannot blacklist owner");
        
        _blacklist[account] = blacklisted;
        emit AddressBlacklisted(account, blacklisted);
    }
    
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklist[account];
    }
        
    function initiateLiquidityWalletChange(address newWallet) external onlyOwner validAddress(newWallet) {
        bytes32 operationId = keccak256(abi.encodePacked("liquidityWallet", newWallet));
        timelocks[operationId] = Timelock({
            timestamp: block.timestamp + TIMELOCK_DURATION,
            newAddress: newWallet,
            amount: 0
        });
        
        emit TimelockInitiated(operationId, newWallet, block.timestamp + TIMELOCK_DURATION);
    }
    
    function executeLiquidityWalletChange(address newWallet) external onlyOwner {
        bytes32 operationId = keccak256(abi.encodePacked("liquidityWallet", newWallet));
        Timelock storage timelock = timelocks[operationId];
        
        require(timelock.timestamp > 0, "VEC: timelock not initiated");
        require(block.timestamp >= timelock.timestamp, "VEC: timelock not expired");
        require(timelock.newAddress == newWallet, "VEC: address mismatch");
        
        emit LiquidityWalletChanged(liquidityWallet, newWallet);
        liquidityWallet = newWallet;
        
        delete timelocks[operationId];
        emit TimelockExecuted(operationId);
    }
        
    function transferOwnership(address newOwner) 
        external 
        onlyOwner 
        validAddress(newOwner)
    {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
    
    function setLiquidityWallet(address newWallet) 
        external 
        onlyOwner 
        validAddress(newWallet)
    {
        emit LiquidityWalletChanged(liquidityWallet, newWallet);
        liquidityWallet = newWallet;
    }
    
    function setFeeExempt(address account, bool exempt) 
        external 
        onlyOwner 
        validAddress(account)
    {
        require(account != owner, "VEC: owner cannot be exempt");
        isFeeExempt[account] = exempt;
        emit FeeExemptionUpdated(account, exempt);
    }
    
    function batchSetFeeExempt(address[] calldata accounts, bool exempt) 
        external 
        onlyOwner 
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] != address(0) && accounts[i] != owner) {
                isFeeExempt[accounts[i]] = exempt;
                emit FeeExemptionUpdated(accounts[i], exempt);
            }
        }
    }
    
    function rescueTokens(address token, uint256 amount, address to) 
        external 
        onlyOwner 
        validAddress(to)
        nonReentrant
    {
        require(token != address(this), "VEC: cannot rescue native token");
        
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        
        if (!success) {
            if (data.length > 0) {
                revert(string(data));
            } else {
                revert("VEC: token transfer failed without error message");
            }
        }
        
        if (data.length > 0) {
            require(abi.decode(data, (bool)), "VEC: token transfer returned false");
        }
        
        emit TokensRescued(token, amount, to);
    }
    
    function emergencyBurn(uint256 amount) external onlyOwner {
        require(amount > 0, "VEC: amount must be positive");
        require(balanceOf[owner] >= amount, "VEC: insufficient owner balance");
        
        balanceOf[owner] -= amount;
        totalSupply -= amount;
        
        emit Transfer(owner, address(0), amount);
        emit TokensBurned(owner, amount);
        emit EmergencyBurnExecuted(owner, amount);
    }
        
    function getFeeInfo() external pure returns (
        uint256 totalFee,
        uint256 lpFee,
        uint256 burnFee,
        uint256 maxBps
    ) {
        return (TOTAL_FEE, LP_FEE, BURN_FEE, MAX_BPS);
    }
    
    function verifyFeeConfiguration() external pure returns (bool) {
        return (LP_FEE + BURN_FEE == TOTAL_FEE && TOTAL_FEE <= MAX_BPS);
    }
    
    function calculateFees(uint256 amount) external pure returns (
        uint256 totalFee,
        uint256 lpFee,
        uint256 burnFee,
        uint256 netAmount
    ) {
        totalFee = (amount * TOTAL_FEE) / MAX_BPS;
        lpFee = (amount * LP_FEE) / MAX_BPS;
        burnFee = (amount * BURN_FEE) / MAX_BPS;
        netAmount = amount - totalFee;
    }
    
    function version() external pure returns (string memory) {
        return "2.1.0";
    }
    
    function getOwner() external view returns (address) {
        return owner;
    }
    
    function isOwner(address account) external view returns (bool) {
        return account == owner;
    }
    
    function checkFeeExempt(address account) external view returns (bool) {
        return isFeeExempt[account];
    }
    
    function getTimelockInfo(bytes32 operationId) external view returns (uint256 timestamp, address newAddress) {
        Timelock storage timelock = timelocks[operationId];
        return (timelock.timestamp, timelock.newAddress);
    }
}
