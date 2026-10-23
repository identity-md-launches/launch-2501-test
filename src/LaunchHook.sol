// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title LaunchHook
/// @notice Uniswap v4 hook for the TEST launch pool (native ETH / TEST). Every swap pays a fee in ETH that is
/// split between a research vault and a dev wallet, both fixed at construction.
///
/// Fee schedule (basis points of the swap's gross ETH amount, see `_collect`):
/// - Buys (ETH in, TEST out) in the first `LAUNCH_WINDOW` seconds after the pool is initialized pay a fee
///   that decays linearly from `launchFeeBps` (30% at t = 0) to `baseFeeBps` (2% at t = 3600).
/// - Sells (TEST in, ETH out) pay `baseFeeBps` (2%) at all times. After the window every swap pays it.
/// - Of each fee, `DEV_SHARE_BPS` (0.5%) of the gross ETH goes to the dev wallet and the rest to the vault.
///
/// The fee is always taken on the ETH side: from the swapper's ETH on a buy, from the pool's ETH payout on a
/// sell, for exact-input and exact-output swaps alike. When ETH is the specified currency (exact-input buy,
/// exact-output sell) the fee is taken in `beforeSwap` through the before-swap return delta; when ETH is the
/// unspecified currency (exact-output buy, exact-input sell) it is taken in `afterSwap` through the after-swap
/// return delta. The amount decided in `beforeSwap` reaches `afterSwap` through transient storage (EIP-1153).
/// A fee sized in `beforeSwap` is checked in `afterSwap` against the ETH the pool actually swapped: an
/// exact-input buy or exact-output sell that stops early (price limit reached, or the pool's ETH exhausted) is
/// a partial fill and reverts with `PartialFill`, so the fee can never exceed the rate on the ETH swapped.
/// Exact-output buys and exact-input sells size the fee from the executed amount and may fill partially.
///
/// Payout happens inside the swap. The hook takes the ETH from the PoolManager and pushes it to both
/// recipients. If the PoolManager does not hold enough ETH yet (a fresh pool seeded with tokens only, before
/// the first buyer's ETH is settled) the hook mints itself an ERC-6909 ETH claim instead and credits the
/// recipients; anyone may later call `redeemClaims`. If a push to a recipient fails the swap still succeeds:
/// the amount is credited to that recipient, which pulls it with `withdraw`; anyone may also deliver it to the
/// recipient with `withdrawFor`.
///
/// The owner may only lower `launchFeeBps` and `baseFeeBps` (never raise them, never below the dev share),
/// and may transfer or renounce ownership. Nothing here moves liquidity, mints tokens, pauses swaps or
/// touches ETH owed to a recipient.
contract LaunchHook is IHooks, IUnlockCallback, Ownable {
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Length of the launch window in seconds, counted from pool initialization.
    uint256 public constant LAUNCH_WINDOW = 3600;
    /// @notice Hard cap of the launch fee (30%). The owner can only go below it.
    uint16 public constant MAX_LAUNCH_FEE_BPS = 3000;
    /// @notice Hard cap of the base fee (2%). The owner can only go below it.
    uint16 public constant MAX_BASE_FEE_BPS = 200;
    /// @notice Dev wallet share of every swap's gross ETH amount (0.5%). Fixed; the base fee can never go below it.
    uint16 public constant DEV_SHARE_BPS = 50;
    /// @notice Gas forwarded on a push payout. A recipient needing more is credited and pulls with `withdraw`,
    /// which forwards all gas; the bound keeps a slow recipient from making every swap expensive.
    uint256 public constant PAYOUT_GAS = 100_000;
    /// @notice ERC-6909 id of native ETH in the PoolManager.
    uint256 public constant ETH_CLAIM_ID = 0;

    // Transient slots (EIP-1153) carrying `beforeSwap`'s decision to `afterSwap` within one swap.
    bytes32 private constant T_FEE_SLOT = keccak256("LaunchHook.transient.fee");
    bytes32 private constant T_RATE_SLOT = keccak256("LaunchHook.transient.rate");

    // ------------------------------------------------------------------------------------------------
    // Immutables
    // ------------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The launch token; the only currency this hook pairs with ETH.
    address public immutable token;
    /// @notice Receives everything above the dev share.
    address public immutable researchVault;
    /// @notice Receives `DEV_SHARE_BPS` of every swap's gross ETH amount.
    address public immutable devWallet;

    // ------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------

    /// @notice Launch fee for buys at t = 0, in bps. Starts at the 30% cap; the owner can only lower it.
    uint16 public launchFeeBps = MAX_LAUNCH_FEE_BPS;
    /// @notice Base fee for sells, and for every swap after the window, in bps. Starts at the 2% cap.
    uint16 public baseFeeBps = MAX_BASE_FEE_BPS;
    /// @notice Timestamp of pool initialization; zero until `afterInitialize` ran.
    uint64 public launchedAt;
    /// @notice The one pool this hook serves.
    PoolId public poolId;
    /// @notice ETH owed to a recipient that could not be pushed (or that is still an ERC-6909 claim).
    mapping(address recipient => uint256 amount) public owed;

    // ------------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------------

    event PoolLaunched(PoolId indexed poolId, uint256 launchedAt);
    event FeeCharged(
        bool indexed buy, bool exactInput, uint256 grossEth, uint256 fee, uint256 devAmount, uint256 vaultAmount
    );
    event FeeDeferredAsClaim(uint256 amount);
    event PaidOut(address indexed recipient, uint256 amount);
    event PayoutCredited(address indexed recipient, uint256 amount);
    event Withdrawn(address indexed recipient, address indexed to, uint256 amount);
    event ClaimsRedeemed(uint256 amount);
    event LaunchFeeLowered(uint16 oldBps, uint16 newBps);
    event BaseFeeLowered(uint16 oldBps, uint16 newBps);

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error AlreadyInitialized();
    error WrongPool();
    error FeeCanOnlyDecrease();
    error FeeBelowDevShare();
    error LaunchFeeBelowBaseFee();
    error NothingOwed();
    error WithdrawFailed();
    error NotFromPoolManager();
    /// @notice An exact-input buy or exact-output sell stopped before its full ETH amount was swapped.
    /// `assumed` is the pool ETH the fee was sized for, `executed` what the pool actually swapped.
    error PartialFill(uint256 assumed, uint256 executed);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (manifest: "$poolManager").
    /// @param token_ The launch token (manifest: "$token").
    /// @param owner_ Owner of the fee-lowering functions (manifest: "$owner").
    /// @param researchVault_ Research vault, receives the fee above the dev share.
    /// @param devWallet_ Dev wallet, receives the 0.5% dev share.
    constructor(IPoolManager poolManager_, address token_, address owner_, address researchVault_, address devWallet_)
        Ownable(owner_)
    {
        if (address(poolManager_) == address(0) || token_ == address(0)) revert ZeroAddress();
        if (researchVault_ == address(0) || devWallet_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        token = token_;
        researchVault = researchVault_;
        devWallet = devWallet_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice ETH arrives only from the PoolManager (`take`). Anything else is refused so no ETH gets stuck.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotFromPoolManager();
    }

    // ------------------------------------------------------------------------------------------------
    // Permissions
    // ------------------------------------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------------
    // Fee views
    // ------------------------------------------------------------------------------------------------

    /// @notice The buy fee in bps at `timestamp`, given the current fee settings.
    function buyFeeBpsAt(uint256 timestamp) public view returns (uint256) {
        uint256 start = launchedAt;
        if (start == 0 || timestamp < start) return launchFeeBps;
        uint256 elapsed = timestamp - start;
        if (elapsed >= LAUNCH_WINDOW) return baseFeeBps;
        uint256 launch = launchFeeBps;
        uint256 base = baseFeeBps;
        return launch - (launch - base) * elapsed / LAUNCH_WINDOW;
    }

    /// @notice The buy fee in bps right now.
    function buyFeeBps() public view returns (uint256) {
        return buyFeeBpsAt(block.timestamp);
    }

    /// @notice The sell fee in bps (always the base fee).
    function sellFeeBps() public view returns (uint256) {
        return baseFeeBps;
    }

    /// @notice Fee owed in ETH on a swap whose gross ETH amount is `grossEth`, split into dev and vault parts.
    function splitFee(uint256 grossEth, uint256 rateBps)
        public
        pure
        returns (uint256 fee, uint256 devAmount, uint256 vaultAmount)
    {
        fee = grossEth * rateBps / BPS;
        devAmount = grossEth * DEV_SHARE_BPS / BPS;
        if (devAmount > fee) devAmount = fee;
        vaultAmount = fee - devAmount;
    }

    // ------------------------------------------------------------------------------------------------
    // Owner: fees can only go down
    // ------------------------------------------------------------------------------------------------

    /// @notice Lower the launch fee. Never above the current value, never below the base fee.
    function setLaunchFee(uint16 newBps) external onlyOwner {
        uint16 old = launchFeeBps;
        if (newBps > old) revert FeeCanOnlyDecrease();
        if (newBps < baseFeeBps) revert LaunchFeeBelowBaseFee();
        launchFeeBps = newBps;
        emit LaunchFeeLowered(old, newBps);
    }

    /// @notice Lower the base fee. Never above the current value, never below the dev share.
    function setBaseFee(uint16 newBps) external onlyOwner {
        uint16 old = baseFeeBps;
        if (newBps > old) revert FeeCanOnlyDecrease();
        if (newBps < DEV_SHARE_BPS) revert FeeBelowDevShare();
        baseFeeBps = newBps;
        emit BaseFeeLowered(old, newBps);
    }

    // ------------------------------------------------------------------------------------------------
    // Recipients: pull and claim redemption
    // ------------------------------------------------------------------------------------------------

    /// @notice A recipient pulls what it is owed to `to`. Redeems the hook's ETH claims first if needed.
    function withdraw(address to) external {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        if (address(this).balance < amount) _redeemClaims();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(msg.sender, to, amount);
    }

    /// @notice Anyone may deliver a recipient's whole credit to that recipient, with all remaining gas. For a
    /// recipient contract that cannot call `withdraw` itself, or whose `receive` needs more than `PAYOUT_GAS`.
    /// The ETH can only go to the recipient, so the caller gains nothing but the delivery.
    function withdrawFor(address recipient) external {
        uint256 amount = owed[recipient];
        if (amount == 0) revert NothingOwed();
        owed[recipient] = 0;
        if (address(this).balance < amount) _redeemClaims();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(recipient, recipient, amount);
    }

    /// @notice Anyone may turn the hook's ERC-6909 ETH claims into ETH and push what is owed to both recipients.
    function redeemClaims() external {
        _redeemClaims();
        _flush(devWallet);
        _flush(researchVault);
    }

    /// @notice ETH claims the hook holds in the PoolManager, not yet redeemed.
    function pendingClaims() public view returns (uint256) {
        return poolManager.balanceOf(address(this), ETH_CLAIM_ID);
    }

    /// @dev PoolManager unlock callback used by `_redeemClaims`: burn the claim, take the ETH.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), ETH_CLAIM_ID, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        return "";
    }

    // ------------------------------------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (launchedAt != 0) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token) revert WrongPool();
        launchedAt = uint64(block.timestamp);
        PoolId id = key.toId();
        poolId = id;
        emit PoolLaunched(id, block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Takes the fee here when ETH is the specified currency (exact-input buy, exact-output sell). The
    /// rate and the amount taken are left in transient storage for `afterSwap`.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool buy = params.zeroForOne;
        uint256 rate = buy ? buyFeeBps() : baseFeeBps;
        uint256 fee;
        if (buy && params.amountSpecified < 0) {
            // Exact-input buy: the specified amount is the swapper's ETH. Take `rate` of it up front.
            fee = uint256(-params.amountSpecified) * rate / BPS;
        } else if (!buy && params.amountSpecified > 0) {
            // Exact-output sell: the specified amount is the ETH the swapper wants net. The pool pays out
            // gross = net / (1 - rate); the difference is the fee.
            fee = uint256(params.amountSpecified) * rate / (BPS - rate);
        }
        _tstore(T_RATE_SLOT, rate);
        _tstore(T_FEE_SLOT, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Takes the fee here when ETH is the unspecified currency (exact-output buy, exact-input sell),
    /// checks a fee taken in `beforeSwap` against the executed fill, and pays out whichever fee this swap owes.
    /// `delta` is the pool's own leg of the swap, before the hook's deltas are applied.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 rate = _tload(T_RATE_SLOT);
        uint256 feeFromBefore = _tload(T_FEE_SLOT);
        _tstore(T_RATE_SLOT, 0);
        _tstore(T_FEE_SLOT, 0);

        bool buy = params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;
        uint256 fee;
        uint256 gross;
        int128 hookDelta;
        if (exactInput == buy) {
            // ETH was the specified currency: the fee was already taken in beforeSwap, sized from the amount
            // the swapper specified. `delta` is the pool's own leg (the specified amount minus that fee). It
            // is smaller when the swap stopped early, at `sqrtPriceLimitX96` or because the pool ran out of
            // ETH, and the specified delta cannot be adjusted here, so such a partial fill is refused instead
            // of charging the fee on ETH that was never swapped.
            fee = feeFromBefore;
            uint256 executed;
            uint256 assumed;
            if (buy) {
                gross = uint256(-params.amountSpecified);
                assumed = gross - fee;
                executed = uint256(SafeCast.toUint128(-delta.amount0()));
            } else {
                gross = uint256(params.amountSpecified) + fee;
                assumed = gross;
                executed = uint256(SafeCast.toUint128(delta.amount0()));
            }
            if (executed != assumed) revert PartialFill(assumed, executed);
        } else if (buy) {
            // Exact-output buy: the pool's ETH input is known only now. The swapper pays gross = pool / (1 - rate).
            uint256 poolEth = uint256(SafeCast.toUint128(-delta.amount0()));
            fee = poolEth * rate / (BPS - rate);
            gross = poolEth + fee;
            hookDelta = fee.toInt128();
        } else {
            // Exact-input sell: the pool's ETH payout is the gross amount; the swapper receives it minus the fee.
            gross = uint256(SafeCast.toUint128(delta.amount0()));
            fee = gross * rate / BPS;
            hookDelta = fee.toInt128();
        }

        if (fee > 0) _collect(buy, exactInput, gross, fee);
        return (IHooks.afterSwap.selector, hookDelta);
    }

    // Callbacks this hook does not enable. The PoolManager never calls them; anyone else is refused.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
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
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------

    /// @dev Moves `fee` ETH out of the PoolManager (or mints a claim for it) and pays both recipients.
    function _collect(bool buy, bool exactInput, uint256 gross, uint256 fee) private {
        uint256 devAmount = gross * DEV_SHARE_BPS / BPS;
        if (devAmount > fee) devAmount = fee;
        uint256 vaultAmount = fee - devAmount;
        emit FeeCharged(buy, exactInput, gross, fee, devAmount, vaultAmount);

        if (address(poolManager).balance >= fee) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
            _push(devWallet, devAmount);
            _push(researchVault, vaultAmount);
        } else {
            // The manager has not received the buyer's ETH yet: hold an ERC-6909 claim and credit the
            // recipients. `redeemClaims` or `withdraw` converts it once the ETH is in.
            poolManager.mint(address(this), ETH_CLAIM_ID, fee);
            owed[devWallet] += devAmount;
            owed[researchVault] += vaultAmount;
            emit FeeDeferredAsClaim(fee);
            emit PayoutCredited(devWallet, devAmount);
            emit PayoutCredited(researchVault, vaultAmount);
        }
    }

    /// @dev Push `amount` to `to`; on failure credit it instead so the swap never reverts on a recipient.
    function _push(address to, uint256 amount) private {
        if (amount == 0) return;
        if (_send(to, amount)) {
            emit PaidOut(to, amount);
        } else {
            owed[to] += amount;
            emit PayoutCredited(to, amount);
        }
    }

    /// @dev Try to push a recipient's whole credit; keep it credited if the push fails.
    function _flush(address to) private {
        uint256 amount = owed[to];
        if (amount == 0 || address(this).balance < amount) return;
        owed[to] = 0;
        if (_send(to, amount)) {
            emit PaidOut(to, amount);
        } else {
            owed[to] = amount;
        }
    }

    /// @dev Bounded-gas ETH send that ignores return data, so a recipient can neither grief the swap's gas
    /// nor return-bomb the hook.
    function _send(address to, uint256 amount) private returns (bool ok) {
        uint256 gasLimit = PAYOUT_GAS;
        assembly ("memory-safe") {
            ok := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
    }

    /// @dev Burn every ETH claim the hook holds and take the ETH. Needs the manager to be locked.
    function _redeemClaims() private {
        uint256 claims = pendingClaims();
        if (claims == 0) return;
        poolManager.unlock(abi.encode(claims));
        emit ClaimsRedeemed(claims);
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
