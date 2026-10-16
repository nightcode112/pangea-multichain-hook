// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// The quote dust an in-range opening owes, and the quotes it can be owed in
//
// A pool whose token is currency1 -- every native-quoted one, and any asset that sorts below the
// token -- opens one unit of square-root price under the top of its range, so its liquidity is
// active from the first block (LiquidityLocker). The position then owes the pool the quote for the
// sliver between that price and the range's top:
//
//     dust = ceil(L * 2^96 / (sqrtP * sqrtU)),  sqrtU - sqrtP = 1,  L ~ slice * 2^96 / sqrtP
//          ~ slice / (p^1.5 * 2^96)
//
// where p is token base units per quote base unit. Every launch opens at a $3,000 market cap over
// its launch total T (base units), so p = u * T / 3000 with u the quote's USD per BASE unit, and
// with a slice of at most T:
//
//     dust <= 3000^1.5 / (u^1.5 * T^0.5 * 2^96)
//
// It grows as the quote gets cheaper per base unit, and it is worth nothing in dollars anywhere:
// dust * u ~ 7.6e-27 / sqrt(p) USD.
//
// THE TWO NUMBERS. A quote may only be listed (PairRegistry) or attested as the native coin
// (PriceAttestor) with a price band whose floor is at least 1e-30 USD per base unit
// (`quoteBandFloorFits`), which is an 18-decimal asset at $1e-12 a whole unit -- below every
// real asset. At that floor, with the smallest launch the attestor accepts (one whole token,
// T = 1e9, all of it in one slice), the formula gives 6.6e16 base units; the default launch
// (a 200M slice of 1B) owes 4.2e11 there and exactly 1 for any quote worth more than ~$5.6e-5 a
// whole 18-decimal unit. So `MAX_OPENING_DUST` = 1e17 is enough for every launch the contracts
// accept against every quote they accept, and test/InRangeOpening.t.sol holds the two to each
// other.
//
// WHAT THE CAP IS FOR. The factory pays the exact dust from its float and nothing more -- the
// locker pulls what the pool says the position owes -- so the cap is not what the float loses per
// launch. It is the sanity bound on that pull: a position on the wrong side of its price owes the
// slice's worth of quote, not dust, and is refused (LiquidityLocker.QuoteSideTooLarge) whenever
// that is more than the cap. Below the cap the float's own balance is the bound.

// The most quote, in its base units, an opening may owe and the factory may pay for it.
uint256 constant MAX_OPENING_DUST = 1e17;

// Base units of a quote that 1e18-scaled USD 1 (that is, $1e-18) may buy at the most: 1e12, which
// is 1e-30 USD a base unit. See `quoteBandFloorFits`.
uint256 constant MAX_QUOTE_BASE_UNITS_PER_WAD_USD = 1e12;

/// @notice Whether a band whose floor is `minUsdPerQuote` (USD per whole unit, 1e18-scaled) for a
///         quote of `decimals` keeps every opening's dust within `MAX_OPENING_DUST`: at least
///         1e-30 USD a base unit.
/// @dev minUsdPerQuote >= 10^decimals / 1e12, the division exact (both powers of ten) and nothing
///      multiplied, so no band can overflow it. For 18 decimals the floor is 1e6 ($1e-12 a whole
///      unit); for 12 decimals or fewer it is 1, the least a band can be.
function quoteBandFloorFits(uint256 minUsdPerQuote, uint8 decimals) pure returns (bool) {
    uint256 unit = 10 ** uint256(decimals);
    uint256 floor = unit <= MAX_QUOTE_BASE_UNITS_PER_WAD_USD ? 1 : unit / MAX_QUOTE_BASE_UNITS_PER_WAD_USD;
    return minUsdPerQuote >= floor;
}
