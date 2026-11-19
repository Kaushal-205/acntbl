// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralModule, IERC20} from "./CollateralModule.sol";
import {IIncidentOracle} from "./interfaces/IIncidentOracle.sol";

contract FailurePredictionMarket is CollateralModule {
    uint256 public constant BPS = 10_000;
    uint256 public immutable feeBps;
    address public immutable reserveRecipient;

    struct Market {
        uint64 closesAt;
        IIncidentOracle.Outcome result;
        uint256 yes;
        uint256 no;
        uint256 reserve;
    }

    struct Position {
        uint256 yes;
        uint256 no;
        uint256 fees;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => Position)) public positions;

    event PositionBought(uint256 indexed epochId, address indexed trader, bool failure, uint256 net, uint256 fee);
    event MarketResolved(uint256 indexed epochId, IIncidentOracle.Outcome result, uint256 victimReserve);
    event MarketClaimed(uint256 indexed epochId, address indexed trader, uint256 amount);

    constructor(IERC20 token, address authority, uint256 fee, address treasury) CollateralModule(token, authority) {
        if (fee == 0 || fee > 1_000 || treasury == address(0)) revert InvalidInput();
        feeBps = fee;
        reserveRecipient = treasury;
    }

    function openMarket(uint256 epochId, uint64 closesAt) external onlyCoordinator {
        if (markets[epochId].closesAt != 0 || closesAt <= block.timestamp) revert InvalidState();
        markets[epochId].closesAt = closesAt;
    }

    function buy(uint256 epochId, bool failure, uint256 amount) external nonReentrant {
        Market storage market = markets[epochId];
        if (block.timestamp >= market.closesAt || amount == 0) revert InvalidState();
        uint256 fee = Math.mulDiv(amount, feeBps, BPS, Math.Rounding.Ceil);
        if (fee >= amount) revert InvalidInput();
        uint256 net = amount - fee;
        Position storage position = positions[epochId][msg.sender];
        position.fees += fee;
        market.reserve += fee;
        if (failure) {
            market.yes += net;
            position.yes += net;
        } else {
            market.no += net;
            position.no += net;
        }
        _collect(msg.sender, amount);
        emit PositionBought(epochId, msg.sender, failure, net, fee);
    }

    /// @notice Net YES stake as a share of total net stake, expressed in basis points.
    function impliedFailureBps(uint256 epochId) external view returns (uint256 bps, bool hasTrades) {
        Market storage market = markets[epochId];
        uint256 total = market.yes + market.no;
        if (total == 0) return (0, false);
        return (Math.mulDiv(market.yes, BPS, total), true);
    }

    function resolve(uint256 epochId, IIncidentOracle.Outcome result, uint256 maximum, address escrow)
        external onlyCoordinator nonReentrant returns (uint256 victimReserve)
    {
        Market storage market = markets[epochId];
        if (market.closesAt == 0 || market.result != IIncidentOracle.Outcome.Pending
            || result == IIncidentOracle.Outcome.Pending) revert InvalidState();
        market.result = result;
        if (result == IIncidentOracle.Outcome.Failure) {
            victimReserve = Math.min(market.reserve, maximum);
            _pay(escrow, victimReserve);
        }
        if (result != IIncidentOracle.Outcome.Void) _pay(reserveRecipient, market.reserve - victimReserve);
        emit MarketResolved(epochId, result, victimReserve);
    }

    function claim(uint256 epochId) external nonReentrant returns (uint256 amount) {
        Market storage market = markets[epochId];
        Position memory position = positions[epochId][msg.sender];
        if (market.result == IIncidentOracle.Outcome.Pending || position.yes + position.no == 0) revert InvalidState();
        delete positions[epochId][msg.sender];
        bool failure = market.result == IIncidentOracle.Outcome.Failure;
        uint256 winningPot = failure ? market.yes : market.no;
        if (market.result == IIncidentOracle.Outcome.Void) {
            amount = position.yes + position.no + position.fees;
        } else if (winningPot == 0) {
            amount = position.yes + position.no;
        } else {
            amount = Math.mulDiv(failure ? position.yes : position.no, market.yes + market.no, winningPot);
        }
        _pay(msg.sender, amount);
        emit MarketClaimed(epochId, msg.sender, amount);
    }
}
