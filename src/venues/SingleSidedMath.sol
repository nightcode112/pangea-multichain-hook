// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title SingleSidedMath
/// @notice The arithmetic every venue's locker shares: how much liquidity a pile of tokens buys
///         when the range sits entirely on one side of the price, and whether a tick-aligned
///         opening price is close enough to the attested one.
///
/// SHARED ON PURPOSE. Uniswap v4 and PancakeSwap Infinity have different plumbing -- one
/// monolithic PoolManager against a Vault plus a CLPoolManager -- but their tick mathematics is
/// the same implementation with different names, down to identical constants. Keeping one copy of
/// the part that is easy to get subtly wrong means a fix or a review lands on both chains at
/// once, rather than one of five pools opening on a formula nobody re-checked.
///
/// Each locker still uses its own venue's TickMath to turn ticks into square-root prices, because
/// that is the piece that must agree with the pool being written to. This library only takes the
/// prices once they exist.
library SingleSidedMath {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant BPS = 10_000;

    error LiquidityOverflow(uint256 liquidity);
    error EmptyRange();
    error OpeningPriceOffTarget(uint256 implied, uint256 target, uint16 toleranceBps);

    /// @notice Liquidity obtainable from `amount` of currency0, for a range above the price.
    /// @dev amount0 = L * (sqrtUpper - sqrtLower) / (sqrtLower * sqrtUpper), rearranged. With the
    ///      price at the lower bound the currency1 side contributes nothing, which is the whole
    ///      point: the position needs tokens only.
    function liquidityForToken0(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount)
        internal
        pure
        returns (uint128)
    {
        if (sqrtUpper <= sqrtLower) revert EmptyRange();
        uint256 intermediate = FullMath.mulDiv(sqrtLower, sqrtUpper, Q96);
        return _toUint128(FullMath.mulDiv(amount, intermediate, sqrtUpper - sqrtLower));
    }

    /// @notice Liquidity obtainable from `amount` of currency1, for a range below the price.
    /// @dev amount1 = L * (sqrtUpper - sqrtLower). Mirror of the above: with the price at the
    ///      upper bound the currency0 side contributes nothing.
    function liquidityForToken1(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount)
        internal
        pure
        returns (uint128)
    {
        if (sqrtUpper <= sqrtLower) revert EmptyRange();
        return _toUint128(FullMath.mulDiv(amount, Q96, sqrtUpper - sqrtLower));
    }

    /// @notice Reject an opening price that is cheaper than the attested one, or dearer than it
    ///         by more than the tolerance.
    /// @dev Compares prices, not square roots. A tolerance applied to a square root is half the
    ///      tolerance on the price it represents, so checking the root would silently be twice as
    ///      strict as it reads -- and the point of the check is that the number means what the
    ///      launcher thinks it means.
    ///
    ///      ONE-SIDED. The tolerance exists because a pool opens on a tick and the attested price
    ///      falls between two; it was applied to both sides, so whoever sent the launch could
    ///      take the tick a spacing or two BELOW the price that was signed and buy in the same
    ///      transaction -- the whole slice a percent under the other four chains. Nothing needs
    ///      that side: there is always an aligned tick at or above the price, and it is the one
    ///      the launcher's own scripts have always picked. The price is currency1 per currency0,
    ///      so "not cheaper" is at or above the target when the token is currency0 and at or
    ///      below it when the token is currency1.
    function checkOpeningPrice(uint160 sqrtPriceX96, uint256 targetPriceX96, uint16 toleranceBps, bool tokenIsCurrency0)
        internal
        pure
    {
        uint256 implied = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        bool cheaper = tokenIsCurrency0 ? implied < targetPriceX96 : implied > targetPriceX96;
        uint256 diff = implied > targetPriceX96 ? implied - targetPriceX96 : targetPriceX96 - implied;
        if (cheaper || diff * BPS > targetPriceX96 * toleranceBps) {
            revert OpeningPriceOffTarget(implied, targetPriceX96, toleranceBps);
        }
    }

    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert LiquidityOverflow(x);
        return uint128(x);
    }
}
