// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ChainlinkMock
 * @notice Minimal simulation of a Chainlink AggregatorV3 price feed for
 *         local development and integration testing.
 * @dev    Exposes the standard `latestRoundData()` interface so that any
 *         consumer written against the Chainlink AggregatorV3Interface can
 *         be exercised without an on-chain deployment.
 *
 *         `updatedAt` is set to `block.timestamp` at every `updatePrice()`
 *         call, mirroring real oracle sequencer behaviour. Staleness
 *         validation (e.g. `block.timestamp - updatedAt < MAX_STALENESS`)
 *         is the responsibility of the consuming contract, as per the
 *         Chainlink integration best-practice guidelines.
 *
 * @custom:security-contact security@novasynth.fi
 */
contract ChainlinkMock {
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;
    uint8 public constant decimals = 8;
    string public description;
    address public owner;

    event PriceUpdated(int256 price, uint80 roundId, uint256 timestamp);

    constructor(string memory _description, int256 _initialPrice) {
        description = _description;
        owner = msg.sender;
        price = _initialPrice;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    /**
     * @notice Push a new price to the feed.
     * @dev    Increments `roundId` and updates `updatedAt` to the current
     *         block timestamp, matching real Chainlink sequencer behaviour.
     * @param  _price New answer in feed-native precision (8 decimals).
     */
    function updatePrice(int256 _price) external {
        require(msg.sender == owner, "ChainlinkMock: not owner");
        roundId++;
        price = _price;
        updatedAt = block.timestamp;
        emit PriceUpdated(_price, roundId, block.timestamp);
    }

    /**
     * @notice Returns the latest round data in the standard Chainlink format.
     * @return _roundId        Monotonically increasing round identifier.
     * @return _answer         Latest price in 8-decimal fixed-point.
     * @return _startedAt      Timestamp when this round started (= updatedAt).
     * @return _updatedAt      Timestamp of the last `updatePrice()` call.
     * @return _answeredInRound Round in which the answer was computed (= roundId).
     */
    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, price, updatedAt, updatedAt, roundId);
    }
}
