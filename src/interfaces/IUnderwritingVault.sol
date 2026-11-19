// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IUnderwritingVault {
    function openPool(uint256 epochId, uint64 depositsClose) external;
    function slash(uint256 epochId, uint256 amount, address recipient) external returns (uint256);
    function release(uint256 epochId) external;
}
