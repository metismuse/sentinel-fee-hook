// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @title SentinelFeeHook
/// @notice Uniswap v4 dynamic-fee hook that prices token risk into every swap.
/// @dev Prototype for the Uniswap Hook Incubator (Atrium) grant application.
///      An off-chain keeper pushes a signed 0-100 risk score hourly (EIP-712,
///      nonce-chained). beforeSwap reads the latest score and returns a fee
///      override. If the score is stale (>6h), the hook falls back to an
///      on-chain EWMA-volatility premium instead of reverting.
///
///      KNOWN PROTOTYPE LIMITATIONS (see README):
///      - Single keeper key: compromise lets an attacker rewrite the fee
///        schedule for every pool using this hook. Mitigated (not eliminated)
///        by the immutable keeper address, nonce chaining, and the staleness
///        fallback. Production would use a keeper quorum / multisig.
///      - The risk score's predictive power against realized LP losses is
///        UNVALIDATED. The backtest measures the fee mechanism assuming the
///        score tracks volatility; it does not prove the score predicts losses.
///      - Not yet deployed at a CREATE2-mined address matching the permission
///        bits; production deployment must mine the address per Hooks.sol.
contract SentinelFeeHook is IHooks, EIP712 {
    using LPFeeLibrary for uint24;

    // ---- Fee math constants (units: hundredths of a basis point) ----
    uint24 public constant BASE_FEE = 3000; // 0.30%
    uint24 public constant MAX_FEE = 10_000; // 1.00% hard cap
    uint24 public constant SCORE_SLOPE = 50; // +0.50 bps per score point -> +50 bps at score 100
    uint24 public constant MAX_FALLBACK_PREMIUM = 2500; // 0.25% cap on the stale-feed fallback
    uint256 public constant STALE_AFTER = 6 hours;
    uint256 public constant TIMESTAMP_SKEW = 1 hours;

    bytes32 private constant RISK_REPORT_TYPEHASH =
        keccak256("RiskReport(uint8 score,uint256 nonce,uint256 timestamp)");

    /// @notice The keeper key authorized to push risk scores. Immutable.
    address public immutable keeper;

    /// @notice Latest pushed risk score (0-100).
    uint8 public currentScore;
    /// @notice Block timestamp of the last accepted keeper push.
    uint256 public lastUpdate;
    /// @notice Last accepted nonce. Strictly chained: next push must use lastNonce + 1.
    uint256 public lastNonce;

    /// @notice Packed volatility observation: high 128 bits = EWMA of sqrtPriceX96>>32,
    ///         low 128 bits = last implied sqrtPriceX96>>32. Updated in afterSwap (one SSTORE).
    uint256 public volData;

    error NotDynamicFeePool();
    error ScoreOutOfRange();
    error BadNonce();
    error StaleReport();
    error FutureReport();
    error BadSignature();

    constructor(address _keeper) EIP712("SentinelFeeHook", "1") {
        keeper = _keeper;
    }

    // -------------------------------------------------------------------------
    // Permissions
    // -------------------------------------------------------------------------

    /// @notice Declares the hook permissions this contract implements.
    /// @dev v4-core validates permissions from the hook's deployed address flags;
    ///      production deployment must CREATE2-mine an address whose leading bits
    ///      match these permissions (see Hooks.sol). This helper documents intent
    ///      and is used by the test suite.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // Keeper feed
    // -------------------------------------------------------------------------

    /// @notice Push a signed risk-score report from the keeper.
    /// @param score 0-100 risk score.
    /// @param nonce Must equal lastNonce + 1 (strict chaining, replay protection).
    /// @param timestamp Report timestamp; must be within TIMESTAMP_SKEW of now.
    /// @param signature EIP-712 signature over RiskReport(score, nonce, timestamp) by `keeper`.
    function pushRiskScore(uint8 score, uint256 nonce, uint256 timestamp, bytes calldata signature)
        external
    {
        if (score > 100) revert ScoreOutOfRange();
        if (nonce != lastNonce + 1) revert BadNonce();
        if (timestamp + TIMESTAMP_SKEW < block.timestamp) revert StaleReport();
        if (timestamp > block.timestamp + TIMESTAMP_SKEW) revert FutureReport();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(RISK_REPORT_TYPEHASH, score, nonce, timestamp))
        );
        if (ECDSA.recover(digest, signature) != keeper) revert BadSignature();

        currentScore = score;
        lastNonce = nonce;
        lastUpdate = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Fee computation (public for testability)
    // -------------------------------------------------------------------------

    /// @notice Fee for a fresh keeper score: BASE_FEE + score * SLOPE, hard-capped.
    function feeForScore(uint8 score) public pure returns (uint24) {
        uint256 raw = uint256(BASE_FEE) + uint256(score) * uint256(SCORE_SLOPE);
        return raw > MAX_FEE ? MAX_FEE : uint24(raw);
    }

    /// @notice Staleness fallback premium from the on-chain EWMA volatility proxy.
    /// @dev premium = min(deviationBps * 10, MAX_FALLBACK_PREMIUM), where
    ///      deviationBps = |lastPrice - ewma| * 10000 / ewma. A 1% deviation
    ///      yields a 10 bps premium; >=2.5% deviation hits the 25 bps cap.
    function fallbackPremium() public view returns (uint24) {
        uint256 ewma = volData >> 128;
        uint256 lastPrice = volData & type(uint128).max;
        if (ewma == 0 || lastPrice == 0) return 0;
        uint256 dev = lastPrice > ewma ? lastPrice - ewma : ewma - lastPrice;
        uint256 devBps = (dev * 10_000) / ewma;
        uint256 premium = devBps * 10;
        return premium > MAX_FALLBACK_PREMIUM ? MAX_FALLBACK_PREMIUM : uint24(premium);
    }

    /// @notice True when the keeper feed is too old to trust.
    /// @dev A feed that was never pushed (lastUpdate == 0) is stale by definition.
    function isStale() public view returns (bool) {
        return lastUpdate == 0 || block.timestamp - lastUpdate > STALE_AFTER;
    }

    // -------------------------------------------------------------------------
    // IHooks
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // NOTE: beforeSwap is a state-reading (view) callback, not pure:
        // it reads the stored keeper score. It writes no state.
        uint24 fee;
        if (isStale()) {
            // Keeper silent >6h: never brick the swap, charge base + bounded
            // on-chain volatility premium instead.
            fee = BASE_FEE + fallbackPremium();
            if (fee > MAX_FEE) fee = MAX_FEE;
        } else {
            fee = feeForScore(currentScore);
        }
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        // Derive the swap-implied price from the executed amounts and fold it
        // into the EWMA observation. Single SSTORE (packed slot).
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 != 0 && a1 != 0) {
            uint256 abs0 = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
            uint256 abs1 = a1 < 0 ? uint256(uint128(-a1)) : uint256(uint128(a1));
            // implied sqrtPriceX96-ish observation, scaled to 128 bits
            uint256 obs = (abs1 << 96) / abs0 >> 32;
            uint256 ewma = volData >> 128;
            uint256 newEwma = ewma == 0 ? obs : (ewma * 7 + obs) / 8;
            volData = (newEwma << 128) | (obs & type(uint128).max);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ---- Unused IHooks callbacks: explicitly revert to fail loudly ----

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert("not implemented");
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert("not implemented");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("not implemented");
    }
}
