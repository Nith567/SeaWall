// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { OptionPosition, PendingOption, Pool, PoolState, OptionStatus } from "../interfaces/OptionTypes.sol";
import { IOptionManager } from "../interfaces/IOptionManager.sol";
import { ICollateralManager } from "../interfaces/ICollateralManager.sol";
import { IPricingEngine } from "../interfaces/IPricingEngine.sol";
import { IETHPriceOracle } from "../interfaces/IETHPriceOracle.sol";
import { MarketParams } from "../oracle/MarketParams.sol";

/// @title OptionManager
/// @notice Lifecycle state machine for fully collateralised European ETH puts.
///
/// @dev All state transitions are deterministic and permissionless once their preconditions hold:
///      - `open`    stages a pending option and reserves `maximumPayout` of LP collateral.
///      - `buy`     creates the position; only reachable in the same atomic execution as `open`,
///                  after the premium has been validated against the on-chain quote.
///      - `exercise` is buyer-only, inside [expiry, expiry + EXERCISE_WINDOW], in the money.
///      - `settle`  pays the buyer. Anyone may trigger it; it can also auto-settle an unexercised
///                  ITM position inside the exercise window (the payout always goes to the buyer).
///      - `expire`  releases collateral for OTM positions and for ITM positions whose exercise
///                  window has closed (European exercise semantics).
///
///      Only the router may mutate state. The router is the Aqua app that executes the SwapVM
///      programs; it forwards `ctx.query.taker` for authorisation checks.
contract OptionManager is IOptionManager, ReentrancyGuard {
    using Math for uint256;

    /// @dev Collateral token units (USDC) are 6 decimals, model prices are 1e18.
    uint256 internal constant COLLATERAL_SCALE = 1e12;
    uint256 internal constant QUANTITY_SCALE = 1e18;

    /// @notice Window after expiry during which the buyer may exercise (European exercise window).
    uint256 public constant EXERCISE_WINDOW = 7 days;

    /// @dev Aqua marks docked strategies with tokensCount == 0xff.
    uint8 internal constant AQUA_DOCKED = 0xff;

    /// @notice The Aqua app (SwapVM router) allowed to drive the lifecycle.
    address public immutable router;
    /// @notice Aqua registry, used to read live maker balances.
    IAqua public immutable AQUA;
    /// @notice Collateral token (USDC).
    address public immutable USDC;
    ICollateralManager public immutable collateral;
    IPricingEngine public immutable pricing;
    MarketParams public immutable marketParams;
    IETHPriceOracle public immutable oracle;

    uint256 public override nextPositionId = 1;

    mapping(uint256 positionId => OptionPosition) private _positions;
    mapping(bytes32 orderHash => PendingOption) private _pending;

    error OnlyRouter(address caller);
    error PoolNotRegistered(bytes32 poolId);
    error PoolNotActive(bytes32 poolId);
    error PoolMakerMismatch(bytes32 poolId, address expected, address actual);
    error ZeroBuyer();
    error InvalidOptionParams();
    error ExpiryNotInFuture(uint256 expiry, uint256 timestamp);
    error TenorTooLong(uint256 tenor, uint256 maxTenor);
    error NotionalTooLarge(uint256 notional, uint256 maxNotional);
    error ZeroNotional();
    error PremiumExceedsNotional(uint256 premium, uint256 notional);
    error PendingAlreadyExists(bytes32 orderHash);
    error NoPendingOption(bytes32 orderHash);
    error BuyerMismatch(address expected, address actual);
    error PremiumTooLow(uint256 paid, uint256 quoted);
    error PendingExpired(bytes32 orderHash, uint256 expiry, uint256 timestamp);
    error PositionNotActive(uint256 positionId, OptionStatus status);
    error UnauthorizedExercise(uint256 positionId, address caller, address buyer);
    error NotYetExpired(uint256 expiry, uint256 timestamp);
    error ExerciseWindowClosed(uint256 positionId, uint256 deadline, uint256 timestamp);
    error NotInTheMoney(uint256 strike, uint256 settlementPrice);
    error PositionNotSettleable(uint256 positionId, OptionStatus status);
    error NotExpirable(uint256 positionId);
    error InvalidSettlementPrice();
    error PayoutExceedsReserved(uint256 payout, uint256 reserved);
    error CannotCancelPending(bytes32 orderHash, address caller);
    error WithdrawTooMuch(bytes32 poolId, uint256 available, uint256 requested);
    error PoolNotFunded(bytes32 poolId, address maker, uint256 balance, uint8 tokensCount);

    event PoolRegistered(bytes32 indexed poolId, address indexed maker, uint256 maxNotionalPerOption, uint256 maxTenor);
    event CollateralSynced(bytes32 indexed poolId, uint256 liveBalance);
    event OptionOpened(
        bytes32 indexed orderHash,
        bytes32 indexed poolId,
        address indexed buyer,
        uint256 strike,
        uint256 quantity,
        uint256 notional,
        uint256 expiry,
        uint256 premium
    );
    event OptionPurchased(
        uint256 indexed positionId, bytes32 indexed orderHash, address indexed buyer, uint256 premium
    );
    event OptionExercised(uint256 indexed positionId, address indexed buyer, uint256 settlementPrice);
    event OptionSettled(uint256 indexed positionId, address indexed buyer, uint256 settlementPrice, uint256 payout);
    event OptionExpired(uint256 indexed positionId, uint256 settlementPrice);
    event PendingCancelled(bytes32 indexed orderHash, address indexed caller);
    event CollateralWithdrawn(bytes32 indexed poolId, address indexed maker, uint256 amount);

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter(msg.sender);
        _;
    }

    constructor(
        address router_,
        address aqua_,
        address usdc_,
        address collateral_,
        address pricing_,
        address marketParams_,
        address oracle_
    ) {
        router = router_;
        AQUA = IAqua(aqua_);
        USDC = usdc_;
        collateral = ICollateralManager(collateral_);
        pricing = IPricingEngine(pricing_);
        marketParams = MarketParams(marketParams_);
        oracle = IETHPriceOracle(oracle_);
    }

    // ---------------------------------------------------------------------
    // Pool registration and collateral sync
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    /// @dev Permissionless: the caller becomes the maker. The manager verifies directly against
    ///      Aqua that the caller has shipped and funded the pool strategy (`poolId`).
    function registerPool(bytes32 poolId, uint256 maxNotionalPerOption, uint256 maxTenor) external {
        address maker = msg.sender;
        (uint248 balance, uint8 tokensCount) = AQUA.rawBalances(maker, router, poolId, USDC);
        if (tokensCount == 0 || tokensCount == AQUA_DOCKED || balance == 0) {
            revert PoolNotFunded(poolId, maker, uint256(balance), tokensCount);
        }
        collateral.createPool(poolId, maker, maxNotionalPerOption, maxTenor);
        emit PoolRegistered(poolId, maker, maxNotionalPerOption, maxTenor);
    }

    /// @inheritdoc IOptionManager
    /// @dev Permissionless: refreshes the cached collateral from the maker's real Aqua balance.
    function syncPool(bytes32 poolId) public {
        Pool memory pool = collateral.getPool(poolId);
        if (!pool.active) revert PoolNotRegistered(poolId);
        (uint248 live,) = AQUA.rawBalances(pool.maker, router, poolId, USDC);
        collateral.syncCollateral(poolId, uint256(live));
        emit CollateralSynced(poolId, uint256(live));
    }

    // ---------------------------------------------------------------------
    // OPTION_OPEN
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    /// @dev Reserves the worst-case liability `strike * quantity` (ETH -> 0), never current intrinsic.
    function open(
        bytes32 orderHash,
        address maker,
        address buyer,
        uint256 strike,
        uint256 quantity,
        uint256 expiry
    )
        external
        onlyRouter
        nonReentrant
        returns (uint256 notional)
    {
        if (_pending[orderHash].createdAt != 0) revert PendingAlreadyExists(orderHash);
        if (buyer == address(0)) revert ZeroBuyer();
        if (strike == 0 || quantity == 0) revert InvalidOptionParams();

        syncPool(orderHash);
        Pool memory pool = collateral.getPool(orderHash);
        if (!pool.active) revert PoolNotRegistered(orderHash);
        if (pool.maker != maker) revert PoolMakerMismatch(orderHash, pool.maker, maker);

        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry, block.timestamp);
        uint256 tenor = expiry - block.timestamp;
        if (tenor > pool.maxTenor) revert TenorTooLong(tenor, pool.maxTenor);

        notional = Math.mulDiv(strike, quantity, QUANTITY_SCALE);
        if (notional == 0) revert ZeroNotional();
        if (notional > pool.maxNotionalPerOption) revert NotionalTooLarge(notional, pool.maxNotionalPerOption);

        uint256 premium = _quotePremium(strike, quantity, expiry);
        if (premium > notional) revert PremiumExceedsNotional(premium, notional);

        collateral.reserve(orderHash, notional);

        _pending[orderHash] = PendingOption({
            pool: orderHash,
            buyer: buyer,
            strike: strike,
            quantity: quantity,
            notional: notional,
            expiry: expiry,
            premium: premium,
            createdAt: block.timestamp
        });

        emit OptionOpened(orderHash, orderHash, buyer, strike, quantity, notional, expiry, premium);
    }

    // ---------------------------------------------------------------------
    // OPTION_BUY
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    function buy(
        bytes32 orderHash,
        address buyer,
        uint256 premiumPaid
    )
        external
        onlyRouter
        nonReentrant
        returns (uint256 positionId)
    {
        PendingOption memory pending = _pending[orderHash];
        if (pending.createdAt == 0) revert NoPendingOption(orderHash);
        if (pending.buyer != buyer) revert BuyerMismatch(pending.buyer, buyer);
        if (premiumPaid < pending.premium) revert PremiumTooLow(premiumPaid, pending.premium);
        if (block.timestamp > pending.expiry) revert PendingExpired(orderHash, pending.expiry, block.timestamp);

        delete _pending[orderHash];

        positionId = nextPositionId++;
        _positions[positionId] = OptionPosition({
            id: positionId,
            buyer: buyer,
            pool: pending.pool,
            notional: pending.notional,
            quantity: pending.quantity,
            strike: pending.strike,
            expiry: pending.expiry,
            premium: premiumPaid,
            settlementPrice: 0,
            payout: 0,
            status: OptionStatus.ACTIVE
        });

        // The premium is pushed into the pool strategy by the SwapVM transfer phase in the same tx.
        collateral.recordPremium(pending.pool, premiumPaid);

        emit OptionPurchased(positionId, orderHash, buyer, premiumPaid);
    }

    // ---------------------------------------------------------------------
    // OPTION_EXERCISE
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    function exercise(uint256 positionId, address caller) external onlyRouter nonReentrant {
        OptionPosition storage position = _positions[positionId];
        if (position.status != OptionStatus.ACTIVE) revert PositionNotActive(positionId, position.status);
        if (position.buyer != caller) revert UnauthorizedExercise(positionId, caller, position.buyer);
        _requireExercisable(position);

        uint256 settlementPrice = _settlementPrice(position.expiry);
        if (settlementPrice >= position.strike) revert NotInTheMoney(position.strike, settlementPrice);

        position.status = OptionStatus.EXERCISED;
        position.settlementPrice = settlementPrice;

        emit OptionExercised(positionId, position.buyer, settlementPrice);
    }

    // ---------------------------------------------------------------------
    // OPTION_SETTLE
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    /// @dev Keeperless: the payout always goes to `position.buyer`, so any caller is safe.
    function settle(uint256 positionId)
        external
        onlyRouter
        nonReentrant
        returns (address buyer, bytes32 pool, uint256 payout)
    {
        OptionPosition storage position = _positions[positionId];
        OptionStatus status = position.status;
        if (status != OptionStatus.ACTIVE && status != OptionStatus.EXERCISED) {
            revert PositionNotSettleable(positionId, status);
        }
        if (block.timestamp < position.expiry) revert NotYetExpired(position.expiry, block.timestamp);

        syncPool(position.pool);

        if (status == OptionStatus.ACTIVE) {
            // Auto-exercise: an unexercised ITM position can be settled by anyone inside the window,
            // and the payout still goes to the buyer.
            _requireExercisable(position);
            uint256 autoPrice = _settlementPrice(position.expiry);
            if (autoPrice >= position.strike) revert NotInTheMoney(position.strike, autoPrice);
            position.settlementPrice = autoPrice;
            emit OptionExercised(positionId, position.buyer, autoPrice);
        }

        uint256 settlementPrice = position.settlementPrice;
        payout = pricing.putPayout(position.strike, settlementPrice, position.quantity);
        if (payout > position.notional) revert PayoutExceedsReserved(payout, position.notional);

        position.payout = payout;
        position.status = OptionStatus.SETTLED;

        // Release the full reserved liability, then account the payout.
        collateral.release(position.pool, position.notional);
        if (payout > 0) collateral.recordPayout(position.pool, payout);

        buyer = position.buyer;
        pool = position.pool;

        emit OptionSettled(positionId, buyer, settlementPrice, payout);
    }

    // ---------------------------------------------------------------------
    // OPTION_EXPIRE
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    function expire(uint256 positionId) external onlyRouter nonReentrant {
        OptionPosition storage position = _positions[positionId];
        if (position.status != OptionStatus.ACTIVE) revert PositionNotActive(positionId, position.status);
        if (block.timestamp < position.expiry) revert NotYetExpired(position.expiry, block.timestamp);

        syncPool(position.pool);

        uint256 settlementPrice = _settlementPrice(position.expiry);

        bool outOfTheMoney = settlementPrice >= position.strike;
        bool windowClosed = block.timestamp > position.expiry + EXERCISE_WINDOW;
        if (!outOfTheMoney && !windowClosed) revert NotExpirable(positionId);

        position.settlementPrice = settlementPrice;
        position.payout = 0;
        position.status = OptionStatus.EXPIRED;

        collateral.release(position.pool, position.notional);

        emit OptionExpired(positionId, settlementPrice);
    }

    // ---------------------------------------------------------------------
    // Collateral withdrawal
    // ---------------------------------------------------------------------

    /// @notice Withdraws available collateral for a pool. The router pulls the tokens afterwards.
    /// @dev Reserved liability stays locked; only `availableCollateral` can leave the pool.
    function withdrawCollateral(bytes32 poolId, address caller, uint256 amount) external onlyRouter nonReentrant {
        syncPool(poolId);
        Pool memory pool = collateral.getPool(poolId);
        if (pool.maker != caller) revert PoolMakerMismatch(poolId, pool.maker, caller);

        uint256 available =
            pool.totalCollateral > pool.reservedLiability ? pool.totalCollateral - pool.reservedLiability : 0;
        if (amount > available) revert WithdrawTooMuch(poolId, available, amount);

        collateral.recordWithdrawal(poolId, amount);
        emit CollateralWithdrawn(poolId, caller, amount);
    }

    // ---------------------------------------------------------------------
    // Pending cancellation
    // ---------------------------------------------------------------------

    /// @inheritdoc IOptionManager
    /// @dev Safety valve: releases the reservation of an opened-but-unbought option. Callable by the
    ///      buyer or the pool maker at any time, and by anyone once the option expiry has passed.
    function cancelPending(bytes32 orderHash) external nonReentrant {
        address caller = msg.sender;
        PendingOption memory pending = _pending[orderHash];
        if (pending.createdAt == 0) revert NoPendingOption(orderHash);

        Pool memory pool = collateral.getPool(pending.pool);
        bool expired = block.timestamp > pending.expiry;
        if (!expired && caller != pending.buyer && caller != pool.maker) {
            revert CannotCancelPending(orderHash, caller);
        }

        delete _pending[orderHash];
        collateral.release(pending.pool, pending.notional);

        emit PendingCancelled(orderHash, caller);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPosition(uint256 positionId) external view returns (OptionPosition memory) {
        return _positions[positionId];
    }

    function getPending(bytes32 orderHash) external view returns (PendingOption memory) {
        return _pending[orderHash];
    }

    /// @notice Live pool snapshot: cached accounting plus the real Aqua balance.
    function poolState(bytes32 poolId) external view returns (PoolState memory state) {
        Pool memory pool = collateral.getPool(poolId);
        uint256 live = 0;
        if (pool.active) {
            (uint248 balance,) = AQUA.rawBalances(pool.maker, router, poolId, USDC);
            live = uint256(balance);
        }
        state = PoolState({
            maker: pool.maker,
            totalCollateral: live,
            reservedLiability: pool.reservedLiability,
            availableCollateral: live > pool.reservedLiability ? live - pool.reservedLiability : 0,
            premiumEarned: pool.premiumEarned,
            payoutsPaid: pool.payoutsPaid,
            maxNotionalPerOption: pool.maxNotionalPerOption,
            maxTenor: pool.maxTenor,
            active: pool.active
        });
    }

    /// @notice Model-based premium quote for the given terms, in collateral token units (USDC 6dp).
    /// @dev This is the exact value the protocol enforces in `OPTION_BUY`. The frontend must not
    ///      invent a premium; it should display this quote.
    function quotePremium(uint256 strike, uint256 quantity, uint256 expiry) external view returns (uint256) {
        return _quotePremium(strike, quantity, expiry);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Model-based premium, converted from 1e18 WAD to collateral token units, rounded up.
    function _quotePremium(uint256 strike, uint256 quantity, uint256 expiry) internal view returns (uint256) {
        uint256 spotWad = oracle.spot();
        uint256 strikeWad = strike * COLLATERAL_SCALE;
        uint256 premiumWad = pricing.quotePremium(
            spotWad, strikeWad, quantity, expiry, marketParams.volatility(), marketParams.riskFreeRate()
        );
        return Math.ceilDiv(premiumWad, COLLATERAL_SCALE);
    }

    /// @dev Settlement price in collateral token units (e.g. USDC 6dp).
    function _settlementPrice(uint256 expiry) internal view returns (uint256) {
        uint256 priceWad = oracle.settlementPrice(expiry);
        if (priceWad == 0) revert InvalidSettlementPrice();
        return priceWad / COLLATERAL_SCALE;
    }

    function _requireExercisable(OptionPosition memory position) internal view {
        if (block.timestamp < position.expiry) revert NotYetExpired(position.expiry, block.timestamp);
        uint256 deadline = position.expiry + EXERCISE_WINDOW;
        if (block.timestamp > deadline) revert ExerciseWindowClosed(position.id, deadline, block.timestamp);
    }
}
