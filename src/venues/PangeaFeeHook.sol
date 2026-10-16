// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FactoryList} from "../FactoryList.sol";

/// @title PangeaFeeHook
/// @notice Takes every pool's fee in the quote asset, at the moment of the swap.
///
/// WHY A HOOK AND NOT A CONVERSION. Uniswap v4 charges its fee in whichever token went into a
/// swap, so a sell leaves the creator holding their own token — a position they have to sell into
/// their own pool to turn into money. Converting at collection time fixes the symptom; this fixes
/// the cause. The token side is never accrued at all.
///
/// HOW IT CATCHES BOTH DIRECTIONS. v4 gives a hook two places to take value, and which one reaches
/// the quote depends on the trade:
///
///   `beforeSwap` can take from the SPECIFIED currency — the input of an exact-in swap. When
///   someone buys, they spend the quote, so the fee comes out of what they are about to spend.
///
///   `afterSwap` can take from the UNSPECIFIED currency — the output of an exact-in swap. When
///   someone sells, they receive the quote, so the fee comes out of what they are about to get.
///
/// Exact-out swaps invert which side is specified, and the same rule still decides it: take the fee
/// wherever the quote happens to be.
///
/// ONE RATE, FOUR SHAPES. The fee is `feeBps` of the GROSS quote amount of the trade -- what the
/// trader hands over on a buy, what the pool pays out on a sell -- whichever way the swap was
/// phrased. On an exact-in swap the hook is looking at the gross amount and takes `feeBps` of it.
/// On an exact-out swap it is looking at the net amount, with the fee about to be added on top, so
/// it grosses up: `net * feeBps / (BPS - feeBps)`. Charging plain `feeBps` there, as this once
/// did, made every exact-out trade cheaper than the same trade phrased exact-in -- 4.76% instead
/// of 5% at the ceiling -- which is a discount every router would have learned to take.
///
///   exact-in buy    beforeSwap   gross = quote asked            fee = gross * f
///   exact-in sell   afterSwap    gross = quote the pool paid    fee = gross * f
///   exact-out buy   afterSwap    net   = quote the pool took    fee = net * f / (1 - f)
///   exact-out sell  beforeSwap   net   = quote asked            fee = net * f / (1 - f)
///
/// THE POOL'S OWN FEE IS ZERO. The hook charges the whole fee, so a pool created with this hook
/// must set `fee: 0` — otherwise a trader pays the pool's fee and the hook's, twice over for the
/// same trade.
///
/// WHAT THIS COSTS, SAID PLAINLY. A fee taken in `beforeSwap` shrinks the amount actually swapped,
/// so the pool's `Swap` event reports a price that already includes the fee — accurate. A fee taken
/// in `afterSwap` does not: the event shows the full swap and the trader quietly receives less, so
/// a chart reading that event overstates what a seller got, by the fee. At 1% that is a 1% error on
/// the sell side only. It is the price of never handing a creator their own token back.
///
/// FEES ARE TAKEN AS CLAIMS, NOT AS TOKENS. A hook runs before the trader has settled, and a
/// single-sided launch opens holding no quote at all -- so taking real currency out of the pool
/// would underflow on the very first buy. Minting an ERC-6909 claim credits this contract inside
/// the pool's own accounting without moving anything. `redeem` turns those claims into real tokens
/// and sends them to the splitter; anyone may call it, and the destination is fixed per pool.
///
/// ONE SWAPPER PAYS NOTHING: THE DEV BUY. A creator may pay for a first buy of their own token
/// along with the launch fee. This chain's LaunchFeeCollector makes it, as the pool's first trade,
/// inside the launch transaction, with the creator's own money -- and by the product's rule it is
/// charged no trading fee. So a swap whose `sender` (the address that called
/// `poolManager.swap`) is `devBuyer` is charged nothing, and every other swap exactly what it was.
///
/// Why that cannot be used by anyone else: `sender` is whoever called the PoolManager, which no
/// third party can pretend to be. The collector calls `swap` from one place only -- its own unlock
/// callback, which runs only while its `onLaunch` is executing, which only the factory can call,
/// once per launch, as the launch's last step. It has no function that swaps for a caller, takes
/// a pool key from a caller, or forwards a call. `devBuyer` is a constructor argument -- part of
/// the init code, and so of the mined address -- and can never be changed.
///
/// THE PRICE NEVER LEAVES THE LAUNCH'S RANGE. A launch's pool holds one position, the slice, on one
/// side of the opening price and running to the end of usable ticks on that side; beyond the
/// other edge -- the tick the pool opened next to -- there is no liquidity at all. A sell larger
/// than the quote the pool holds walks the price across that edge and, with nothing there to stop
/// it, on to the swap's price limit, which every router sets at the extreme: two base units of the
/// token, bridged in from another chain, were enough on a fresh pool. The pool is then out of
/// range, its active liquidity is zero, and Uniswap's routers do not route it.
///
/// So each pool's edge is recorded when it is registered (`Config.edgeTick`), and a swap that
/// leaves the pool's tick on the empty side of it is refused in `afterSwap`, where the pool's own
/// tick after the swap is read rather than predicted. That is v4's own definition of the position
/// being in range -- `tickLower <= tick < tickUpper` -- held at the one edge a trade can reach. A
/// buy, a sell back to anywhere inside the range, the dev buy and every hop of a multi-hop route
/// that stays inside it are untouched; a sell of more than the pool can pay for is refused
/// whole, and the seller can sell less. `beforeSwap` could not do this: a hook cannot change a
/// swap's price limit, and requiring callers to set one at the edge would refuse every router.
///
/// FACTORIES: AN APPEND-ONLY LIST, FOR NEW POOLS ONLY. The pools this hook serves are registered by
/// a launch factory. The deployer may ADD a factory (`addFactory`) and never remove or replace
/// one, so a later factory -- a new token, a new opening rule -- reuses this hook and its address.
/// An added factory can register NEW pools only: a pool is registered once, records the factory
/// that registered it (`factoryOf`), and its splitter, fee and range edge are fixed from then on;
/// nothing here lets any factory, or anyone, change them. Everything else is as it was: the fee is
/// fixed per pool, only the locker adds liquidity, the range check holds on every swap, and there
/// is no pause, no owner of the swap path and no proxy.
///
/// AND THE RISK, WHICH IS REAL. This sits on the swap path of every trade, for the life of every
/// pool that uses it. A pool's hook cannot be changed afterwards. One hook serves every Pangea
/// launch, so a bug here does not break one token's fees — it stops trading on all of them. That
/// is strictly worse than the failure mode of converting at collection, where the worst case is a
/// sweep that reverts, and it is the trade being accepted deliberately.
contract PangeaFeeHook is IHooks, IUnlockCallback, FactoryList {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    /// @notice The six permissions this hook needs, which its address must encode.
    /// @dev v4 reads a hook's capabilities from its own address bits, so this contract only works
    ///      when deployed to an address whose low bits are exactly these. `MINED_FLAGS` is what a
    ///      deployer must mine a CREATE2 salt for.
    ///
    ///      BEFORE_ADD_LIQUIDITY is here to refuse it. The fee is charged on swaps, and the pool's
    ///      own fee is zero, so liquidity anyone else added was a way to trade through the pool
    ///      without paying: a holder who rested their tokens in the tick above the price sold them
    ///      to the next buyer as a maker, fee-free, and the mirror image bought. Every such fill
    ///      was a swap's worth of fee the creator and the platform did not get. Nobody had an
    ///      honest reason to add liquidity either -- a pool with no fee pays its providers
    ///      nothing -- so only the chain's LiquidityLocker may, which adds each launch's slice
    ///      once and can never take it out.
    uint160 public constant MINED_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 internal constant BPS = 10_000;

    /// @notice The bounds a pool's fee must sit within. The same two numbers FeeSplitter enforces;
    ///         the factory builds a splitter with this fee first, so this is a second lock on the
    ///         same door rather than the only one.
    uint16 public constant MIN_FEE_BPS = 30;
    uint16 public constant MAX_FEE_BPS = 500;

    IPoolManager public immutable poolManager;

    /// @notice May add a factory to the list that may register NEW pools (`addFactory`). It can
    ///         never remove one, nor change a pool that is registered. See "FACTORIES".
    address public immutable deployer;

    /// @notice The factory that registered each pool. Written once, with the pool's config.
    mapping(PoolId => address) public factoryOf;

    struct Config {
        /// @notice Where this pool's fees go.
        address splitter;
        /// @notice Which side of the pair is the money.
        bool quoteIsCurrency0;
        /// @notice The whole fee, in bps. The pool itself charges nothing.
        uint16 feeBps;
        bool registered;
        /// @notice The edge of the launch's range on its empty side: the tick the pool opened next
        ///         to. With the quote as currency0 (the token is currency1) the range lies below it
        ///         and the pool's tick must stay under it; otherwise the range starts at it and the
        ///         tick must stay at or above it. In the same slot as the rest, so a swap still
        ///         reads one.
        int24 edgeTick;
    }

    mapping(PoolId => Config) public configs;

    /// @notice The one address that may add liquidity to any pool this hook serves: this chain's
    ///         LiquidityLocker, which adds each launch's slice once, as that launch's own
    ///         position, and has no code that can take it out.
    /// @dev Immutable, and part of the init code: the locker is deployed before the hook, and
    ///      nobody can ever name another. It replaced a per-pool `seederOf` the factory wrote at
    ///      every launch.
    address public immutable locker;

    /// @notice Addresses besides the locker that may ADD liquidity, set by `factoryAdmin`. Empty
    ///         at deploy, so nobody else can until the admin names one (the platform's own
    ///         rebalancing vault, to deepen pools from its profit).
    /// @dev Optional and off by default. It covers adding only: v4 sends a removal to
    ///      `beforeRemoveLiquidity`, which this hook does not ask for, so whoever owns a position can
    ///      take it out as before, and the launch's own slice stays locked in the locker, which has
    ///      no code that removes. `sender` is the contract that calls the pool manager, so the
    ///      address named must call `modifyLiquidity` itself -- naming a shared router or position
    ///      manager would let everyone through it add. A named adder's resting liquidity fills
    ///      swaps without this hook's fee on its part of the fill, the reason the door is shut to
    ///      everyone else (see `MINED_FLAGS`); for the platform's own vault that is accepted.
    mapping(address => bool) public isLiquidityAdder;

    /// @notice Claims accrued per pool, per currency, waiting to be redeemed into real tokens.
    mapping(PoolId => mapping(Currency => uint256)) public owed;

    /// @notice The one address whose swaps are charged no fee: this chain's LaunchFeeCollector,
    ///         which makes each launch's dev buy.
    /// @dev Immutable, so the exemption check on every swap costs no storage read. That fixes the
    ///      deploy order: the collector first, then this hook, mined and deployed with the
    ///      collector's address in its init code, then the factory. There is no way to exempt
    ///      anybody else, before a pool opens or after.
    address public immutable devBuyer;

    event Registered(PoolId indexed id, address splitter, uint16 feeBps, bool quoteIsCurrency0, int24 edgeTick);
    event Redeemed(PoolId indexed id, Currency currency, uint256 amount, address to);
    event FeeTaken(PoolId indexed id, Currency currency, uint256 amount);
    event LiquidityAdderSet(address indexed adder, bool allowed);

    error NotPoolManager();
    error NotFactory();
    error NotDeployer();
    error AlreadyRegistered();
    error NotRegistered();
    error WrongFlags(uint160 have, uint160 want);
    error HookNotImplemented();
    error NothingOwed();
    error ZeroSplitter();
    error PartialFill(uint256 asked, uint256 traded);
    error ZeroAddress();
    error NothingSwapped();
    error WrongHook(address hooks);
    error PoolFeeNotZero(uint24 fee);
    error FeeOutOfRange(uint16 feeBps);
    error OnlyLocker(address sender);
    /// @notice The swap would leave the pool's tick beyond its range's edge, on the side with no
    ///         liquidity. See "THE PRICE NEVER LEAVES THE LAUNCH'S RANGE".
    error OutOfRange(int24 tick, int24 edgeTick);
    /// @notice The pool would open on the empty side of the edge it was registered with.
    error OpensOutOfRange(uint160 sqrtPriceX96, int24 edgeTick);

    constructor(address poolManager_, address deployer_, address devBuyer_, address locker_) {
        // Fail at deployment rather than at the first swap. A hook at an address without the right
        // bits is not a hook v4 will ever call, and finding that out from a pool that silently
        // charges nothing is far worse than a failed deploy.
        uint160 flags = uint160(address(this)) & Hooks.ALL_HOOK_MASK;
        if (flags != MINED_FLAGS) revert WrongFlags(flags, MINED_FLAGS);

        if (
            poolManager_ == address(0) || deployer_ == address(0) || devBuyer_ == address(0) || locker_ == address(0)
        ) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        deployer = deployer_;
        devBuyer = devBuyer_;
        locker = locker_;
        _initFactoryAdmin(deployer_);
    }


    /// @notice Allow or stop `adder` adding liquidity to the pools this hook serves. See
    ///         `isLiquidityAdder`. The factory admin only.
    function setLiquidityAdder(address adder, bool allowed) external onlyFactoryAdmin {
        if (adder == address(0)) revert ZeroAddress();
        isLiquidityAdder[adder] = allowed;
        emit LiquidityAdderSet(adder, allowed);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Record where a pool's fees go, which of its currencies is the money, and the edge of
    ///         its launch's range on the empty side, which no swap may leave the price beyond.
    /// @dev Once only. A pool whose fee destination could be changed later would make "the fee goes
    ///      to the creator" a statement about today rather than about the contract. `edgeTick` is
    ///      the launch's start tick: the locked position's `tickUpper` with the token as
    ///      currency1, its `tickLower` as currency0. `beforeInitialize` holds the opening price to
    ///      it. Who may add the pool's liquidity is not an argument: it is `locker`, for every pool.
    function register(
        PoolKey calldata key,
        address splitter,
        bool quoteIsCurrency0,
        uint16 feeBps,
        int24 edgeTick
    ) external {
        if (!isFactory[msg.sender]) revert NotFactory();
        // A zero destination would send every fee this pool ever earns to address(0), with no way
        // to recover it and nothing to signal it had happened. Caught here because this is the one
        // place it can enter, rather than trusting each caller to have got it right.
        if (splitter == address(0)) revert ZeroSplitter();
        // The factory is trusted to build the key, and these are the three things about it that
        // would be silent if it ever got them wrong: a key naming another hook is a pool this
        // contract is never called for, a pool fee above zero bills every trader twice, and a fee
        // outside the bounds is one no splitter would have accepted.
        if (address(key.hooks) != address(this)) revert WrongHook(address(key.hooks));
        if (key.fee != 0) revert PoolFeeNotZero(key.fee);
        if (feeBps < MIN_FEE_BPS || feeBps > MAX_FEE_BPS) revert FeeOutOfRange(feeBps);

        PoolId id = key.toId();
        if (configs[id].registered) revert AlreadyRegistered();

        configs[id] = Config({
            splitter: splitter,
            quoteIsCurrency0: quoteIsCurrency0,
            feeBps: feeBps,
            registered: true,
            edgeTick: edgeTick
        });
        factoryOf[id] = msg.sender;
        emit Registered(id, splitter, feeBps, quoteIsCurrency0, edgeTick);
    }

    /// @notice Turn a pool's accrued claims into real tokens, sent to its splitter.
    ///
    /// @dev Permissionless. The destination is whatever was registered for that pool and cannot be
    ///      changed, so there is nothing a caller can redirect -- only the timing is theirs. The
    ///      same reasoning as `release` on the splitter: a creator should never be waiting on us.
    function redeem(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();

        amount0 = owed[id][key.currency0];
        amount1 = owed[id][key.currency1];
        if (amount0 == 0 && amount1 == 0) revert NothingOwed();

        // Cleared before the unlock, so a currency that re-enters cannot be redeemed twice.
        if (amount0 > 0) owed[id][key.currency0] = 0;
        if (amount1 > 0) owed[id][key.currency1] = 0;

        poolManager.unlock(abi.encode(key, c.splitter, amount0, amount1));

        if (amount0 > 0) emit Redeemed(id, key.currency0, amount0, c.splitter);
        if (amount1 > 0) emit Redeemed(id, key.currency1, amount1, c.splitter);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address to, uint256 amount0, uint256 amount1) =
            abi.decode(data, (PoolKey, address, uint256, uint256));

        // Burning the claim is what gives this contract a positive delta to take against.
        if (amount0 > 0) {
            poolManager.burn(address(this), key.currency0.toId(), amount0);
            poolManager.take(key.currency0, to, amount0);
        }
        if (amount1 > 0) {
            poolManager.burn(address(this), key.currency1.toId(), amount1);
            poolManager.take(key.currency1, to, amount1);
        }
        return "";
    }

    // ------------------------------------------------------------ the swap

    /// @inheritdoc IHooks
    /// @dev Takes the fee when the quote is the specified currency — a buy, for an exact-in swap.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();

        // Exact-in specifies the input; exact-out specifies the output.
        bool exactIn = params.amountSpecified < 0;
        Currency specified = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        Currency quote = c.quoteIsCurrency0 ? key.currency0 : key.currency1;

        // The quote is on the other side this time; afterSwap will catch it.
        if (Currency.unwrap(specified) != Currency.unwrap(quote)) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // The dev buy pays nothing. Read only here, where a fee would otherwise be charged.
        if (sender == devBuyer) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        // Exact-in names the gross amount; exact-out names the net one and the pool pays the fee
        // on top of it.
        uint256 amount = uint256(exactIn ? -params.amountSpecified : params.amountSpecified);
        uint256 fee = _fee(amount, c.feeBps, !exactIn);
        if (fee == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        // A positive specified delta is the hook taking that much; the pool then swaps what is
        // left, so the Swap event already reflects the fee.
        //
        // Minted as a claim, not taken as currency: the trader has not settled yet, and on a
        // single-sided pool there is no quote in there to take.
        poolManager.mint(address(this), quote.toId(), fee);
        owed[id][quote] += fee;
        emit FeeTaken(id, quote, fee);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Takes the fee when the quote is the unspecified currency — a sell, for an exact-in swap.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();

        // A swap that moved nothing on either side still moved the price. Into the empty side of
        // a fresh single-sided pool there is no liquidity to trade against, so for the cost of gas
        // alone anyone could walk the price to the far limit and leave it there. Nothing honest
        // looks like this -- a real trade moves at least one of the two -- so it is refused.
        if (delta.amount0() == 0 && delta.amount1() == 0) revert NothingSwapped();

        // And no swap -- whoever makes it, whichever way it is phrased -- may leave the price on the
        // empty side of the launch's range, where the pool has no active liquidity and routers do
        // not see it. The pool's tick after the swap, read rather than predicted: v4's in-range
        // test is `tickLower <= tick < tickUpper`, and this is it at the edge a trade can reach.
        {
            (, int24 tick,,) = poolManager.getSlot0(id);
            if (c.quoteIsCurrency0 ? tick >= c.edgeTick : tick < c.edgeTick) revert OutOfRange(tick, c.edgeTick);
        }

        bool exactIn = params.amountSpecified < 0;
        Currency specified = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        Currency quote = c.quoteIsCurrency0 ? key.currency0 : key.currency1;

        // Already handled in beforeSwap -- provided the swap went through in full. The dev buy was
        // charged nothing there, so it is held to the full amount with no fee taken out of it.
        if (Currency.unwrap(specified) == Currency.unwrap(quote)) {
            _requireFullFill(
                params.amountSpecified,
                c.quoteIsCurrency0 ? delta.amount0() : delta.amount1(),
                sender == devBuyer ? 0 : c.feeBps
            );
            return (IHooks.afterSwap.selector, 0);
        }

        // How much quote moved, in either direction. The sign says which way it went and does not
        // change the fee: a positive hook delta takes from the trader either way -- out of what
        // they are about to receive on an exact-in sell, or added to what they are about to pay on
        // an exact-out buy. Guarding on `> 0` let exact-out buys through for free, because there
        // the quote is what the trader hands over rather than what they get.
        int128 quoteDelta = c.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 moved = uint256(uint128(quoteDelta < 0 ? -quoteDelta : quoteDelta));
        if (moved == 0) return (IHooks.afterSwap.selector, 0);
        // The dev buy pays nothing. (The collector only ever makes exact-in buys, which are
        // charged in beforeSwap; this keeps the rule "the dev buyer pays nothing" true of every
        // shape rather than of the one it uses.)
        if (sender == devBuyer) return (IHooks.afterSwap.selector, 0);

        // Exact-in here is a sell: `moved` is what the pool paid out, the gross amount, and the
        // fee comes out of it. Exact-out is a buy: `moved` is what the pool took, the net amount,
        // and the fee goes on top.
        uint256 fee = _fee(moved, c.feeBps, !exactIn);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        poolManager.mint(address(this), quote.toId(), fee);
        owed[id][quote] += fee;
        emit FeeTaken(id, quote, fee);

        // Positive is the hook's claim on the unspecified currency, taken out of the trader's
        // output. The Swap event was emitted before this ran, so it does NOT reflect this fee --
        // see the note at the top of the contract.
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev A fee taken in `beforeSwap` is charged on the amount ASKED for, before anyone knows how
    ///      much will actually trade. A swap stopped short by its price limit would therefore pay
    ///      the fee on the whole request while trading only part of it, and the hook has no way to
    ///      hand the difference back -- `afterSwap` can only adjust the other currency. So a
    ///      partial fill is refused instead. The caller set that limit as a bound on the price
    ///      they would accept, and a revert honours it; an overcharge would not.
    ///
    ///      The pool swaps the request less the fee on the way in, or plus the fee on the way out,
    ///      and v4 trades exactly that amount unless the limit stops it -- so equality is the test.
    ///      The fee is recomputed by the same function `beforeSwap` used, so the two cannot differ
    ///      by a rounding.
    function _requireFullFill(int256 amountSpecified, int128 quoteDelta, uint16 feeBps) internal pure {
        bool exactIn = amountSpecified < 0;
        uint256 asked = uint256(exactIn ? -amountSpecified : amountSpecified);
        uint256 fee = _fee(asked, feeBps, !exactIn);
        uint256 traded = uint256(uint128(quoteDelta < 0 ? -quoteDelta : quoteDelta));
        if (traded != (exactIn ? asked - fee : asked + fee)) revert PartialFill(asked, traded);
    }

    /// @dev `feeBps` of the gross amount, given either the gross amount itself or the net one.
    ///      Rounds down both ways, so the trader is never charged more than the rate.
    function _fee(uint256 amount, uint16 feeBps, bool amountIsNet) internal pure returns (uint256) {
        return amountIsNet ? (amount * feeBps) / (BPS - feeBps) : (amount * feeBps) / BPS;
    }

    // ------------------------------------------------------- initialization

    /// @inheritdoc IHooks
    /// @dev Refuses a pool the factory has not registered. Opening a v4 pool is permissionless and
    ///      a launch's pool key is computable in advance -- the token address is CREATE2, the rest
    ///      is public -- so without this anyone could open the pool first, at any price, and the
    ///      locker's own `initialize` would then revert and take the launch with it. The factory
    ///      registers and seeds in one transaction, so a registered pool that is not yet open is a
    ///      state no stranger ever sees.
    ///
    ///      And the pool must open on its range's side of the edge it was registered with -- one
    ///      unit of square-root price under it with the token as currency1, on it as currency0 --
    ///      so "the price never leaves the range" holds from the first block rather than from the
    ///      first trade.
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        Config memory c = configs[key.toId()];
        if (!c.registered) revert NotRegistered();
        uint160 edge = TickMath.getSqrtPriceAtTick(c.edgeTick);
        if (c.quoteIsCurrency0 ? sqrtPriceX96 >= edge : sqrtPriceX96 < edge) {
            revert OpensOutOfRange(sqrtPriceX96, c.edgeTick);
        }
        return IHooks.beforeInitialize.selector;
    }

    // ------------------------------------------- everything v4 may still call

    /// @dev v4 calls only what a hook's address advertises, so these can never be reached. They
    ///      exist because IHooks demands them, and they revert rather than returning a selector so
    ///      that a mis-mined address fails loudly instead of silently approving a call.

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @notice Only the locker adds liquidity, and whoever the admin has named (`isLiquidityAdder`,
    ///         empty by default). See `MINED_FLAGS`.
    /// @dev v4 calls this for a positive liquidity change only; a zero one -- how the locker
    ///      collects -- and a removal go to `beforeRemoveLiquidity`, which this hook does not ask
    ///      for. The locker adds to a pool once, for the factory, in the launch that registered
    ///      it, and a pool cannot open here unregistered (`beforeInitialize`). Nothing here reads
    ///      who the pool manager is: an impostor calling this changes nothing, because it changes
    ///      no state.
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (sender != locker && !isLiquidityAdder[sender]) revert OnlyLocker(sender);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
