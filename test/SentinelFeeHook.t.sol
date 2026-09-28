// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SentinelFeeHook} from "../src/SentinelFeeHook.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract SentinelFeeHookTest is Test {
    SentinelFeeHook hook;

    uint256 keeperPk = 0xA11CE;
    address keeper;
    uint256 randoPk = 0xBADCAFE;
    address rando;

    bytes32 constant RISK_REPORT_TYPEHASH =
        keccak256("RiskReport(uint8 score,uint256 nonce,uint256 timestamp)");
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        keeper = vm.addr(keeperPk);
        rando = vm.addr(randoPk);
        hook = new SentinelFeeHook(keeper);
    }

    // ---- helpers ----

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("SentinelFeeHook"),
                keccak256("1"),
                block.chainid,
                address(hook)
            )
        );
    }

    function _signReport(uint256 pk, uint8 score, uint256 nonce, uint256 timestamp)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(RISK_REPORT_TYPEHASH, score, nonce, timestamp));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _push(uint8 score, uint256 nonce) internal {
        bytes memory sig = _signReport(keeperPk, score, nonce, block.timestamp);
        hook.pushRiskScore(score, nonce, block.timestamp, sig);
    }

    function _dummyKey(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _dummySwapParams() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1000,
            sqrtPriceLimitX96: 0
        });
    }

    function _beforeSwapFee() internal view returns (uint24 rawFee, uint24 flaggedFee) {
        (, , flaggedFee) = hook.beforeSwap(
            address(this), _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG), _dummySwapParams(), ""
        );
        rawFee = flaggedFee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    // ---- fee math ----

    function test_feeForScore_endpoints() public view {
        assertEq(hook.feeForScore(0), 3000, "score 0 -> 0.30%");
        assertEq(hook.feeForScore(50), 5500, "score 50 -> 0.55%");
        assertEq(hook.feeForScore(100), 8000, "score 100 -> 0.80%");
    }

    function test_feeForScore_neverExceedsMaxFee() public view {
        for (uint8 s = 0; s <= 100; s++) {
            assertLe(hook.feeForScore(s), hook.MAX_FEE(), "fee exceeds 1.00% cap");
        }
    }

    function test_feeForScore_monotonic() public view {
        uint24 prev = hook.feeForScore(0);
        for (uint8 s = 1; s <= 100; s++) {
            uint24 cur = hook.feeForScore(s);
            assertGe(cur, prev, "fee not monotonic in score");
            prev = cur;
        }
    }

    // ---- permissions ----

    function test_getHookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_beforeInitialize_revertsForStaticFeePool() public {
        vm.expectRevert(SentinelFeeHook.NotDynamicFeePool.selector);
        hook.beforeInitialize(address(this), _dummyKey(3000), 0);
    }

    function test_beforeInitialize_acceptsDynamicFeePool() public {
        bytes4 sel = hook.beforeInitialize(
            address(this), _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG), 0
        );
        assertEq(sel, IHooks.beforeInitialize.selector);
    }

    // ---- keeper feed ----

    function test_pushRiskScore_happyPath() public {
        _push(42, 1);
        assertEq(hook.currentScore(), 42);
        assertEq(hook.lastNonce(), 1);
        assertEq(hook.lastUpdate(), block.timestamp);
    }

    function test_pushRiskScore_rejectsReplay() public {
        _push(42, 1);
        bytes memory sig = _signReport(keeperPk, 42, 1, block.timestamp);
        vm.expectRevert(SentinelFeeHook.BadNonce.selector);
        hook.pushRiskScore(42, 1, block.timestamp, sig);
    }

    function test_pushRiskScore_rejectsSkippedNonce() public {
        bytes memory sig = _signReport(keeperPk, 42, 5, block.timestamp);
        vm.expectRevert(SentinelFeeHook.BadNonce.selector);
        hook.pushRiskScore(42, 5, block.timestamp, sig);
    }

    function test_pushRiskScore_rejectsWrongSigner() public {
        bytes memory sig = _signReport(randoPk, 42, 1, block.timestamp);
        vm.expectRevert(SentinelFeeHook.BadSignature.selector);
        hook.pushRiskScore(42, 1, block.timestamp, sig);
    }

    function test_pushRiskScore_rejectsScoreAbove100() public {
        bytes memory sig = _signReport(keeperPk, 101, 1, block.timestamp);
        vm.expectRevert(SentinelFeeHook.ScoreOutOfRange.selector);
        hook.pushRiskScore(101, 1, block.timestamp, sig);
    }

    function test_pushRiskScore_rejectsAncientTimestamp() public {
        vm.warp(10_000_000); // realistic timestamp so `now - 2h` cannot underflow
        uint256 old = block.timestamp - 2 hours;
        bytes memory sig = _signReport(keeperPk, 42, 1, old);
        vm.expectRevert(SentinelFeeHook.StaleReport.selector);
        hook.pushRiskScore(42, 1, old, sig);
    }

    function test_pushRiskScore_sequentialNonces() public {
        _push(10, 1);
        _push(90, 2);
        assertEq(hook.currentScore(), 90);
        assertEq(hook.lastNonce(), 2);
    }

    // ---- beforeSwap behavior ----

    function test_beforeSwap_freshScoreSetsOverrideFee() public {
        _push(100, 1);
        (uint24 rawFee, uint24 flaggedFee) = _beforeSwapFee();
        assertEq(rawFee, 8000, "fresh score 100 -> 0.80%");
        assertTrue(flaggedFee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag missing");
    }

    function test_beforeSwap_freshScoreZeroChargesBaseOnly() public {
        _push(0, 1);
        (uint24 rawFee,) = _beforeSwapFee();
        assertEq(rawFee, 3000, "fresh score 0 -> base fee only");
    }

    function test_beforeSwap_staleFeedFallsBackToBasePlusVolPremium() public {
        _push(100, 1);
        // No swaps observed yet -> vol premium is 0, fee must drop to base fee.
        vm.warp(block.timestamp + 7 hours);
        assertTrue(hook.isStale(), "feed should be stale after 7h");
        (uint24 rawFee, uint24 flaggedFee) = _beforeSwapFee();
        assertEq(rawFee, 3000, "stale feed with no observations -> base fee");
        assertTrue(flaggedFee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag missing");
    }

    function test_beforeSwap_neverRevertsWhenStale() public {
        // Never pushed at all: lastUpdate = 0 -> stale from genesis.
        assertTrue(hook.isStale());
        (uint24 rawFee,) = _beforeSwapFee(); // must not revert
        assertEq(rawFee, 3000);
    }

    function test_fallbackPremium_zeroWithoutObservations() public view {
        assertEq(hook.fallbackPremium(), 0);
    }

    function test_fallbackPremium_spikesOnVolatilityAndCaps() public {
        // Build an EWMA observation history via afterSwap, then shock the price.
        hook.afterSwap(
            address(this),
            _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            _dummySwapParams(),
            toBalanceDelta(int128(-1000), int128(2000)),
            ""
        );
        hook.afterSwap(
            address(this),
            _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            _dummySwapParams(),
            toBalanceDelta(int128(-1000), int128(4000)), // 2x price shock
            ""
        );
        uint24 premium = hook.fallbackPremium();
        assertGt(premium, 0, "volatility should produce a premium");
        assertLe(premium, hook.MAX_FALLBACK_PREMIUM(), "premium must respect the 0.25% cap");
    }

    function test_fallbackPremium_smallMoveSmallPremium() public {
        hook.afterSwap(
            address(this),
            _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            _dummySwapParams(),
            toBalanceDelta(int128(-1000), int128(2000)),
            ""
        );
        hook.afterSwap(
            address(this),
            _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            _dummySwapParams(),
            toBalanceDelta(int128(-1000), int128(2010)), // 0.5% move
            ""
        );
        uint24 premium = hook.fallbackPremium();
        assertLt(premium, hook.MAX_FALLBACK_PREMIUM(), "small move should not hit the cap");
    }

    function test_staleWithVolatility_chargesCappedPremium() public {
        _push(100, 1);
        hook.afterSwap(
            address(this),
            _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            _dummySwapParams(),
            toBalanceDelta(int128(-1000), int128(2000)),
            ""
        );
        hook.afterSwap(
            address(this),
            _dummyKey(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            _dummySwapParams(),
            toBalanceDelta(int128(-1000), int128(4000)),
            ""
        );
        vm.warp(block.timestamp + 7 hours);
        (uint24 rawFee,) = _beforeSwapFee();
        assertGt(rawFee, 3000, "stale + volatile -> premium above base");
        assertLe(rawFee, 3000 + hook.MAX_FALLBACK_PREMIUM(), "premium capped at 0.25%");
        assertLe(rawFee, hook.MAX_FEE(), "never exceeds hard cap");
    }
}
