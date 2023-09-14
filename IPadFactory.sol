
// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

interface IPadFactory {
    function feeCollector() external view returns (address);
    function numModels() external view returns (uint256 total, uint256 unlimited);
    function allUnlimitedModels(uint256 index) external view returns (address);
    function isModel(address unlimitedAddress) external view returns (bool);
}