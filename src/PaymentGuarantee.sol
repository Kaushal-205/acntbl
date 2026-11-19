// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CollateralModule, IERC20} from "./CollateralModule.sol";

/// @notice A provider guarantees that its executor will deliver a funded payment before a fixed deadline.
/// A missed deadline pays the client's pre-agreed benefit, independently of committee availability.
contract PaymentGuarantee is CollateralModule {
    enum State { Offered, Active, Delivered, Expired, Cancelled }

    struct Terms {
        address client;
        address executor;
        address beneficiary;
        uint128 payment;
        uint128 premium;
        uint128 benefit;
        uint64 acceptBefore;
        uint64 deliverBefore;
    }

    struct Receipt {
        address provider;
        State state;
        Terms terms;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Receipt) private receipts;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public deliveries;
    mapping(address => uint256) public missedDeadlines;
    mapping(address => uint256) public benefitsAccrued;
    event Offered(uint256 indexed id, address indexed provider, address indexed client);
    event Activated(uint256 indexed id);
    event Closed(uint256 indexed id, State state);
    event Withdrawn(address indexed account, uint256 amount);

    constructor(IERC20 token) CollateralModule(token, address(this)) {}

    function receipt(uint256 id) external view returns (Receipt memory) {
        return receipts[id];
    }

    function offer(Terms calldata terms) external nonReentrant returns (uint256 id) {
        if (terms.client == address(0) || terms.executor == address(0) || terms.beneficiary == address(0)
            || terms.beneficiary == address(this) || terms.payment == 0 || terms.benefit == 0 || terms.premium == 0
            || terms.acceptBefore <= block.timestamp || terms.deliverBefore <= terms.acceptBefore) revert InvalidInput();
        id = nextId++;
        receipts[id] = Receipt(msg.sender, State.Offered, terms);
        _collect(msg.sender, terms.benefit);
        emit Offered(id, msg.sender, terms.client);
    }

    function accept(uint256 id) external nonReentrant {
        Receipt storage r = receipts[id];
        if (r.terms.client != msg.sender) revert Unauthorized();
        if (r.state != State.Offered || block.timestamp >= r.terms.acceptBefore) revert InvalidState();
        r.state = State.Active;
        _collect(msg.sender, uint256(r.terms.payment) + r.terms.premium);
        emit Activated(id);
    }

    function cancel(uint256 id) external {
        Receipt storage r = receipts[id];
        if (r.provider != msg.sender) revert Unauthorized();
        if (r.state != State.Offered) revert InvalidState();
        r.state = State.Cancelled;
        credit[r.provider] += r.terms.benefit;
        emit Closed(id, r.state);
    }

    function deliver(uint256 id) external nonReentrant {
        Receipt storage r = receipts[id];
        if (msg.sender != r.terms.executor) revert Unauthorized();
        if (r.state != State.Active || block.timestamp >= r.terms.deliverBefore) revert InvalidState();
        r.state = State.Delivered;
        ++deliveries[r.provider];
        credit[r.provider] += uint256(r.terms.benefit) + r.terms.premium;
        uint256 beforeBalance = collateral.balanceOf(r.terms.beneficiary);
        _pay(r.terms.beneficiary, r.terms.payment);
        if (collateral.balanceOf(r.terms.beneficiary) - beforeBalance != r.terms.payment) revert UnsupportedCollateral();
        emit Closed(id, r.state);
    }

    function expire(uint256 id) external {
        Receipt storage r = receipts[id];
        if (r.state != State.Active || block.timestamp < r.terms.deliverBefore) revert InvalidState();
        r.state = State.Expired;
        ++missedDeadlines[r.provider];
        benefitsAccrued[r.provider] += r.terms.benefit;
        credit[r.terms.client] += uint256(r.terms.payment) + r.terms.premium + r.terms.benefit;
        emit Closed(id, r.state);
    }

    function withdraw() external nonReentrant {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert InvalidState();
        delete credit[msg.sender];
        _pay(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
