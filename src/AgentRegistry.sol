// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralModule, IERC20} from "./CollateralModule.sol";

contract AgentRegistry is CollateralModule {
    uint256 public constant MAX_SCORE = 10_000;
    uint256 public nextAgentId = 1;
    uint256 public immutable minimumBond;

    struct Agent {
        address provider;
        uint8 riskTier;
        uint256 credibility;
        uint256 bond;
        uint256 activeEpoch;
        uint256 incidents;
        string metadataURI;
    }

    mapping(uint256 => Agent) public agents;

    event AgentRegistered(uint256 indexed agentId, address indexed provider, uint8 riskTier, string metadataURI);
    event BondChanged(uint256 indexed agentId, uint256 balance);
    event CredibilityChanged(uint256 indexed agentId, uint256 indexed epochId, uint256 score, uint256 verifiedLoss);

    constructor(IERC20 token, address authority, uint256 minBond) CollateralModule(token, authority) {
        if (minBond == 0) revert InvalidInput();
        minimumBond = minBond;
    }

    function register(string calldata metadataURI, uint8 riskTier, uint256 bond)
        external nonReentrant returns (uint256 id)
    {
        if (bytes(metadataURI).length == 0 || riskTier == 0 || riskTier > 3 || bond < minimumBond) {
            revert InvalidInput();
        }
        id = nextAgentId++;
        agents[id] = Agent(msg.sender, riskTier, MAX_SCORE, bond, 0, 0, metadataURI);
        _collect(msg.sender, bond);
        emit AgentRegistered(id, msg.sender, riskTier, metadataURI);
        emit BondChanged(id, bond);
    }

    function addBond(uint256 id, uint256 amount) external nonReentrant {
        Agent storage agent = agents[id];
        if (msg.sender != agent.provider) revert Unauthorized();
        if (agent.activeEpoch != 0 || amount == 0) revert InvalidState();
        agent.bond += amount;
        _collect(msg.sender, amount);
        emit BondChanged(id, agent.bond);
    }

    function withdrawBond(uint256 id, uint256 amount) external nonReentrant {
        Agent storage agent = agents[id];
        if (msg.sender != agent.provider) revert Unauthorized();
        if (agent.activeEpoch != 0 || amount == 0 || amount > agent.bond) revert InvalidState();
        agent.bond -= amount;
        _pay(msg.sender, amount);
        emit BondChanged(id, agent.bond);
    }

    function lock(uint256 id, uint256 epochId, address provider) external onlyCoordinator {
        Agent storage agent = agents[id];
        if (agent.provider != provider) revert Unauthorized();
        if (epochId == 0 || agent.activeEpoch != 0 || agent.bond < minimumBond) revert InvalidState();
        agent.activeEpoch = epochId;
    }

    function settle(
        uint256 id, uint256 epochId, uint256 verifiedLoss, uint256 lossCap, uint256 requestedBond, address recipient
    ) external onlyCoordinator nonReentrant returns (uint256 seized) {
        Agent storage agent = agents[id];
        if (epochId == 0 || agent.activeEpoch != epochId) revert InvalidState();
        agent.activeEpoch = 0;
        if (verifiedLoss != 0) {
            ++agent.incidents;
            uint256 penalty = Math.max(1, Math.mulDiv(verifiedLoss, MAX_SCORE, lossCap));
            agent.credibility -= Math.min(agent.credibility, penalty);
            seized = Math.min(agent.bond, requestedBond);
            agent.bond -= seized;
            _pay(recipient, seized);
            emit BondChanged(id, agent.bond);
            emit CredibilityChanged(id, epochId, agent.credibility, verifiedLoss);
        }
    }
}
