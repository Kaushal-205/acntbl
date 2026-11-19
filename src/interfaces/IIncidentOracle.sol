// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IIncidentOracle {
    enum Outcome { Pending, NoFailure, Failure, Void }

    struct Report {
        uint256 epochId;
        uint256 exactLoss;
        uint8 severity;
        bytes32 evidenceHash;
        bytes32 claimsRoot;
        uint256 totalClaims;
    }

    function outcome(uint256 epochId) external view returns (Outcome);
    function reportDigest(Report calldata report) external view returns (bytes32);
}
