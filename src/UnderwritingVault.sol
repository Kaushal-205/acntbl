// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralModule, IERC20} from "./CollateralModule.sol";
import {IIncidentOracle} from "./interfaces/IIncidentOracle.sol";
import {IUnderwritingVault} from "./interfaces/IUnderwritingVault.sol";

contract UnderwritingVault is CollateralModule, IUnderwritingVault {
    struct Pool {
        uint64 depositsClose;
        bool released;
        bool slashed;
        uint256 totalShares;
        uint256 principal;
        uint256 premiums;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => uint256)) public sharesOf;

    event Staked(uint256 indexed epochId, address indexed staker, uint256 assets);
    event PremiumFunded(uint256 indexed epochId, address indexed funder, uint256 assets);
    event StakeSlashed(uint256 indexed epochId, uint256 assets);
    event Redeemed(uint256 indexed epochId, address indexed staker, uint256 assets);

    constructor(IERC20 token, address oracle) CollateralModule(token, oracle) {}

    function openPool(uint256 epochId, uint64 depositsClose) external onlyCoordinator {
        if (pools[epochId].depositsClose != 0 || depositsClose <= block.timestamp) revert InvalidState();
        pools[epochId].depositsClose = depositsClose;
    }

    function stake(uint256 epochId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[epochId];
        if (block.timestamp >= pool.depositsClose || amount == 0) revert InvalidState();
        sharesOf[epochId][msg.sender] += amount;
        pool.totalShares += amount;
        pool.principal += amount;
        _collect(msg.sender, amount);
        emit Staked(epochId, msg.sender, amount);
    }

    function fundPremium(uint256 epochId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[epochId];
        if (block.timestamp < pool.depositsClose || pool.released || pool.totalShares == 0 || amount == 0) revert InvalidState();
        pool.premiums += amount;
        _collect(msg.sender, amount);
        emit PremiumFunded(epochId, msg.sender, amount);
    }

    function slash(uint256 epochId, uint256 amount, address recipient)
        external onlyCoordinator nonReentrant returns (uint256 seized)
    {
        Pool storage pool = pools[epochId];
        if (pool.released || pool.slashed || recipient == address(0)
            || IIncidentOracle(coordinator).outcome(epochId) != IIncidentOracle.Outcome.Failure) {
            revert InvalidState();
        }
        pool.slashed = true;
        seized = Math.min(pool.principal, amount);
        pool.principal -= seized;
        _pay(recipient, seized);
        emit StakeSlashed(epochId, seized);
    }

    function release(uint256 epochId) external onlyCoordinator {
        Pool storage pool = pools[epochId];
        if (pool.depositsClose == 0 || pool.released
            || IIncidentOracle(coordinator).outcome(epochId) == IIncidentOracle.Outcome.Pending) {
            revert InvalidState();
        }
        pool.released = true;
    }

    function redeem(uint256 epochId) external nonReentrant returns (uint256 amount) {
        Pool storage pool = pools[epochId];
        uint256 shares = sharesOf[epochId][msg.sender];
        if (!pool.released || shares == 0) revert InvalidState();
        delete sharesOf[epochId][msg.sender];
        amount = Math.mulDiv(shares, pool.principal + pool.premiums, pool.totalShares);
        _pay(msg.sender, amount);
        emit Redeemed(epochId, msg.sender, amount);
    }
}
