// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChainlinkMock.sol";
import "./SynthToken.sol";

/**
 * @title SynthOracle
 * @notice Composite price oracle that combines two independent sources to
 *         reduce reliance on any single data provider:
 *
 *           1. An internal AMM-based TWAP accumulator updated via {observe}.
 *           2. An external Chainlink-compatible push feed ({ChainlinkMock}).
 *
 *         The reported price is the arithmetic mean of both sources, optionally
 *         scaled by a per-asset multiplier registered by the owner.
 *
 * @dev    Price data is stored in an append-only {Observation} array.
 *         The TWAP is derived by dividing the cumulative price delta between
 *         the two observations that bracket the configured {twapWindow}.
 *         The external feed is read via the standard `latestRoundData()` ABI.
 *
 * @custom:security-contact security@novasynth.fi
 */
contract SynthOracle {
    ChainlinkMock public externalFeed;
    address public owner;

    // ─── Internal TWAP accumulator ───
    uint256 public cumulativePrice; // Append-only; used for TWAP delta calculations
    uint256 public lastObservationTime;
    uint256 public lastPrice; // Last spot price observation

    // TWAP window in seconds
    uint256 public twapWindow;

    // Historical observations for TWAP
    struct Observation {
        uint256 timestamp;
        uint256 cumulativePrice;
    }
    Observation[] public observations;

    // Supported assets and their price multipliers
    mapping(address => uint256) public assetMultiplier; // 1e18 base

    event PriceObserved(uint256 spotPrice, uint256 cumulative, uint256 timestamp);
    event AssetRegistered(address indexed asset, uint256 multiplier);

    constructor(address _externalFeed, uint256 _twapWindow) {
        externalFeed = ChainlinkMock(_externalFeed);
        owner = msg.sender;
        twapWindow = _twapWindow;
        lastObservationTime = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════

    function registerAsset(address asset, uint256 multiplier) external {
        require(msg.sender == owner, "Oracle: not owner");
        assetMultiplier[asset] = multiplier;
        emit AssetRegistered(asset, multiplier);
    }

    // ═══════════════════════════════════════════════════════════════
    // OBSERVATION (update internal TWAP)
    // ═══════════════════════════════════════════════════════════════

    function observe(uint256 spotPrice) external {
        uint256 elapsed = block.timestamp - lastObservationTime;

        // Accumulate price × time
        cumulativePrice += lastPrice * elapsed;

        observations.push(Observation({timestamp: block.timestamp, cumulativePrice: cumulativePrice}));

        lastPrice = spotPrice;
        lastObservationTime = block.timestamp;

        emit PriceObserved(spotPrice, cumulativePrice, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════
    // PRICE QUERIES
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Returns the composite price of `asset` in 18-decimal precision.
     * @dev    Reads the internal AMM TWAP and the external Chainlink feed,
     *         averages them, then scales by the asset-specific multiplier.
     *         If no multiplier is registered the multiplier defaults to 1e18
     *         (i.e. no scaling).
     * @param  asset  The address of the registered asset.
     * @return        Composite price in WAD (18-decimal) units.
     */
    function getPrice(address asset) external view returns (uint256) {
        uint256 internalPrice = _getInternalTWAP();
        uint256 externalPrice = _getExternalPrice();

        // Average of internal + external; apply asset-specific multiplier
        uint256 compositePrice = (internalPrice + externalPrice) / 2;

        // Apply asset-specific multiplier
        uint256 multiplier = assetMultiplier[asset];
        if (multiplier == 0) multiplier = 1e18;

        return (compositePrice * multiplier) / 1e18;
    }

    /**
     * @notice Computes the time-weighted average price from the internal
     *         observation history over approximately {twapWindow} seconds.
     * @dev    Finds the oldest observation within the window via a reverse
     *         linear scan, then divides the cumulative price delta by the
     *         elapsed time. Falls back to {lastPrice} when fewer than two
     *         observations exist or the time delta is zero.
     */
    function _getInternalTWAP() internal view returns (uint256) {
        if (observations.length < 2) {
            return lastPrice;
        }

        // Find observation from ~twapWindow ago
        uint256 targetTime = block.timestamp - twapWindow;
        uint256 oldIdx = 0;

        for (uint256 i = observations.length - 1; i > 0; i--) {
            if (observations[i].timestamp <= targetTime) {
                oldIdx = i;
                break;
            }
        }

        Observation storage oldObs = observations[oldIdx];
        Observation storage newObs = observations[observations.length - 1];

        uint256 timeDelta = newObs.timestamp - oldObs.timestamp;
        if (timeDelta == 0) return lastPrice;

        uint256 priceDelta = newObs.cumulativePrice - oldObs.cumulativePrice;
        return priceDelta / timeDelta;
    }

    /**
     * @notice Reads the latest price from the external Chainlink-compatible feed.
     * @dev    Calls `latestRoundData()` and converts the 8-decimal Chainlink
     *         answer to 18-decimal WAD by multiplying by 1e10.
     *         Reverts if the returned answer is non-positive.
     * @return Price in 18-decimal WAD format.
     */
    function _getExternalPrice() internal view returns (uint256) {
        (, int256 answer,,,) = externalFeed.latestRoundData();
        require(answer > 0, "Oracle: invalid external price");
        // Convert from 8 decimals (Chainlink) to 18 decimals
        return uint256(answer) * 1e10;
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    function getLastObservation() external view returns (uint256 timestamp, uint256 cumPrice) {
        if (observations.length == 0) return (0, 0);
        Observation storage obs = observations[observations.length - 1];
        return (obs.timestamp, obs.cumulativePrice);
    }
}
