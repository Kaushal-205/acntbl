// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {CollateralModule, IERC20} from "../CollateralModule.sol";
import {AgentRegistry} from "../AgentRegistry.sol";
import {CompensationEscrow} from "../CompensationEscrow.sol";
import {FailurePredictionMarket} from "../FailurePredictionMarket.sol";
import {IIncidentOracle} from "../interfaces/IIncidentOracle.sol";
import {IUnderwritingVault} from "../interfaces/IUnderwritingVault.sol";

contract MockOracle is IIncidentOracle, CollateralModule, EIP712 {
    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "Report(uint256 epochId,uint256 exactLoss,uint8 severity,bytes32 evidenceHash,bytes32 claimsRoot,uint256 totalClaims)"
    );
    uint256 public constant MAX_ATTESTERS = 32;

    bytes32 public constant CORRECTION_TYPEHASH = keccak256("Correction(bytes32 reportDigest)");
    mapping(uint256 => uint256) public correctionDeadline;
    event CorrectionOpened(uint256 indexed epochId, uint256 deadline);

    struct Terms {
        uint64 opensAt;
        uint64 endsAt;
        uint256 lossCap;
        uint256[3] severityAmounts;
        bytes32 workflowHash;
    }

    struct Epoch {
        uint256 agentId;
        Terms terms;
        Outcome result;
    }

    struct Assertion {
        Report report;
        address proposer;
        address challenger;
        uint64 challengeEnds;
        uint64 arbitrationEnds;
        uint256 signers;
    }

    address[] public committee;
    mapping(address => bool) public retired;
    mapping(address => uint256) public lockedUntil;
    mapping(uint256 => mapping(address => uint256)) public epochBit;
    mapping(uint256 => uint256) public evidenceDeadline;
    event CommitteeReplaced(address indexed prior, address indexed replacement);

    address public immutable deployer;
    address public immutable arbitrator;
    address public immutable penaltyRecipient;
    uint64 public immutable reportingWindow;
    uint64 public immutable challengeWindow;
    uint64 public immutable arbitrationWindow;
    uint256 public immutable attesterBond;
    uint256 public immutable disputeBond;
    uint256 public immutable quorum;

    AgentRegistry public registry;
    CompensationEscrow public escrow;
    FailurePredictionMarket public market;
    IUnderwritingVault public vault;
    uint256 public nextEpochId = 1;

    mapping(uint256 => Epoch) private epochs;
    mapping(uint256 => Assertion) private assertions;
    mapping(address => uint256) public attesterBit;
    mapping(address => uint256) public attesterCollateral;
    mapping(address => uint256) public attesterCredibility;
    mapping(uint256 => uint256) public disqualifiedSigners;
    mapping(address => uint256) public bondCredit;

    event EpochOpened(uint256 indexed epochId, uint256 indexed agentId, bytes32 workflowHash);
    event AttesterBonded(address indexed attester);
    event ReportAsserted(uint256 indexed epochId, bytes32 indexed digest, address indexed proposer, uint64 challengeEnds);
    event ReportChallenged(uint256 indexed epochId, address indexed challenger, bytes32 counterEvidenceHash);
    event DoubleSignProven(uint256 indexed epochId, address indexed attester, uint256 collateralForfeited);
    event EpochSettled(uint256 indexed epochId, Outcome result, uint256 recognizedLoss, uint256 funded, bytes32 evidenceHash);

    constructor(
        IERC20 token,
        address resolver,
        address treasury,
        uint64[3] memory windows,
        uint256[2] memory bonds,
        address[] memory attesters,
        uint256 threshold
    ) CollateralModule(token, address(this)) EIP712("AI Accountability Oracle", "1") {
        if (resolver == address(0) || treasury == address(0) || threshold <= attesters.length / 2
            || threshold > attesters.length || attesters.length > MAX_ATTESTERS || windows[0] == 0
            || windows[1] == 0 || windows[2] == 0 || windows[0] > 30 days || windows[1] > 30 days
            || windows[2] > 30 days || bonds[0] == 0 || bonds[1] == 0 || bonds[1] > type(uint256).max / 2) {
            revert InvalidInput();
        }
        deployer = msg.sender;
        arbitrator = resolver;
        penaltyRecipient = treasury;
        (reportingWindow, challengeWindow, arbitrationWindow) = (windows[0], windows[1], windows[2]);
        (attesterBond, disputeBond) = (bonds[0], bonds[1]);
        quorum = threshold;

        for (uint256 i; i < attesters.length; ++i) {
            address signer = attesters[i];
            if (signer == address(0) || attesterBit[signer] != 0) revert InvalidInput();
            committee.push(signer);
            attesterBit[signer] = 1 << i;
            attesterCredibility[signer] = 10_000;
        }
    }

    function bind(
        AgentRegistry agentRegistry,
        IUnderwritingVault underwritingVault,
        FailurePredictionMarket predictionMarket,
        CompensationEscrow compensationEscrow
    ) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (address(registry) != address(0)) revert InvalidState();
        _checkModule(CollateralModule(address(agentRegistry)));
        _checkModule(CollateralModule(address(underwritingVault)));
        _checkModule(CollateralModule(address(predictionMarket)));
        _checkModule(CollateralModule(address(compensationEscrow)));
        registry = agentRegistry;
        vault = underwritingVault;
        market = predictionMarket;
        escrow = compensationEscrow;
    }

    function _checkModule(CollateralModule module) private view {
        if (address(module).code.length == 0 || module.coordinator() != address(this)
            || address(module.collateral()) != address(collateral)) revert InvalidInput();
    }

    function bondAttester() external nonReentrant {
        if (retired[msg.sender] || attesterBit[msg.sender] == 0 || attesterCollateral[msg.sender] != 0
            || attesterCredibility[msg.sender] == 0) revert InvalidState();
        attesterCollateral[msg.sender] = attesterBond;
        _collect(msg.sender, attesterBond);
        emit AttesterBonded(msg.sender);
    }

    function retire() external {
        if (attesterBit[msg.sender] == 0) revert Unauthorized();
        retired[msg.sender] = true;
    }

    function withdrawAttesterBond() external nonReentrant {
        if (!retired[msg.sender] || block.timestamp <= lockedUntil[msg.sender]) revert InvalidState();
        uint256 amount = attesterCollateral[msg.sender];
        if (amount == 0) revert InvalidState();
        delete attesterCollateral[msg.sender];
        _pay(msg.sender, amount);
    }

    function replaceSeat(uint256 seat, address replacement) external {
        if (msg.sender != arbitrator) revert Unauthorized();
        address prior = committee[seat];
        if ((!retired[prior] && attesterCredibility[prior] != 0) || replacement == address(0)
            || attesterBit[replacement] != 0) revert InvalidInput();
        committee[seat] = replacement;
        attesterBit[replacement] = 1 << seat;
        attesterCredibility[replacement] = 10_000;
        emit CommitteeReplaced(prior, replacement);
    }

    function _snapshot(uint256 epochId, uint64 endsAt) private {
        uint256 deadline = uint256(endsAt) + 2 * (uint256(reportingWindow) + challengeWindow + arbitrationWindow);
        evidenceDeadline[epochId] = deadline;
        uint256 members;
        for (uint256 i; i < committee.length; ++i) {
            address signer = committee[i];
            if (!retired[signer] && attesterCollateral[signer] == attesterBond) {
                epochBit[epochId][signer] = attesterBit[signer];
                lockedUntil[signer] = Math.max(lockedUntil[signer], deadline);
                ++members;
            }
        }
        if (members < quorum) revert InvalidState();
    }

    function openEpoch(uint256 agentId, Terms calldata terms) external nonReentrant returns (uint256 epochId) {
        if (address(registry) == address(0) || terms.opensAt <= block.timestamp || terms.endsAt <= terms.opensAt
            || terms.endsAt > block.timestamp + 365 days || terms.workflowHash == bytes32(0) || terms.lossCap == 0
            || terms.severityAmounts[0] == 0 || terms.severityAmounts[0] >= terms.severityAmounts[1]
            || terms.severityAmounts[1] >= terms.severityAmounts[2] || terms.severityAmounts[2] > terms.lossCap) {
            revert InvalidInput();
        }
        epochId = nextEpochId++;
        epochs[epochId] = Epoch(agentId, terms, Outcome.Pending);
        _snapshot(epochId, terms.endsAt);
        registry.lock(agentId, epochId, msg.sender);
        vault.openPool(epochId, terms.opensAt);
        market.openMarket(epochId, terms.opensAt);
        emit EpochOpened(epochId, agentId, terms.workflowHash);
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return epochs[epochId];
    }

    function getAssertion(uint256 epochId) external view returns (Assertion memory) {
        return assertions[epochId];
    }

    function outcome(uint256 epochId) external view returns (Outcome) {
        return epochs[epochId].result;
    }

    function reportDigest(Report calldata report) public view returns (bytes32) {
        return _roundDigest(report, correctionDeadline[report.epochId] != 0);
    }

    function _roundDigest(Report calldata report, bool correction) private view returns (bytes32) {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            REPORT_TYPEHASH, report.epochId, report.exactLoss, report.severity, report.evidenceHash,
            report.claimsRoot, report.totalClaims
        )));
        return correction ? _hashTypedDataV4(keccak256(abi.encode(CORRECTION_TYPEHASH, digest))) : digest;
    }

    mapping(bytes32 => bool) public evidenceAvailable;
    event EvidencePublished(bytes32 indexed digest, bytes evidence);

    function publishEvidence(bytes calldata evidence) external {
        if (evidence.length == 0 || evidence.length > 24_576) revert InvalidInput();
        bytes32 digest = keccak256(evidence);
        if (!evidenceAvailable[digest]) {
            evidenceAvailable[digest] = true;
            emit EvidencePublished(digest, evidence);
        }
    }

    function assertReport(Report calldata report, bytes[] calldata signatures) external nonReentrant {
        Epoch storage epoch = epochs[report.epochId];
        if (epoch.agentId == 0 || block.timestamp < epoch.terms.endsAt
            || block.timestamp >= _reportDeadline(report.epochId)
            || epoch.result != Outcome.Pending || assertions[report.epochId].proposer != address(0)) {
            revert InvalidState();
        }
        _validateReport(epoch.terms, report);
        if (!evidenceAvailable[report.evidenceHash] || (report.totalClaims != 0
            && escrow.publishedTotal(report.epochId, report.claimsRoot) != report.totalClaims)) revert InvalidInput();
        bytes32 digest = reportDigest(report);
        uint256 signed = _verifySignatures(report.epochId, digest, signatures);
        uint64 challengeEnds = uint64(block.timestamp) + challengeWindow;
        assertions[report.epochId] = Assertion(report, msg.sender, address(0), challengeEnds, 0, signed);
        _collect(msg.sender, disputeBond);
        emit ReportAsserted(report.epochId, digest, msg.sender, challengeEnds);
    }

    function _verifySignatures(uint256 epochId, bytes32 digest, bytes[] calldata signatures)
        private view returns (uint256 signed)
    {
        if (signatures.length < quorum || signatures.length > MAX_ATTESTERS) revert InvalidInput();
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            uint256 bit = epochBit[epochId][signer];
            if (bit == 0 || attesterCollateral[signer] != attesterBond
                || ((signed | disqualifiedSigners[epochId]) & bit) != 0) revert InvalidInput();
            signed |= bit;
        }
    }

    function _validateReport(Terms storage terms, Report calldata report) private view {
        if (report.evidenceHash == bytes32(0) || report.severity > 3
            || (report.exactLoss != 0 && report.severity != 0)) revert InvalidInput();
        uint256 loss = report.severity == 0 ? report.exactLoss : terms.severityAmounts[report.severity - 1];
        if (report.totalClaims != loss || (report.claimsRoot == bytes32(0)) != (loss == 0)) {
            revert InvalidInput();
        }
    }

    function challenge(uint256 epochId, bytes32 counterEvidenceHash) external nonReentrant {
        Assertion storage assertion = assertions[epochId];
        if (assertion.proposer == address(0) || assertion.challenger != address(0)
            || block.timestamp >= assertion.challengeEnds || epochs[epochId].result != Outcome.Pending) {
            revert InvalidState();
        }
        if (counterEvidenceHash == bytes32(0) || msg.sender == assertion.proposer) revert InvalidInput();
        assertion.challenger = msg.sender;
        assertion.arbitrationEnds = assertion.challengeEnds + arbitrationWindow;
        _collect(msg.sender, disputeBond);
        emit ReportChallenged(epochId, msg.sender, counterEvidenceHash);
    }

    function proveDoubleSign(Report calldata first, bytes calldata sigA, Report calldata second, bytes calldata sigB)
        external nonReentrant
    {
        _prove(first, sigA, second, sigB, false);
    }

    function proveCorrectionDoubleSign(Report calldata first, bytes calldata sigA, Report calldata second, bytes calldata sigB)
        external nonReentrant
    {
        if (correctionDeadline[first.epochId] == 0) revert InvalidState();
        _prove(first, sigA, second, sigB, true);
    }

    function _prove(Report calldata first, bytes calldata sigA, Report calldata second, bytes calldata sigB, bool correction)
        private
    {
        uint256 epochId = first.epochId;
        if (block.timestamp > evidenceDeadline[epochId] || epochId != second.epochId || epochs[epochId].agentId == 0
            || block.timestamp < epochs[epochId].terms.endsAt) revert InvalidInput();
        bytes32 digestA = _roundDigest(first, correction);
        bytes32 digestB = _roundDigest(second, correction);
        if (first.exactLoss == second.exactLoss && first.severity == second.severity
            && first.claimsRoot == second.claimsRoot && first.totalClaims == second.totalClaims) revert InvalidInput();
        _validateReport(epochs[epochId].terms, first);
        _validateReport(epochs[epochId].terms, second);
        address signer = ECDSA.recover(digestA, sigA);
        uint256 bit = epochBit[epochId][signer];
        if (bit == 0 || signer != ECDSA.recover(digestB, sigB)
            || (disqualifiedSigners[epochId] & bit) != 0) revert InvalidInput();
        disqualifiedSigners[epochId] |= bit;
        uint256 forfeited = attesterCollateral[signer];
        attesterCollateral[signer] = 0;
        attesterCredibility[signer] = 0;
        bondCredit[penaltyRecipient] += forfeited;
        emit DoubleSignProven(epochId, signer, forfeited);
    }

    function finalize(uint256 epochId) external nonReentrant {
        Epoch storage epoch = epochs[epochId];
        Assertion storage assertion = assertions[epochId];
        if (epoch.agentId == 0 || epoch.result != Outcome.Pending) revert InvalidState();
        if (assertion.proposer == address(0)) {
            if (block.timestamp < _reportDeadline(epochId)) revert InvalidState();
            _settle(epochId, Outcome.Void);
        } else if (assertion.challenger != address(0)) {
            if (block.timestamp < assertion.arbitrationEnds) revert InvalidState();
            bondCredit[assertion.proposer] += disputeBond;
            bondCredit[assertion.challenger] += disputeBond;
            _settle(epochId, Outcome.Void);
        } else {
            if (block.timestamp < assertion.challengeEnds) revert InvalidState();
            bondCredit[assertion.proposer] += disputeBond;
            _settle(epochId, _acceptedOutcome(epochId));
        }
    }

    function arbitrate(uint256 epochId, bool upholdReport) external nonReentrant {
        if (msg.sender != arbitrator) revert Unauthorized();
        Assertion storage assertion = assertions[epochId];
        if (assertion.challenger == address(0) || block.timestamp < assertion.challengeEnds
            || block.timestamp >= assertion.arbitrationEnds
            || epochs[epochId].result != Outcome.Pending) revert InvalidState();
        Outcome result = upholdReport ? _acceptedOutcome(epochId) : Outcome.Void;
        address winner = result == Outcome.Void ? assertion.challenger : assertion.proposer;
        bondCredit[winner] += 2 * disputeBond;
        _settle(epochId, result);
    }

    function withdrawCredit() external nonReentrant {
        uint256 amount = bondCredit[msg.sender];
        if (amount == 0) revert InvalidState();
        delete bondCredit[msg.sender];
        _pay(msg.sender, amount);
    }

    function _acceptedOutcome(uint256 epochId) private view returns (Outcome) {
        Assertion storage assertion = assertions[epochId];
        uint256 remaining = assertion.signers & ~disqualifiedSigners[epochId];
        uint256 count;
        while (remaining != 0) {
            remaining &= remaining - 1;
            ++count;
        }
        if (count < quorum) return Outcome.Void;
        return assertion.report.totalClaims == 0 ? Outcome.NoFailure : Outcome.Failure;
    }

    function _reportDeadline(uint256 epochId) private view returns (uint256) {
        uint256 deadline = correctionDeadline[epochId];
        return deadline == 0 ? uint256(epochs[epochId].terms.endsAt) + reportingWindow : deadline;
    }

    function _settle(uint256 epochId, Outcome result) private {
        Epoch storage epoch = epochs[epochId];
        Report storage report = assertions[epochId].report;
        uint256 latestCorrection = evidenceDeadline[epochId] - challengeWindow - arbitrationWindow;
        if (result == Outcome.Void && correctionDeadline[epochId] == 0 && block.timestamp < latestCorrection) {
            uint256 deadline = Math.min(block.timestamp + reportingWindow, latestCorrection);
            correctionDeadline[epochId] = deadline;
            delete assertions[epochId];
            emit CorrectionOpened(epochId, deadline);
            return;
        }
        epoch.result = result;
        uint256 loss;
        uint256 funded;
        if (result == Outcome.Failure) {
            loss = Math.min(report.totalClaims, epoch.terms.lossCap);
            address recipient = address(escrow);
            uint256 balanceBefore = collateral.balanceOf(recipient);
            funded = market.resolve(epochId, result, loss, recipient);
            funded += registry.settle(epoch.agentId, epochId, loss, epoch.terms.lossCap, loss - funded, recipient);
            funded += vault.slash(epochId, loss - funded, recipient);
            if (collateral.balanceOf(recipient) - balanceBefore != funded) revert UnsupportedCollateral();
            escrow.open(epochId, report.claimsRoot, report.totalClaims, funded);
        } else {
            market.resolve(epochId, result, 0, address(escrow));
            registry.settle(epoch.agentId, epochId, 0, epoch.terms.lossCap, 0, address(escrow));
        }
        vault.release(epochId);
        emit EpochSettled(epochId, result, loss, funded, report.evidenceHash);
    }
}
