// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "./IERC20Metadata.sol";

interface IUnlimited {
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

    enum Phase {Prepare, Deposit, SaleEnded, Launch}

    function issuedToken() external view returns (IERC20Metadata);

    function paymentToken() external view returns (IERC20Metadata);

    function depositStart() external view returns (uint256);

    function DEPOSIT_DURATION() external view returns (uint256);

    function launchTime() external view returns (uint256);

    function price() external view returns (uint256);

    function issuedTokenAmount() external view returns (uint256);

    function targetRaised() external view returns (uint256);

    function issuedTokenDecimals() external view returns (uint256);

    function userCount() external view returns (uint256);

    function paymentTokenReserve() external view returns (uint256);

    function getUserInfo(address _user) external view returns (UserInfo memory);

    function getUserAllocation(address _user) external view returns (uint256);

    function getUserRefunds(address _user) external view returns (uint256);

    function currentPhase() external view returns (Phase);

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
        
    ) external;
}