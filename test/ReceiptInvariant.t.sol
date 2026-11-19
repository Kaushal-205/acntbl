// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PaymentGuarantee} from "../src/PaymentGuarantee.sol";
import {TestCollateral} from "./Accountability.t.sol";

contract ReceiptHandler is Test {
    TestCollateral immutable token;
    PaymentGuarantee immutable policies;
    address public constant CLIENT = address(9001);
    address constant BENEFICIARY = address(9002);
    uint256 public reserved;
    uint256 public expectedClientCredit;
    uint256 public expectedProviderCredit;
    uint256[] private active;

    constructor(TestCollateral asset, PaymentGuarantee guarantees) {
        token = asset;
        policies = guarantees;
        asset.approve(address(guarantees), type(uint256).max);
        vm.prank(CLIENT);
        asset.approve(address(guarantees), type(uint256).max);
    }

    function issue(uint64 rawPayment, uint64 rawBenefit) external {
        uint128 payment = uint128(rawPayment) + 1;
        uint128 benefit = uint128(rawBenefit) + 1;
        token.mint(address(this), benefit);
        token.mint(CLIENT, payment + 1);
        uint256 id = policies.offer(PaymentGuarantee.Terms(
            CLIENT, address(this), BENEFICIARY, payment, 1, benefit,
            uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 days)
        ));
        vm.prank(CLIENT);
        policies.accept(id);
        reserved += uint256(payment) + 1 + benefit;
        active.push(id);
    }

    function progress(uint32 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 0, 2 days));
    }

    function close(uint256 seed) external {
        if (active.length == 0) return;
        uint256 index = seed % active.length;
        uint256 id = active[index];
        active[index] = active[active.length - 1];
        active.pop();
        PaymentGuarantee.Terms memory t = policies.receipt(id).terms;
        uint256 liability = uint256(t.payment) + t.benefit + t.premium;
        reserved -= liability;
        if (block.timestamp >= t.deliverBefore) {
            policies.expire(id);
            expectedClientCredit += liability;
        } else {
            policies.deliver(id);
            expectedProviderCredit += uint256(t.benefit) + t.premium;
        }
    }

    function collect(bool customer) external {
        if (customer && expectedClientCredit > 0) {
            expectedClientCredit = 0;
            vm.prank(CLIENT);
            policies.withdraw();
        } else if (!customer && expectedProviderCredit > 0) {
            expectedProviderCredit = 0;
            policies.withdraw();
        }
    }
}

contract ReceiptInvariantTest is Test {
    TestCollateral token;
    PaymentGuarantee policies;
    ReceiptHandler handler;

    function setUp() public {
        token = new TestCollateral();
        policies = new PaymentGuarantee(token);
        handler = new ReceiptHandler(token, policies);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.issue.selector;
        selectors[1] = handler.progress.selector;
        selectors[2] = handler.close.selector;
        selectors[3] = handler.collect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_AllActiveAndSettledLiabilitiesAreFullyFunded() public view {
        assertEq(policies.credit(handler.CLIENT()), handler.expectedClientCredit());
        assertEq(policies.credit(address(handler)), handler.expectedProviderCredit());
        assertEq(token.balanceOf(address(policies)),
            handler.reserved() + handler.expectedProviderCredit() + handler.expectedClientCredit());
    }
}
