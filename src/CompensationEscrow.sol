// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {CollateralModule, IERC20} from "./CollateralModule.sol";

contract CompensationEscrow is CollateralModule {
    struct Settlement {
        bytes32 root;
        uint256 verifiedClaims;
        uint256 funded;
        uint256 claimedLoss;
        uint256 paid;
    }

    mapping(uint256 => Settlement) public settlements;
    mapping(uint256 => mapping(bytes32 => bool)) public claimed;

    event CompensationOpened(uint256 indexed epochId, bytes32 root, uint256 verifiedClaims, uint256 funded);
    event Compensated(uint256 indexed epochId, bytes32 indexed claimId, address indexed victim, uint256 loss, uint256 paid);

    constructor(IERC20 token, address authority) CollateralModule(token, authority) {}

    function open(uint256 epochId, bytes32 root, uint256 verifiedClaims, uint256 funded) external onlyCoordinator {
        if (root == bytes32(0) || verifiedClaims == 0 || funded > verifiedClaims
            || settlements[epochId].root != bytes32(0)) revert InvalidInput();
        settlements[epochId] = Settlement(root, verifiedClaims, funded, 0, 0);
        emit CompensationOpened(epochId, root, verifiedClaims, funded);
    }

    function claimLeaf(uint256 epochId, bytes32 claimId, address victim, uint256 loss) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), epochId, claimId, victim, loss))));
    }

    /// @notice Anyone can relay a claim. Funds always go to the victim bound into the proof.
    function claim(uint256 epochId, bytes32 claimId, address victim, uint256 loss, bytes32[] calldata proof)
        external nonReentrant returns (uint256 amount)
    {
        Settlement storage settlement = settlements[epochId];
        if (settlement.root == bytes32(0) || claimed[epochId][claimId]) revert InvalidState();
        if (victim == address(0) || claimId == bytes32(0) || loss == 0
            || loss > settlement.verifiedClaims - settlement.claimedLoss
            || !MerkleProof.verifyCalldata(proof, settlement.root, claimLeaf(epochId, claimId, victim, loss))) {
            revert InvalidInput();
        }
        claimed[epochId][claimId] = true;
        settlement.claimedLoss += loss;
        amount = Math.mulDiv(loss, settlement.funded, settlement.verifiedClaims);
        settlement.paid += amount;
        _pay(victim, amount);
        emit Compensated(epochId, claimId, victim, loss, amount);
    }
}
