// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FactoryList} from "../FactoryList.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SingleSidedMath} from "./SingleSidedMath.sol";
import {MAX_OPENING_DUST} from "./OpeningDust.sol";

/// @title LiquidityLocker
/// @notice Holds every launch's liquidity on one EVM chain, permanently: one contract, one
///         position per pool, and no way for anybody to take any of it out.
///
/// ONE LOCKER, NOT ONE SEEDER PER LAUNCH. Each launch used to deploy its own UniswapV4Seeder: a
/// five-kilobyte contract created, and its state written, inside every launch transaction, only to
/// open one pool and then do nothing for ever. This is that contract's logic, kept, with the pool
/// as a key rather than a deployment: the factory hands it the slice and the pool key, it opens the
/// pool and adds the slice as one position it owns, and that is the last time the position's
/// liquidity changes. A launch now writes one record here instead of deploying a contract.
///
/// THE LOCK IS THE ABSENCE OF CODE. This contract owns every position, and there is no function
/// anywhere in it that passes a negative `liquidityDelta`, moves a position, or hands one to
/// anybody. There is no owner, no admin, no upgrade and no proxy. The two operations it performs
/// on a pool are "add at launch", once per pool and only for the factory, and "collect fees",
/// which anyone may call and whose only destination is the splitter recorded at the seed. A v4
/// position belongs to whoever called `modifyLiquidity` for it, so nothing but this contract can
/// touch these positions -- and this contract cannot ask for less liquidity, because nothing in it
/// can express that.
///
/// The one setting it has is its list of factories (FactoryList): `deployer` may ADD one, never
/// remove or replace one, and an added factory may seed NEW pools only. A pool is seeded once, by
/// the factory recorded with it (`factoryOf`), and nothing writes its position again -- so a later
/// factory reuses this locker and the hook that names it, and cannot touch any pool already here.
/// The same rule as PangeaFeeHook's.
///
/// EVERY POOL IS KEPT APART. Each pool's position is its own v4 position (the salt is the pool's
/// id), its own record here, and its fees go to the splitter recorded for that pool at its seed --
/// `collect(id)` can send pool A's fees nowhere but A's splitter. Each launch's token is seeded
/// into exactly one pool (`poolOf`), so the rounding dust a seed leaves behind, which stays here
/// with no code that can move it, is that one pool's and nobody else's: a seed spends at most the
/// amount it was handed for that pool (`TokenSideTooLarge`) and never reaches into what another
/// launch left. Quote never rests here at all -- the opening's dust is paid from the factory's
/// float straight to the pool, and native the pool did not ask for goes straight back.
///
/// SINGLE-SIDED, AND PROVEN RATHER THAN ASSUMED. Unchanged from the seeder. The position sits on
/// one side of the opening price, so it needs tokens and -- at most -- a dust of the quote asset,
/// which is what lets 100% of supply go into liquidity with nothing held back. The callback asserts
/// the quote side owes no more than `MAX_QUOTE_DUST`, so if the range were ever misplaced the
/// launch reverts instead of demanding quote the factory does not have.
///
/// WHICH SIDE DEPENDS ON TOKEN ORDERING. v4 sorts currencies by address, and price means
/// currency1 per currency0. If the token sorts lower it is currency0, the price rises as the token
/// appreciates, and the range sits above the opening price. If it sorts higher the price is
/// inverted and the range sits below. A native-quoted pool is always the second: the native coin
/// is address zero and sorts first.
///
/// THE POSITION IS ACTIVE FROM THE FIRST BLOCK, ON BOTH SIDES. v4 counts a position as in range
/// when `tickLower <= tick < tickUpper`. With the token as currency0 the pool opens on the range's
/// lower tick, which is inside it. With the token as currency1 the range ends AT the opening tick,
/// so that pool opens one unit of square-root price below it -- tick `startTick - 1`, inside the
/// range, on the dear side of the attested price by about 1e-29 -- and the slice's liquidity is
/// computed with that price as the top of what it fills. The position then owes the pool a dust
/// of the quote for the sliver between the price and `tickUpper`: one base unit at any ordinary
/// price, more for a quote worth very little per base unit (OpeningDust.sol). It is paid from a
/// float the platform keeps in the factory, EXACTLY: the pool says what the position owes and this
/// contract pays that -- pulling an ERC-20's from the factory, which has approved it up to
/// `MAX_QUOTE_DUST`, or settling the native coin's out of what the factory sent with `seed` and
/// returning the rest in the same call. Never the creator's, and not a trade.
///
/// THE POOL HAS A HOOK, AND THIS CONTRACT DOES NOT CHOOSE IT. The key the factory hands `seed`
/// names PangeaFeeHook, which lets nobody but this contract add liquidity, takes the whole fee at
/// swap time and keeps the price inside the range. Nothing here checks which hook the key names --
/// the factory builds the key and is the only caller `seed` accepts -- so "which hook" is the
/// factory's guarantee, not this contract's.
///
/// FEES DO NOT ACCRUE HERE. The hook takes the whole fee at swap time and the pool's own fee is
/// zero, so these positions earn nothing. `collect` is kept as a claim of last resort for a pool
/// somehow created without the hook; on a normal launch it finds nothing, which the sweep already
/// treats as success.
///
/// THE OPENING PRICE IS TICK-ALIGNED, AND THE ERROR IS BOUNDED ON-CHAIN. The caller supplies the
/// tick and this contract checks the price it implies against the attested one, reverting if the
/// gap exceeds tolerance -- and never accepting one cheaper than attested (SingleSidedMath).
contract LiquidityLocker is IUnlockCallback, ReentrancyGuardTransient, FactoryList {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice The most of the quote asset, in its base units, an opening position may owe.
    /// @dev `MAX_OPENING_DUST`, 1e17: see UniswapLaunchFactory and OpeningDust.sol. More than
    ///      this means the range is not where it should be, and the launch reverts. With the token
    ///      as currency0 the pool opens on `tickLower` and owes nothing.
    uint256 public constant MAX_QUOTE_DUST = MAX_OPENING_DUST;

    enum Action {
        Seed,
        Collect
    }

    IPoolManager public immutable poolManager;

    /// @notice May add a factory to the list that may seed NEW pools (`addFactory`). It can never
    ///         remove one, and no factory can touch a pool once it is seeded: a position is
    ///         written once, with the factory that seeded it, and nothing writes it again.
    address public immutable deployer;

    /// @notice The factory that seeded each pool, recorded with its position.
    mapping(PoolId => address) public factoryOf;

    /// @notice One pool's locked position.
    /// @dev One storage slot. `splitter` is never zero for a seeded pool, so it doubles as the
    ///      "seeded" flag. The liquidity itself is read from the PoolManager (`positionLiquidity`),
    ///      the one place it can never disagree with.
    struct Locked {
        /// @notice Where this pool's fees go, for good.
        address splitter;
        int24 tickLower;
        int24 tickUpper;
        /// @notice Which side of the key is the launch's token.
        bool tokenIsCurrency0;
    }

    /// @notice Each pool's position: (splitter, tickLower, tickUpper, tokenIsCurrency0).
    mapping(PoolId => Locked) public positions;

    /// @notice Each pool's key, as the factory built it.
    mapping(PoolId => PoolKey) internal _keys;

    /// @notice The one pool each launch token was seeded into. Zero for a token never seeded.
    mapping(address => PoolId) public poolOf;

    /// @param quoteDust What the opening owed the pool in the quote, in its base units, and paid
    ///        from the factory's float: zero with the token as currency0.
    event Seeded(
        PoolId indexed id,
        address indexed token,
        address splitter,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokensUsed,
        uint256 quoteDust
    );
    event Collected(PoolId indexed id, address indexed splitter, uint256 amount0, uint256 amount1);

    error ZeroAddress();
    error NotDeployer();
    error NotFactory();
    error NotPoolManager();
    error ZeroSplitter();
    error AlreadySeeded(PoolId id);
    error TokenAlreadySeeded(address token);
    error NotSeeded(PoolId id);
    error TokenNotInPool();
    error TickNotAligned(int24 tick, int24 tickSpacing);
    error TickOnWrongSide(int24 tick);
    error NoLiquidity();
    error QuoteSideTooLarge(int256 delta);
    /// @notice The pool asked for more of the token than this seed was handed. Never reached with
    ///         v4's own rounding; refused rather than paid out of what another seed left here.
    error TokenSideTooLarge(uint256 owed, uint256 amount);
    error NothingToCollect();
    /// @notice Native sent with a seed that cannot owe it -- an ERC-20 quote, or the token as
    ///         currency0 -- or more than any opening may owe. Refused rather than kept: this
    ///         contract has no code that could ever move it again.
    error UnexpectedValue(uint256 value);
    /// @notice The native the factory sent does not cover what the opening owes.
    error DustNotCovered(uint256 owed, uint256 sent);
    error RefundFailed();

    constructor(address poolManager_, address deployer_) {
        if (poolManager_ == address(0) || deployer_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        deployer = deployer_;
        _initFactoryAdmin(deployer_);
    }


    // -------------------------------------------------------------- seeding

    /// @notice Open one launch's pool and lock `amount` of its token in as single-sided liquidity.
    /// @param key The pool, with currencies already sorted and the fee already set.
    /// @param token The launch's token: one of the key's currencies, never seeded before.
    /// @param splitter Where this pool's fees go, for good.
    /// @param amount The slice: how much of `token` the factory transferred here for this seed.
    ///        Whatever v4's rounding leaves of it stays here, with no code that can move it.
    /// @param startTick The opening tick. Must be a multiple of `key.tickSpacing`, and on the
    ///        side of the range that leaves the position holding only tokens.
    /// @param targetPriceX96 The attested price as currency1-per-currency0, Q96-scaled.
    /// @param toleranceBps How far above the attested price the tick-aligned one may sit. It may
    ///        not sit below it at all.
    /// @dev Payable for one reason: when the quote is the native coin and the token is currency1,
    ///      the factory sends up to `MAX_QUOTE_DUST` wei of its float with this call. The pool is
    ///      paid exactly what the opening owes out of it and the rest goes back to the factory
    ///      before this returns. Value sent with any other seed is refused. With an ERC-20 quote
    ///      the factory approves this contract instead, and the callback pulls exactly what is
    ///      owed. Only the factory may call it, once per pool and once per token.
    function seed(
        PoolKey calldata key,
        address token,
        address splitter,
        uint256 amount,
        int24 startTick,
        uint256 targetPriceX96,
        uint16 toleranceBps
    ) external payable nonReentrant returns (uint128 liquidity, uint256 tokensUsed) {
        if (!isFactory[msg.sender]) revert NotFactory();
        if (token == address(0)) revert TokenNotInPool();
        if (splitter == address(0)) revert ZeroSplitter();

        PoolId id = key.toId();
        if (positions[id].splitter != address(0)) revert AlreadySeeded(id);
        if (PoolId.unwrap(poolOf[token]) != bytes32(0)) revert TokenAlreadySeeded(token);

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        if (!tokenIsCurrency0 && Currency.unwrap(key.currency1) != token) revert TokenNotInPool();

        // Only a currency1 opening against the native coin -- which sorts first, as address zero --
        // can owe native, and never more than the cap.
        bool owesNative = !tokenIsCurrency0 && Currency.unwrap(key.currency0) == address(0);
        if (msg.value != 0 && (!owesNative || msg.value > MAX_QUOTE_DUST)) revert UnexpectedValue(msg.value);

        if (startTick % key.tickSpacing != 0) revert TickNotAligned(startTick, key.tickSpacing);

        // With the token as currency1 the pool opens one unit of square-root price under the tick,
        // so the tick is `startTick - 1` and the position below it is in range from the start. The
        // price check runs on the price the pool actually opens at.
        uint160 sqrtPriceX96;
        {
            uint160 sqrtAtTick = TickMath.getSqrtPriceAtTick(startTick);
            unchecked {
                // A tick's square-root price is at least TickMath.MIN_SQRT_PRICE, never zero.
                sqrtPriceX96 = tokenIsCurrency0 ? sqrtAtTick : sqrtAtTick - 1;
            }
        }
        SingleSidedMath.checkOpeningPrice(sqrtPriceX96, targetPriceX96, toleranceBps, tokenIsCurrency0);

        // The range runs from the opening price to the end of usable space, on whichever side
        // holds only tokens, so the pool can never run out of tokens to sell however far the
        // price travels.
        int24 tickLower;
        int24 tickUpper;
        if (tokenIsCurrency0) {
            tickLower = startTick;
            tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        } else {
            tickLower = TickMath.minUsableTick(key.tickSpacing);
            tickUpper = startTick;
        }
        if (tickLower >= tickUpper) revert TickOnWrongSide(startTick);

        // The token side of the position is what lies between the price and the far end of the
        // range: [price, upper] as currency0, [lower, price] as currency1.
        liquidity = tokenIsCurrency0
            ? SingleSidedMath.liquidityForToken0(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), amount)
            : SingleSidedMath.liquidityForToken1(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, amount);
        if (liquidity == 0) revert NoLiquidity();

        positions[id] =
            Locked({splitter: splitter, tickLower: tickLower, tickUpper: tickUpper, tokenIsCurrency0: tokenIsCurrency0});
        _keys[id] = key;
        poolOf[token] = id;
        factoryOf[id] = msg.sender;

        poolManager.initialize(key, sqrtPriceX96);
        uint256 quoteDust;
        (tokensUsed, quoteDust) = abi.decode(
            poolManager.unlock(abi.encode(Action.Seed, id, liquidity, amount, msg.value)), (uint256, uint256)
        );

        // The factory's native beyond what the pool asked for goes straight back to it, so its
        // float falls by exactly the opening's dust.
        if (msg.value > quoteDust) {
            (bool ok,) = msg.sender.call{value: msg.value - quoteDust}("");
            if (!ok) revert RefundFailed();
        }

        emit Seeded(id, token, splitter, sqrtPriceX96, tickLower, tickUpper, liquidity, tokensUsed, quoteDust);
    }

    // ------------------------------------------------------------ collecting

    /// @notice Sweep one pool's accrued fees to that pool's splitter. Permissionless -- the only
    ///         destination is the one recorded at the seed, so there is nothing to protect and the
    ///         creator never waits on the platform to press a button.
    function collect(PoolId id) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Locked memory p = positions[id];
        if (p.splitter == address(0)) revert NotSeeded(id);
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Collect, id, uint128(0), uint256(0), uint256(0))), (uint256, uint256)
        );
        if (amount0 == 0 && amount1 == 0) revert NothingToCollect();
        emit Collected(id, p.splitter, amount0, amount1);
    }

    // -------------------------------------------------------------- callback

    /// @dev Reached only through this contract's own `unlock`: the PoolManager calls back whoever
    ///      unlocked it, and nobody else may call this.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, PoolId id, uint128 liquidity, uint256 amount, uint256 nativeSent) =
            abi.decode(data, (Action, PoolId, uint128, uint256, uint256));

        if (action == Action.Seed) {
            return _addLiquidity(id, liquidity, amount, nativeSent);
        }
        return _collectFees(id);
    }

    /// @param amount The most of the token this seed may spend: what the factory handed it.
    /// @param nativeSent What the factory sent with `seed`: the most of the native coin the
    ///        opening may spend.
    /// @return The tokens and the quote dust paid, ABI-encoded.
    function _addLiquidity(PoolId id, uint128 liquidity, uint256 amount, uint256 nativeSent)
        internal
        returns (bytes memory)
    {
        PoolKey memory key = _keys[id];
        Locked memory p = positions[id];

        // A positive delta, and the only one in this contract.
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: PoolId.unwrap(id)
            }),
            ""
        );

        int256 tokenDelta = p.tokenIsCurrency0 ? callerDelta.amount0() : callerDelta.amount1();
        int256 quoteDelta = p.tokenIsCurrency0 ? callerDelta.amount1() : callerDelta.amount0();

        // The whole premise of a single-sided launch: if the range were on the wrong side of the
        // opening price this would be a real amount of quote the factory was never given, so the
        // launch fails here. What is allowed is the dust the currency1 opening owes for the sliver
        // between the price and `tickUpper`, paid from the factory's float: exactly what the pool
        // says.
        if (quoteDelta > 0 || quoteDelta < -int256(MAX_QUOTE_DUST)) revert QuoteSideTooLarge(quoteDelta);
        uint256 quoteDust = uint256(-quoteDelta);
        if (quoteDust > 0) {
            Currency quote = p.tokenIsCurrency0 ? key.currency1 : key.currency0;
            address q = Currency.unwrap(quote);
            poolManager.sync(quote);
            if (q == address(0)) {
                if (quoteDust > nativeSent) revert DustNotCovered(quoteDust, nativeSent);
                poolManager.settle{value: quoteDust}();
            } else {
                // Straight from the factory's float, which approved this contract for the cap.
                IERC20(q).safeTransferFrom(factoryOf[id], address(poolManager), quoteDust);
                poolManager.settle();
            }
        }

        // A negative delta is what this contract owes the pool: the slice, and never more of it
        // than this seed was handed.
        uint256 tokensUsed;
        if (tokenDelta < 0) {
            tokensUsed = uint256(-tokenDelta);
            if (tokensUsed > amount) revert TokenSideTooLarge(tokensUsed, amount);
            Currency t = p.tokenIsCurrency0 ? key.currency0 : key.currency1;
            poolManager.sync(t);
            IERC20(Currency.unwrap(t)).safeTransfer(address(poolManager), tokensUsed);
            poolManager.settle();
        }

        return abi.encode(tokensUsed, quoteDust);
    }

    function _collectFees(PoolId id) internal returns (bytes memory) {
        PoolKey memory key = _keys[id];
        Locked memory p = positions[id];

        // Zero liquidity change: this exists only to realise fees into a claimable delta. On a
        // hooked pool there are none, because the hook took them at swap time.
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: 0,
                salt: PoolId.unwrap(id)
            }),
            ""
        );

        uint256 amount0 = callerDelta.amount0() > 0 ? uint256(int256(callerDelta.amount0())) : 0;
        uint256 amount1 = callerDelta.amount1() > 0 ? uint256(int256(callerDelta.amount1())) : 0;

        // Straight to this pool's splitter rather than via this contract: fewer transfers, and
        // this contract never holds fees.
        if (amount0 > 0) poolManager.take(key.currency0, p.splitter, amount0);
        if (amount1 > 0) poolManager.take(key.currency1, p.splitter, amount1);

        return abi.encode(amount0, amount1);
    }

    // ----------------------------------------------------------------- reads

    /// @notice A seeded pool's key. Reverts for a pool this locker never seeded.
    function poolKeys(PoolId id) external view returns (PoolKey memory key) {
        if (positions[id].splitter == address(0)) revert NotSeeded(id);
        key = _keys[id];
    }

    /// @notice The key of the pool `token` was seeded into: where a launch's quote is recorded on
    ///         chain. Reverts for a token this locker never seeded.
    function poolKeyOf(address token) external view returns (PoolKey memory key) {
        PoolId id = poolOf[token];
        if (positions[id].splitter == address(0)) revert NotSeeded(id);
        key = _keys[id];
    }

    /// @notice Whether `id` was seeded here.
    function seeded(PoolId id) external view returns (bool) {
        return positions[id].splitter != address(0);
    }

    /// @notice The v4 position key this locker holds `id`'s liquidity under.
    function positionKey(PoolId id) public view returns (bytes32) {
        Locked memory p = positions[id];
        return Position.calculatePositionKey(address(this), p.tickLower, p.tickUpper, PoolId.unwrap(id));
    }

    /// @notice The liquidity locked in `id`, as the PoolManager holds it. Zero for an unseeded pool.
    function positionLiquidity(PoolId id) external view returns (uint128) {
        if (positions[id].splitter == address(0)) return 0;
        return poolManager.getPositionLiquidity(id, positionKey(id));
    }
}
