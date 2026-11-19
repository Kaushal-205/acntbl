// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PaymentGuarantee} from "../PaymentGuarantee.sol";
import {CollateralModule} from "../CollateralModule.sol";

interface IVetoSlasher {
    function vault() external view returns (address);
    function vetoDuration() external view returns (uint48);
    function requestSlash(bytes32, address, uint256, uint48, bytes calldata) external returns (uint256);
    function executeSlash(uint256, bytes calldata) external returns (uint256);
}

interface ISymbioticVault {
    function collateral() external view returns (address);
    function epochDuration() external view returns (uint48);
}

/// @notice Optional recovery for the provider that already funded a missed-delivery benefit.
/// Network middleware registration and a distributor authorized to route burner proceeds are required.
contract SymbioticRecovery is CollateralModule {
    struct Recovery {
        uint48 capturedAt;
        bool requested;
        bool executed;
        uint256 index;
        uint256 executedAmount;
        uint256 received;
    }

    PaymentGuarantee public immutable guarantee;
    IVetoSlasher public immutable slasher;
    bytes32 public immutable subnetwork;
    address public immutable distributor;
    mapping(uint256 => Recovery) public recoveries;
    mapping(address => uint256) public reimbursable;

    event OptedIn(uint256 indexed receiptId, address indexed operator, uint48 capturedAt);
    event Requested(uint256 indexed receiptId, uint256 indexed slashIndex);
    event Executed(uint256 indexed receiptId, uint256 virtualAmount);
    event Received(uint256 indexed receiptId, uint256 assets);

    constructor(PaymentGuarantee policies, IVetoSlasher upstream, bytes32 network, address burnerDistributor)
        CollateralModule(policies.collateral(), address(policies))
    {
        if (burnerDistributor == address(0) || network == bytes32(0)
            || ISymbioticVault(upstream.vault()).collateral() != address(collateral)) revert InvalidInput();
        guarantee = policies;
        slasher = upstream;
        subnetwork = network;
        distributor = burnerDistributor;
    }

    function optIn(uint256 id) external {
        PaymentGuarantee.Receipt memory r = guarantee.receipt(id);
        if (msg.sender != r.terms.executor) revert Unauthorized();
        if (r.state != PaymentGuarantee.State.Offered || recoveries[id].capturedAt != 0
            || block.timestamp >= r.terms.acceptBefore
            || uint256(r.terms.deliverBefore) + slasher.vetoDuration()
                >= block.timestamp + ISymbioticVault(slasher.vault()).epochDuration()) revert InvalidState();
        recoveries[id].capturedAt = uint48(block.timestamp);
        emit OptedIn(id, msg.sender, uint48(block.timestamp));
    }

    function request(uint256 id, bytes calldata hints) external nonReentrant {
        PaymentGuarantee.Receipt memory r = guarantee.receipt(id);
        Recovery storage rec = recoveries[id];
        if (r.state != PaymentGuarantee.State.Expired || rec.capturedAt == 0 || rec.requested) revert InvalidState();
        rec.requested = true;
        rec.index = slasher.requestSlash(subnetwork, r.terms.executor, r.terms.benefit, rec.capturedAt, hints);
        emit Requested(id, rec.index);
    }

    function execute(uint256 id, bytes calldata hints) external nonReentrant {
        Recovery storage rec = recoveries[id];
        if (!rec.requested || rec.executed) revert InvalidState();
        rec.executed = true;
        rec.executedAmount = slasher.executeSlash(rec.index, hints);
        emit Executed(id, rec.executedAmount);
    }

    /// @notice Distributor pulls from its own realized proceeds. No balance delta can be reused across receipts.
    function remit(uint256 id, uint256 amount) external nonReentrant {
        if (msg.sender != distributor) revert Unauthorized();
        Recovery storage rec = recoveries[id];
        PaymentGuarantee.Receipt memory r = guarantee.receipt(id);
        if (!rec.executed || amount == 0 || rec.received + amount > rec.executedAmount
            || rec.received + amount > r.terms.benefit) revert InvalidInput();
        _collect(msg.sender, amount);
        rec.received += amount;
        reimbursable[r.provider] += amount;
        emit Received(id, amount);
    }

    function withdraw() external nonReentrant {
        uint256 amount = reimbursable[msg.sender];
        if (amount == 0) revert InvalidState();
        delete reimbursable[msg.sender];
        _pay(msg.sender, amount);
    }
}
