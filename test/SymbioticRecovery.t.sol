// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestCollateral} from "./Accountability.t.sol";
import {PaymentGuarantee} from "../src/PaymentGuarantee.sol";
import {SymbioticRecovery, IVetoSlasher} from "../src/adapters/SymbioticRecovery.sol";
import {CollateralModule} from "../src/CollateralModule.sol";

contract VetoFixture {
    address public collateral;
    uint48 public constant epochDuration = 10 days;
    uint48 public constant vetoDuration = 1 days;
    uint256 public requestedAt;
    bool public vetoed;

    constructor(address token) { collateral = token; }
    function vault() external view returns (address) { return address(this); }
    function veto() external { vetoed = true; }
    function requestSlash(bytes32, address, uint256, uint48, bytes calldata) external returns (uint256) {
        requestedAt = block.timestamp;
        return 7;
    }
    function executeSlash(uint256 index, bytes calldata) external view returns (uint256) {
        require(index == 7 && !vetoed && block.timestamp >= requestedAt + vetoDuration, "upstream unavailable");
        return 30;
    }
}

contract SymbioticRecoveryTest is Test {
    TestCollateral token;
    PaymentGuarantee policies;
    SymbioticRecovery recovery;
    VetoFixture upstream;
    address constant OPERATOR = address(303);
    address constant CLIENT = address(404);
    uint256 id;

    function setUp() public {
        token = new TestCollateral();
        policies = new PaymentGuarantee(token);
        upstream = new VetoFixture(address(token));
        recovery = new SymbioticRecovery(policies, IVetoSlasher(address(upstream)), bytes32(uint256(1)), address(this));
        token.mint(address(this), 50);
        token.approve(address(policies), 50);
        id = policies.offer(PaymentGuarantee.Terms(CLIENT, OPERATOR, address(505), 100, 5, 50,
            uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days)));
        vm.prank(OPERATOR);
        recovery.optIn(id);
        token.mint(CLIENT, 105);
        vm.startPrank(CLIENT);
        token.approve(address(policies), 105);
        policies.accept(id);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        policies.expire(id);
        recovery.request(id, "");
    }

    function testPartialUpstreamRecoveryRequiresActualReceipt() public {
        vm.warp(block.timestamp + 1 days);
        recovery.execute(id, "");
        assertEq(recovery.reimbursable(address(this)), 0);
        token.mint(address(this), 30);
        token.approve(address(recovery), 30);
        recovery.remit(id, 20);
        vm.expectRevert(CollateralModule.InvalidInput.selector);
        recovery.remit(id, 11);
        recovery.remit(id, 10);
        recovery.withdraw();
        assertEq(token.balanceOf(address(this)), 30);
        assertEq(policies.credit(CLIENT), 155);
    }

    function testVetoLeavesCustomerEntitlementIntact() public {
        upstream.veto();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert();
        recovery.execute(id, "");
        vm.prank(CLIENT);
        policies.withdraw();
        assertEq(token.balanceOf(CLIENT), 155);
        assertEq(recovery.reimbursable(address(this)), 0);
    }
}
