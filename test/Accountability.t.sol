// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {CollateralModule} from "../src/CollateralModule.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {FailurePredictionMarket} from "../src/FailurePredictionMarket.sol";
import {UnderwritingVault} from "../src/UnderwritingVault.sol";
import {IIncidentOracle} from "../src/interfaces/IIncidentOracle.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract TestCollateral is ERC20 {
    constructor() ERC20("Test Collateral", "TEST") {}
    function mint(address recipient, uint256 amount) external { _mint(recipient, amount); }
}

contract AccountabilityTest is Test {
    TestCollateral private token;
    MockOracle private oracle;
    AgentRegistry private registry;
    UnderwritingVault private vault;
    FailurePredictionMarket private market;
    CompensationEscrow private escrow;

    address private constant PROVIDER = address(0x100);
    address private constant STAKER_A = address(0x101);
    address private constant STAKER_B = address(0x102);
    address private constant YES_TRADER = address(0x103);
    address private constant NO_TRADER = address(0x104);
    address private constant VICTIM_A = address(0x105);
    address private constant VICTIM_B = address(0x106);
    address private constant CHALLENGER = address(0x107);
    address private constant ARBITRATOR = address(0x108);
    address private constant TREASURY = address(0x109);
    uint256 private constant KEY_A = 0xBEEF;
    uint256 private constant KEY_B = 0xCAFE;
    uint256 private constant KEY_C = 0xD00D;
    uint256 private constant CAP = 1_000 ether;
    bytes32 private constant CLAIM_A = keccak256("claim A");
    bytes32 private constant CLAIM_B = keccak256("claim B");
    bytes32 private constant EVIDENCE = keccak256("deterministic execution trace");
    uint256 private agentId;
    uint256 private epochId;
    uint64 private opensAt;
    uint64 private endsAt;

    function setUp() public {
        token = new TestCollateral();
        address[] memory committee = new address[](3);
        committee[0] = vm.addr(KEY_A);
        committee[1] = vm.addr(KEY_B);
        committee[2] = vm.addr(KEY_C);
        oracle = new MockOracle(
            token, ARBITRATOR, TREASURY, [uint64(1 days), 1 days, 2 days], [uint256(10 ether), 5 ether], committee, 2
        );
        registry = new AgentRegistry(token, address(oracle), 25 ether);
        vault = new UnderwritingVault(token, address(oracle));
        market = new FailurePredictionMarket(token, address(oracle), 500, TREASURY);
        escrow = new CompensationEscrow(token, address(oracle));
        oracle.bind(registry, vault, market, escrow);

        for (uint256 i; i < committee.length; ++i) {
            _fund(committee[i], address(oracle), 10 ether);
            vm.prank(committee[i]);
            oracle.bondAttester();
        }

        _fund(PROVIDER, address(registry), 100 ether);
        vm.prank(PROVIDER);
        agentId = registry.register("ipfs://agent-manifest", 2, 100 ether);
        opensAt = uint64(block.timestamp + 1 days);
        endsAt = opensAt + 3 days;
        MockOracle.Terms memory terms = MockOracle.Terms(
            opensAt, endsAt, CAP, [uint256(50 ether), 200 ether, 500 ether], keccak256("workflow-v1")
        );
        vm.prank(PROVIDER);
        epochId = oracle.openEpoch(agentId, terms);
    }

    function testNoFailureDistributesPremiumAndTraderPot() public {
        _stake(STAKER_A, 600 ether);
        _stake(STAKER_B, 400 ether);
        _fund(address(this), address(vault), 100 ether);
        vault.fundPremium(epochId, 100 ether);
        _trade(YES_TRADER, true, 100 ether);
        _trade(NO_TRADER, false, 300 ether);
        (uint256 implied, bool traded) = market.impliedFailureBps(epochId);
        assertTrue(traded);
        assertEq(implied, 2500);

        _assertReport(_noFailure());
        _finalizeUnchallenged();
        assertEq(uint256(oracle.outcome(epochId)), uint256(IIncidentOracle.Outcome.NoFailure));
        vm.prank(STAKER_A);
        assertEq(vault.redeem(epochId), 660 ether);
        vm.prank(STAKER_B);
        assertEq(vault.redeem(epochId), 440 ether);
        vm.prank(NO_TRADER);
        assertEq(market.claim(epochId), 380 ether);
        vm.prank(YES_TRADER);
        assertEq(market.claim(epochId), 0);
        assertEq(token.balanceOf(TREASURY), 20 ether);
        vm.prank(PROVIDER);
        registry.withdrawBond(agentId, 100 ether);
        assertEq(token.balanceOf(PROVIDER), 100 ether);
    }

    function testDisputedFailureSlashesAndCompensatesVictimsProRata() public {
        _stake(STAKER_A, 200 ether);
        _stake(STAKER_B, 100 ether);
        _trade(YES_TRADER, true, 100 ether);
        _trade(NO_TRADER, false, 300 ether);
        bytes32 a = escrow.claimLeaf(epochId, CLAIM_A, VICTIM_A, 400 ether);
        bytes32 b = escrow.claimLeaf(epochId, CLAIM_B, VICTIM_B, 200 ether);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        _assertReport(IIncidentOracle.Report(epochId, 600 ether, 0, EVIDENCE, root, 600 ether));
        _challenge();
        vm.warp(oracle.getAssertion(epochId).challengeEnds);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        oracle.finalize(epochId);
        vm.expectRevert(CollateralModule.Unauthorized.selector);
        oracle.arbitrate(epochId, true);
        vm.prank(ARBITRATOR);
        oracle.arbitrate(epochId, true);

        (, , uint256 credibility, uint256 bond, uint256 activeEpoch, uint256 incidents,) = registry.agents(agentId);
        assertEq(credibility, 4000);
        assertEq(bond, 0);
        assertEq(activeEpoch, 0);
        assertEq(incidents, 1);
        assertEq(token.balanceOf(address(escrow)), 420 ether);
        assertEq(oracle.bondCredit(address(this)), 10 ether);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        vm.expectRevert(CollateralModule.InvalidInput.selector);
        escrow.claim(epochId, CLAIM_A, VICTIM_B, 400 ether, proof);
        assertEq(escrow.claim(epochId, CLAIM_A, VICTIM_A, 400 ether, proof), 280 ether);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        escrow.claim(epochId, CLAIM_A, VICTIM_A, 400 ether, proof);
        proof[0] = a;
        assertEq(escrow.claim(epochId, CLAIM_B, VICTIM_B, 200 ether, proof), 140 ether);
        assertEq(token.balanceOf(VICTIM_A), 280 ether);
        assertEq(token.balanceOf(VICTIM_B), 140 ether);
        assertEq(token.balanceOf(address(escrow)), 0);
        vm.prank(YES_TRADER);
        assertEq(market.claim(epochId), 380 ether);
        vm.prank(STAKER_A);
        assertEq(vault.redeem(epochId), 0);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        oracle.finalize(epochId);
    }

    function testSeverityScheduleIsFixedAndSlashOnlyCoversUnfundedLoss() public {
        _stake(STAKER_A, 1_000 ether);
        IIncidentOracle.Report memory report = _singleClaim(200 ether);
        report.exactLoss = 0;
        report.severity = 2;
        _assertReport(report);
        _finalizeUnchallenged();
        assertEq(escrow.claim(epochId, CLAIM_A, VICTIM_A, 200 ether, new bytes32[](0)), 200 ether);
        vm.prank(STAKER_A);
        assertEq(vault.redeem(epochId), 900 ether);
    }

    function testAssertionChallengeAndStakeExitBoundaries() public {
        _stake(STAKER_A, 100 ether);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        vault.redeem(epochId);
        vm.startPrank(PROVIDER);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        registry.withdrawBond(agentId, 1);
        vm.stopPrank();
        vm.expectRevert(CollateralModule.Unauthorized.selector);
        vault.slash(epochId, 100 ether, VICTIM_A);
        vm.warp(opensAt);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        market.buy(epochId, true, 100 ether);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        vault.stake(epochId, 100 ether);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        oracle.assertReport(_noFailure(), new bytes[](0));
        _assertReport(_noFailure());
        vm.expectRevert(CollateralModule.InvalidState.selector);
        oracle.finalize(epochId);
        vm.warp(oracle.getAssertion(epochId).challengeEnds);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        oracle.challenge(epochId, EVIDENCE);
        oracle.finalize(epochId);
    }

    function testChallengeRejectionVoidsAndRefundsTradersWithFees() public {
        _trade(YES_TRADER, true, 100 ether);
        _assertReport(_singleClaim(500 ether));
        _challenge();
        vm.warp(oracle.getAssertion(epochId).challengeEnds);
        vm.prank(ARBITRATOR);
        oracle.arbitrate(epochId, false);
        assertEq(uint256(oracle.outcome(epochId)), uint256(IIncidentOracle.Outcome.Void));
        assertEq(oracle.bondCredit(CHALLENGER), 10 ether);
        vm.prank(CHALLENGER);
        oracle.withdrawCredit();
        assertEq(token.balanceOf(CHALLENGER), 10 ether);
        vm.prank(YES_TRADER);
        assertEq(market.claim(epochId), 100 ether);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testArbitrationTimeoutUnlocksCapitalAndReturnsBonds() public {
        _stake(STAKER_A, 80 ether);
        _assertReport(_singleClaim(600 ether));
        _challenge();
        vm.warp(oracle.getAssertion(epochId).arbitrationEnds);
        vm.prank(ARBITRATOR);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        oracle.arbitrate(epochId, true);
        oracle.finalize(epochId);
        assertEq(uint256(oracle.outcome(epochId)), uint256(IIncidentOracle.Outcome.Void));
        assertEq(oracle.bondCredit(CHALLENGER), 5 ether);
        assertEq(oracle.bondCredit(address(this)), 5 ether);
        vm.prank(STAKER_A);
        assertEq(vault.redeem(epochId), 80 ether);
    }

    function testMissingReportVoidsAtReportingDeadline() public {
        _trade(NO_TRADER, false, 100 ether);
        vm.warp(endsAt + oracle.reportingWindow());
        oracle.finalize(epochId);
        assertEq(uint256(oracle.outcome(epochId)), uint256(IIncidentOracle.Outcome.Void));
        vm.prank(NO_TRADER);
        assertEq(market.claim(epochId), 100 ether);
    }

    function testDoubleSigningHasIndependentPenaltyAndRemovesQuorum() public {
        IIncidentOracle.Report memory first = _singleClaim(240 ether);
        IIncidentOracle.Report memory second = _noFailure();
        _assertReport(first);
        bytes memory sigA = _sign(KEY_A, oracle.reportDigest(first));
        bytes memory sigB = _sign(KEY_A, oracle.reportDigest(second));
        oracle.proveDoubleSign(first, sigA, second, sigB);
        assertEq(oracle.attesterCollateral(vm.addr(KEY_A)), 0);
        assertEq(oracle.attesterCredibility(vm.addr(KEY_A)), 0);
        assertEq(oracle.bondCredit(TREASURY), 10 ether);
        vm.expectRevert(CollateralModule.InvalidInput.selector);
        oracle.proveDoubleSign(second, sigB, first, sigA);
        _finalizeUnchallenged();
        assertEq(uint256(oracle.outcome(epochId)), uint256(IIncidentOracle.Outcome.Void));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testDuplicateAttesterAndInconsistentLossRejected() public {
        vm.warp(endsAt);
        IIncidentOracle.Report memory report = _singleClaim(240 ether);
        bytes[] memory signatures = _signatures(report);
        signatures[1] = signatures[0];
        vm.expectRevert(CollateralModule.InvalidInput.selector);
        oracle.assertReport(report, signatures);
        report.totalClaims = 1;
        bytes[] memory invalidReportSignatures = _signatures(report);
        vm.expectRevert(CollateralModule.InvalidInput.selector);
        oracle.assertReport(report, invalidReportSignatures);
    }

    function testFuzzSlashIsBoundedByVerifiedLossCapAndPrincipal(uint96 rawLoss, uint96 rawPrincipal) public {
        uint256 loss = bound(rawLoss, 1, 10_000 ether);
        uint256 principal = bound(rawPrincipal, 1, 2_000 ether);
        _stake(STAKER_A, principal);
        _assertReport(_singleClaim(loss));
        _finalizeUnchallenged();
        uint256 recognized = loss < CAP ? loss : CAP;
        uint256 funded = recognized < 100 ether + principal ? recognized : 100 ether + principal;
        uint256 slashed = funded > 100 ether ? funded - 100 ether : 0;
        assertEq(escrow.claim(epochId, CLAIM_A, VICTIM_A, loss, new bytes32[](0)), funded);
        vm.prank(STAKER_A);
        assertEq(vault.redeem(epochId), principal - slashed);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testFuzzParimutuelWinnerAndReserveConserveFunds(uint96 rawYes, uint96 rawNo) public {
        uint256 yes = bound(rawYes, 2, 10_000 ether);
        uint256 no = bound(rawNo, 2, 10_000 ether);
        _trade(YES_TRADER, true, yes);
        _trade(NO_TRADER, false, no);
        _assertReport(_noFailure());
        _finalizeUnchallenged();
        uint256 fees = (yes + 19) / 20 + (no + 19) / 20;
        vm.prank(NO_TRADER);
        assertEq(market.claim(epochId), yes + no - fees);
        assertEq(token.balanceOf(TREASURY), fees);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function _fund(address account, address spender, uint256 amount) private {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(spender, amount);
    }

    function _stake(address account, uint256 amount) private {
        _fund(account, address(vault), amount);
        vm.prank(account);
        vault.stake(epochId, amount);
    }

    function _trade(address account, bool fail, uint256 amount) private {
        _fund(account, address(market), amount);
        vm.prank(account);
        market.buy(epochId, fail, amount);
    }

    function _noFailure() private view returns (IIncidentOracle.Report memory) {
        return IIncidentOracle.Report(epochId, 0, 0, EVIDENCE, bytes32(0), 0);
    }

    function _singleClaim(uint256 loss) private view returns (IIncidentOracle.Report memory) {
        return IIncidentOracle.Report(epochId, loss, 0, EVIDENCE, escrow.claimLeaf(epochId, CLAIM_A, VICTIM_A, loss), loss);
    }

    function _assertReport(IIncidentOracle.Report memory report) private {
        vm.warp(endsAt);
        _fund(address(this), address(oracle), oracle.disputeBond());
        oracle.assertReport(report, _signatures(report));
    }

    function _signatures(IIncidentOracle.Report memory report) private view returns (bytes[] memory signatures) {
        bytes32 digest = oracle.reportDigest(report);
        signatures = new bytes[](2);
        signatures[0] = _sign(KEY_A, digest);
        signatures[1] = _sign(KEY_B, digest);
    }

    function _sign(uint256 key, bytes32 digest) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _finalizeUnchallenged() private {
        vm.warp(oracle.getAssertion(epochId).challengeEnds);
        oracle.finalize(epochId);
    }

    function _challenge() private {
        _fund(CHALLENGER, address(oracle), oracle.disputeBond());
        vm.prank(CHALLENGER);
        oracle.challenge(epochId, keccak256("counter-evidence"));
    }
}
