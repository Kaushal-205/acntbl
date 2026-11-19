// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract CollateralModule is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidInput();
    error InvalidState();
    error UnsupportedCollateral();

    IERC20 public immutable collateral;
    address public immutable coordinator;

    constructor(IERC20 token, address authority) {
        if (address(token).code.length == 0 || authority == address(0)) revert InvalidInput();
        collateral = token;
        coordinator = authority;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Unauthorized();
        _;
    }

    function _collect(address sender, uint256 amount) internal {
        uint256 previousBalance = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(sender, address(this), amount);
        if (collateral.balanceOf(address(this)) != previousBalance + amount) revert UnsupportedCollateral();
    }

    function _pay(address receiver, uint256 amount) internal {
        if (amount != 0) collateral.safeTransfer(receiver, amount);
    }
}
