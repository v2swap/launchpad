// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "./IERC20MetadataUpgradeable.sol";
import "./SafeERC20Upgradeable.sol";
import "./SafeMathUpgradeable.sol";

import "./IPadFactory.sol";

interface Ownable {
    function owner() external view returns (address);
}

/// @title Launchpad V2 Unlimited model
/// @author v2swap, but originally by netswap
/// @notice A launch contract enabling unlimited deposit and refunds(if any)
contract Unlimited {
    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;
    using SafeMathUpgradeable for uint256;

    enum Phase {Prepare, Deposit, SaleEnded, Launch}

    struct UserInfo {
        /// @notice How much sale token user will get
        uint256 allocation;
        /// @notice How much payment token user has deposited for this launch event
        uint256 balance;
        bool hasClaimedTokens;
        /// @notice How much refunds user will get under situation of over-subscription
        uint256 refunds;
        /// @notice If user claimed refunds
        bool hasClaimedRefunds;
    }

    /// @notice Issuer of sale token
    address public issuer;

    /// @notice The start time of depositing
    uint256 public depositStart;
    uint256 public DEPOSIT_DURATION;

    /// @notice The start time of launching token
    uint256 public launchTime;

    /// @notice price in USD per sale token
    /// @dev price is scaled to 1e18
    uint256 public price;

    IERC20MetadataUpgradeable public issuedToken;
    IERC20MetadataUpgradeable public paymentToken;
    uint256 public issuedTokenAmount;
    /// @notice target raised amount of payment token
    uint256 public targetRaised;
    /// @notice min deposit amount user invest from, scaled to 1e6
    uint256 public minDeposit;
    uint256 public issuedTokenDecimals;
    uint256 public paymentTokenDecimals;
    uint256 public PRICE_DECIMALS;
    uint256 public accIssuerCharged;
    address[] public participants;

    IPadFactory public padFactory;

    bool public hasFeeCharged;
    bool public hasIssuerCharged;
    bool public hasClaimedUnsoldTokens;
    bool public stopped;
    bool public issuedTokenDeposited;

    /// @dev paymentTokenReserve is the exact amount of paymentToken raised from users and needs to be kept inside the contract.
    /// If there is some excess (because someone sent token directly to the contract), the
    /// feeCollector can collect the excess using `skim()`
    uint256 public paymentTokenReserve;

    mapping(address => UserInfo) public getUserInfo;

    function initialize(
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
    ) external atPhase(Phase.Prepare) {
        require(depositStart == 0, "Unlimited: already initialized");

        padFactory = IPadFactory(msg.sender);

        require(
            _issuer != address(0),
            "Unlimited: issuer must be address zero"
        );
        require(
            _depositStartTime > block.timestamp, 
            "Unlimited: start of depositing can not be in the past"
        );

        issuer = _issuer;
        issuedToken = IERC20MetadataUpgradeable(_issuedToken);
        paymentToken = IERC20MetadataUpgradeable(_paymentToken);
        issuedTokenAmount = _issuedTokenAmount;
        price = _price;
        depositStart = _depositStartTime;
        DEPOSIT_DURATION =  _depositDuration;
        launchTime = _launchTime;
        issuedTokenDecimals = _decimals;
        paymentTokenDecimals = 1e18; 
        PRICE_DECIMALS = 1e18;
        targetRaised = issuedTokenAmount.mul(price)
            .mul(paymentTokenDecimals)
            .div(issuedTokenDecimals)
            .div(PRICE_DECIMALS);
        minDeposit = _minDeposit;

        emit UnlimitedEventInitialized(
            issuedTokenAmount,
            price,
            targetRaised
        );
    }

    function depositIssuedToken(uint256 amount) external atPhase(Phase.Prepare) {
        require(currentPhase() == Phase.Prepare, "Unlimited: Wrong phase");
        require(msg.sender == issuer, "Unlimited: Only issuer can call this function");
        require(amount > 0, "Unlimited: Deposit amount must be greater than 0");
        require(amount == issuedTokenAmount, "Unlimited: amount not equal to issuedTokenAmount");
        require(!issuedTokenDeposited, "Unlimited: already deposited");

        issuedTokenDeposited = true;
        issuedToken.transferFrom(msg.sender, address(this), amount);

        emit IssuedTokenDeposited(msg.sender, amount, issuedTokenAmount);
    }

    /// @notice Deposits payment token
    function deposit(uint256 amount) 
        external 
        isStopped(false) 
        atPhase(Phase.Deposit) 
    {
        require(currentPhase() == Phase.Deposit, "Unlimited: Wrong phase");
        require(
            amount > 0,
            "Unlimited: expected non-zero payment"
        );
        require(issuedTokenDeposited, "Unlimited: Issuer has not deposited tokens");

        UserInfo storage user = getUserInfo[msg.sender];

        // first deposit
        if (user.balance == 0) {
            require(amount >= minDeposit, "Unlimited: must reach min deposit");
            participants.push(msg.sender);
        }

        uint256 newBalance = user.balance + amount;

        user.balance = newBalance;
        paymentTokenReserve = paymentTokenReserve.add(amount);

        paymentToken.transferFrom(msg.sender, address(this), amount);

        emit UserParticipated(msg.sender, amount);
    }

    function refund() external hasRefunds {
        require(
            currentPhase() == Phase.SaleEnded || currentPhase() == Phase.Launch, 
            "Unlimited: Wrong phase"
        );
        UserInfo storage user = getUserInfo[msg.sender];
        require(!user.hasClaimedRefunds, "Unlimited: already claimed refunds");
        uint256 refundsAmount = getUserRefunds(msg.sender);
        user.refunds = refundsAmount;
        user.hasClaimedRefunds = true;
        _safeTransferPaymentToken(msg.sender, refundsAmount);
        emit UserRefunds(msg.sender, user.balance, refundsAmount);
    }

    /// @notice Auto set allocation for all participants
    function autoSetAlloc() external {
        require( 
            msg.sender == Ownable(address(padFactory)).owner(),
            "Unlimited: caller is not PadFactory owner"
        );
        require(
            currentPhase() == Phase.SaleEnded || currentPhase() == Phase.Launch, 
            "Unlimited: Wrong phase"
        );
        for (uint256 index = 0; index < userCount(); index++) {
            UserInfo storage user = getUserInfo[participants[index]];
            user.allocation = getUserAllocation(participants[index]);
        }
    }

    /// @notice Manually set allocation for participants in case of auto set "out of gas"
    /// @param _start the index starts from to set
    /// @param _end the index ends to set
    function manullySetAlloc(uint256 _start, uint256 _end) external {
        require( 
            msg.sender == Ownable(address(padFactory)).owner(),
            "Unlimited: caller is not PadFactory owner"
        );
        require(
            currentPhase() == Phase.SaleEnded || currentPhase() == Phase.Launch, 
            "Unlimited: Wrong phase"
        );
        for (uint256 index = _start; index < _end; index++) {
            UserInfo storage user = getUserInfo[participants[index]];
            user.allocation = getUserAllocation(participants[index]);
        }
    }

    function getAllUsers() public view returns (address[] memory) {
        return participants;
    }
    
    function userCount() public view returns (uint256) {
        return participants.length;
    }

    function getAllUserInfo() public view returns (UserInfo[] memory) {
        UserInfo[] memory userInfo = new UserInfo[](userCount());
        for (uint256 index = 0; index < userCount(); index++) {
            userInfo[index] = getUserInfo[participants[index]];
        }
        return userInfo;
    }

    /// @notice The current phase the event is in
    function currentPhase() public view returns (Phase) {
        if (depositStart == 0 || block.timestamp < depositStart) {
            return Phase.Prepare;
        } else if (block.timestamp < depositStart + DEPOSIT_DURATION) {
            return Phase.Deposit;
        } else if (
            block.timestamp >= depositStart + DEPOSIT_DURATION &&
            block.timestamp < launchTime
        ) {
            return Phase.SaleEnded;
        }
        return Phase.Launch;
    }

    function getUserAllocation(address _user) public view returns (uint256) {
        UserInfo storage user = getUserInfo[_user];
        (,uint256 issuerCharged,,) = getFundsDistribution();
        uint256 actualSaledTokenAmount = issuedTokenAmount.mul(issuerCharged).div(targetRaised);
        uint256 userAllocation = paymentTokenReserve > 0 ? actualSaledTokenAmount.mul(user.balance).div(paymentTokenReserve) : 0;
        return userAllocation;
    }

    function getUserRefunds(address _user) public view returns (uint256) {
        UserInfo storage user = getUserInfo[_user];
        (,,, uint256 refunds) = getFundsDistribution();
        uint256 userRefunds = 0;
        if (refunds > 0) {
            userRefunds = refunds.mul(user.balance).div(paymentTokenReserve);
        }
        return userRefunds;
    }

    function getFundsDistribution() public view returns (
    uint256 totalRaised, 
    uint256 issuerCharged, 
    uint256 fees, 
    uint256 refunds
    ) {
        totalRaised = paymentTokenReserve;
        uint256 feeRate = 200; // 2% fee rate (200 basis points)
        fees = totalRaised.mul(feeRate).div(10000);
        issuerCharged = totalRaised.sub(fees);
        if (issuerCharged > targetRaised) {
            issuerCharged = targetRaised;
        }
        refunds = totalRaised.sub(issuerCharged).sub(fees);
    }

    /// @notice Force balances to match tokens that were deposited, but not sent directly to the contract.
    /// Any excess tokens are sent to the feeCollector
    function skim() external {
        require(msg.sender == tx.origin, "Unlimited: EOA only");
        address feeCollector = padFactory.feeCollector();

        uint256 excessPaymentToken = paymentToken.balanceOf(address(this)) - paymentTokenReserve;
        if (excessPaymentToken > 0) {
            _safeTransferPaymentToken(feeCollector, excessPaymentToken);
        }
    }

    function withdrawUnsoldIssuedToken() external atPhase(Phase.Launch) {
        require(msg.sender == issuer, "Unlimited: Only issuer can call this function");
        
        (, uint256 issuerCharged,,) = getFundsDistribution();
        uint256 actualSaledTokenAmount = issuedTokenAmount.mul(issuerCharged).div(targetRaised);
        uint256 unsoldTokenAmount = issuedTokenAmount.sub(actualSaledTokenAmount);

        require(unsoldTokenAmount > 0, "Unlimited: No unsold tokens to withdraw");

        require(!hasClaimedUnsoldTokens, "Unlimited: Unsold Token Already Claimed");

        hasClaimedUnsoldTokens = true;
        
        issuedToken.transfer(issuer, unsoldTokenAmount);
        
        emit UnsoldTokensWithdrawn(issuer, unsoldTokenAmount);
    }

    function claimTokens() external atPhase(Phase.Launch) {
        require(currentPhase() == Phase.Launch, "Unlimited: Wrong phase");
        require(!getUserInfo[msg.sender].hasClaimedTokens, "Unlimited: Tokens already claimed");

        uint256 allocation = getUserAllocation(msg.sender);
        require(allocation > 0, "Unlimited: No tokens to claim");

        getUserInfo[msg.sender].hasClaimedTokens = true;
        issuedToken.transfer(msg.sender, allocation);

        emit TokensClaimed(msg.sender, allocation);
    }


    function chargeRaised() external isStopped(false) {
        require(msg.sender == issuer, "Unlimited: only issuer can do this");
        require(
            currentPhase() == Phase.SaleEnded || currentPhase() == Phase.Launch, 
            "Unlimited: Wrong phase"
        );
        require(!hasIssuerCharged, "Unlimited: Raised has been charged");
        (,uint256 issuerCharged,,) = getFundsDistribution();
        hasIssuerCharged = true;
        _safeTransferPaymentToken(msg.sender, issuerCharged);
        emit IssuerChargedRaised(msg.sender, issuerCharged);
    }

    function chargeFees() external isStopped(false) {
        require(
            msg.sender == Ownable(address(padFactory)).owner(), 
            "Unlimited: not padFactory owner"
        );
        require(
            currentPhase() == Phase.SaleEnded || currentPhase() == Phase.Launch, 
            "Unlimited: Wrong phase"
        );
        require(!hasFeeCharged, "Unlimited: fees has been charged");
        (,,uint256 fees,) = getFundsDistribution();
        hasFeeCharged = true;
        _safeTransferPaymentToken(msg.sender, fees);
        emit FeeCharged(msg.sender, fees);
    }

    /// @notice Withdraw payment token if launch has been cancelled
    function emergencyWithdraw() external isStopped(true) {
        UserInfo storage user = getUserInfo[msg.sender];
        require(
            user.balance > 0,
            "Unlimited: expected user to have non-zero balance to perform emergency withdraw"
        );

        uint256 balance = user.balance;
        user.balance = 0;
        paymentTokenReserve -= balance;

        _safeTransferPaymentToken(msg.sender, balance);

        emit PaymentTokenEmergencyWithdraw(msg.sender, balance);
    }

    /// @notice Stops the launch event and allows participants to withdraw deposits
    function allowEmergencyWithdraw() external {
        require(
            msg.sender == Ownable(address(padFactory)).owner(),
            "Unlimited: caller is not PadFactory owner"
        );
        stopped = true;
        emit Stopped();
    }

    function updateDepositDuration(uint256 _newDuration) atPhase(Phase.Deposit) external {
        require(
            msg.sender == Ownable(address(padFactory)).owner(),
            "Unlimited: caller is not PadFactory owner"
        );
        require(depositStart + _newDuration > block.timestamp, "invalid");
        DEPOSIT_DURATION = _newDuration;
    }

    function updateLaunchTime(uint256 _newLaunchTime) atPhase(Phase.SaleEnded) external {
        require(
            msg.sender == Ownable(address(padFactory)).owner(),
            "Unlimited: caller is not PadFactory owner"
        );
        require(_newLaunchTime > block.timestamp, "invalid");
        launchTime = _newLaunchTime;
    }

    /* ========== MODIFIER ========== */

    /// @notice Modifier which ensures contract is in a defined phase
    modifier atPhase(Phase _phase) {
        _atPhase(_phase);
        _;
    }

    /// @notice Ensures launch event is stopped/running
    modifier isStopped(bool _stopped) {
        _isStopped(_stopped);
        _;
    }

    modifier hasRefunds() {
        (,,, uint256 refunds) = getFundsDistribution();
        require(refunds > 0, "Unlimited: no refunds");
        _;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @dev Bytecode size optimization for the `atPhase` modifier
    /// This works becuase internal functions are not in-lined in modifiers
    function _atPhase(Phase _phase) internal view {
        require(currentPhase() == _phase, "Unlimited: wrong phase");
    }

    /// @dev Bytecode size optimization for the `isStopped` modifier
    /// This works becuase internal functions are not in-lined in modifiers
    function _isStopped(bool _stopped) internal view {
        if (_stopped) {
            require(stopped, "Unlimited: is still running");
        } else {
            require(!stopped, "Unlimited: stopped");
        }
    }

    /// @notice Send Payment Token
    /// @param _to The receiving address
    /// @param _value The amount of payment token to send
    /// @dev Will revert on failure
    function _safeTransferPaymentToken(address _to, uint256 _value) internal {
        uint256 paymentBal = paymentToken.balanceOf(address(this));
        if (_value > paymentBal) {
            paymentToken.transfer(_to, paymentBal);
        } else {
            paymentToken.transfer(_to, _value);
        }
    }

    /* ========== EVENTS ========== */
    event UnlimitedEventInitialized(
        uint256 issuedTokenAmount,
        uint256 price,
        uint256 targetRaised
    );

    event UserParticipated(
        address indexed user,
        uint256 paidAmount
    );

    event UserRefunds(
        address indexed user,
        uint256 paidAmount,
        uint256 refunds
    );

    event Stopped();

    event PaymentTokenEmergencyWithdraw(address indexed user, uint256 amount);

    event IssuerChargedRaised(address indexed issuer, uint256 amount);

    event FeeCharged(address indexed user, uint256 fees);

    event TokensClaimed(address indexed user, uint256 allocation);
    event IssuedTokenDeposited(address indexed issuer, uint256 amount, uint256 totalAmount);
    event UnsoldTokensWithdrawn(address indexed issuer, uint256 amount);

}