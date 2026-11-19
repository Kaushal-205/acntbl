// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestCollateral} from "./Accountability.t.sol";
import {PaymentGuarantee} from "../src/PaymentGuarantee.sol";
import {CollateralModule} from "../src/CollateralModule.sol";

contract PaymentGuaranteeTest is Test {
    TestCollateral token;
    PaymentGuarantee guarantee;
    address constant CUSTOMER = address(1_001);
    address constant RECIPIENT = address(1_002);

    function setUp() public {
        token = new TestCollateral();
        guarantee = new PaymentGuarantee(token);
        token.approve(address(guarantee), type(uint256).max);
        vm.prank(CUSTOMER);
        token.approve(address(guarantee), type(uint256).max);
    }

    function issue(uint128 payment, uint128 benefit) private returns (uint256 id) {
        token.mint(address(this), benefit);
        token.mint(CUSTOMER, uint256(payment) + 5);
        id = guarantee.offer(PaymentGuarantee.Terms(
            CUSTOMER, address(this), RECIPIENT, payment, 5, benefit,
            uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days)
        ));
        vm.prank(CUSTOMER);
        guarantee.accept(id);
    }

    function testFuzzConcurrentReceiptsRemainSolvent(uint96 a, uint96 b) public {
        uint128 payment = uint128(bound(a, 1, type(uint96).max));
        uint128 benefit = uint128(bound(b, 1, type(uint96).max));
        uint256 first = issue(payment, benefit);
        uint256 second = issue(payment, benefit);
        guarantee.deliver(first);
        assertEq(token.balanceOf(RECIPIENT), payment);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        guarantee.deliver(second);
        guarantee.expire(second);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        guarantee.expire(second);
        guarantee.withdraw();
        vm.prank(CUSTOMER);
        guarantee.withdraw();
        assertEq(token.balanceOf(CUSTOMER), uint256(payment) + 5 + benefit);
        assertEq(token.balanceOf(address(this)), uint256(benefit) + 5);
        assertEq(token.balanceOf(address(guarantee)), 0);
    }

    function testCannotCancelOrRedirectAnAcceptedPayment() public {
        uint256 id = issue(100, 50);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        guarantee.cancel(id);
        vm.prank(CUSTOMER);
        vm.expectRevert(CollateralModule.Unauthorized.selector);
        guarantee.deliver(id);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        guarantee.expire(id);
    }
}
