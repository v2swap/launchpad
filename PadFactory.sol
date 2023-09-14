// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "./OwnableUpgradeable.sol";
import "./Initializable.sol";
import "./Clones.sol";
import "./IERC20Upgradeable.sol";
import "./SafeERC20Upgradeable.sol";

import "./IUnlimited.sol";

contract PadFactory is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    address public feeCollector;
    address public unlimitedImplementation;
    // Price of each token in USD, scaled to 1e18
    uint256 public tokenPrice;

    // issued token => model address
    mapping(address => address) public getModel;
    mapping(address => bool) public isModel;
    mapping(address => bool) public isUnlimited;
    // fee rates of unlimited model
    uint256 public multiplierFeeRate = 200; // 2% fee rate (200 basis points)
    address[] public allUnlimitedModels;

    /// @notice initializes the pad factory
    /// @dev Uses clone factory pattern to save space
    /// @param _unlimitedImplementation Implementation of unlimited model contract
    /// @param _feeCollector Address that collects participation fees of unlimited model
    function initialize(
        address _unlimitedImplementation,
        address _feeCollector
    ) public initializer {
        __Ownable_init();

        require(
            _unlimitedImplementation != address(0),
            "PadFactory: model implentation can't be zero address"
        );
        require(_feeCollector != address(0), "PadFactory: fee collector can't be zero address");
        
        unlimitedImplementation = _unlimitedImplementation;
        feeCollector = _feeCollector;

        _setMultiplierFeeRate(200); // Set a constant fee rate of 2%
    }

    /// @notice Returns the number of models
    function numModels() external view returns (uint256 total, uint256 unlimited) {
        total = allUnlimitedModels.length;
        unlimited = allUnlimitedModels.length;
    }

    /// @notice Creates an unlimited model contract
    /// @param _issuer Address of the project issuing tokens for auction
    /// @param _issuedToken Token that will be issued through this launch event
    /// @param _paymentToken Token that will be raised through this launch event
    /// @param _issuedTokenAmount Amount of tokens that will be issued
    /// @param _price Price of each token in USD, scaled to 1e18
    /// @param _depositStartTime Timestamp of when launch event will start to deposit
    /// @param _depositDuration Timestamp of how long deposit phase will last for
    /// @param _launchTime Timestamp of when launch event will launch token
    /// @param _decimals Decimals of issuedToken
    /// @return Address of primary model launch event contract
    function createNewUnlimitedModel(
        address _issuer,
        address _issuedToken,
        address _paymentToken,
        uint256 _issuedTokenAmount,
        uint256 _price,
        uint256 _depositStartTime,
        uint256 _depositDuration,
        uint256 _launchTime,
        uint256 _decimals,
        uint256 _minDeposit
    ) external onlyOwner returns(address) {
        require(_issuer != address(0), "PadFactory: issuer can't be 0 address");
        require(_issuedToken != address(0), "PadFactory: issued token can't be 0 address");
        require(_paymentToken != address(0), "PadFactory: payment token can't be 0 address");
        require(_issuedTokenAmount > 0, "PadFactory: issued token amount need to be greater than 0");
        require(getModel[_issuedToken] == address(0), "PadFactory: token has already been issued");

        address unlimitedModelEvent = Clones.clone(unlimitedImplementation);

        getModel[_issuedToken] = unlimitedModelEvent;
        isModel[unlimitedModelEvent] = true;
        isUnlimited[unlimitedModelEvent] = true;
        allUnlimitedModels.push(unlimitedModelEvent);

        IUnlimited(unlimitedModelEvent).initialize(
            _issuer, 
            _issuedToken, 
            _paymentToken, 
            _issuedTokenAmount, 
            _price, 
            _depositStartTime, 
            _depositDuration, 
            _launchTime, 
            _decimals,
            _minDeposit
        );

        emit NewUnlimitedModelEventCreated(
            unlimitedModelEvent, 
            _issuedToken, 
            _paymentToken,
            _depositStartTime,
            _depositDuration,
            _launchTime
        );

        return unlimitedModelEvent;
    }

    function getCurrentTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _setMultiplierFeeRate(uint256 _feeRate) internal {
        multiplierFeeRate = _feeRate;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Set address to collect participation fees of unlimited model
    /// @param _feeCollector New fee collector address
    function setFeeCollector(address _feeCollector)
        external
        onlyOwner
    {
        require(
            _feeCollector != address(0),
            "PadFactory: fee collector can't be address zero"
        );
        feeCollector = _feeCollector;
        emit SetFeeCollector(_feeCollector);
    }

    
    function addModel(address _model) 
        public 
        onlyOwner {
        isModel[_model] = true;
    }
    
    function delModel(address _model) 
        public 
        onlyOwner {
        isModel[_model] = false;
    }

    /// @notice Set multiplier fee rate for unlimited model
    /// @param _feeRate value of rate
    function setMultiplierFeeRate(uint256 _feeRate) 
        external 
        onlyOwner {
        _setMultiplierFeeRate(_feeRate);
        emit MulitplierFeeRateSet(msg.sender, _feeRate);
    }

    /// @notice Set the proxy implementation address
    /// @param _unlimitedImplementation The address of the primary implementation contract
    function setUnlimitedImplementation(address _unlimitedImplementation)
        external
        onlyOwner
    {
        require(_unlimitedImplementation != address(0), "RJFactory: can't be null");
        unlimitedImplementation = _unlimitedImplementation;
        emit SetUnlimitedImplementation(_unlimitedImplementation);
    }

    /* ========== EVENTS ========== */
    event MulitplierFeeRateSet(address indexed setter, uint256 feeRate);
    event SetUnlimitedImplementation(address indexed _unlimitedImplementation);
    event SetFeeCollector(address indexed _feeCollector);
    event NewUnlimitedModelEventCreated(
        address indexed unlimitedModelEvent, 
        address indexed _issuedToken, 
        address indexed _paymentToken,
        uint256 _depositStartTime,
        uint256 _depositDuration,
        uint256 _launchTime
    );
}