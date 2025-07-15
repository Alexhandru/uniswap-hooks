// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {VolumeBasedFeeHook} from "../../src/general/VolumeBasedFeeHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IPoolManagerEvents} from "../utils/IPoolManagerEvents.sol";

contract VolumeBasedFeeHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint16;

    VolumeBasedFeeHook hook;
    VolumeBasedFeeHook newHook;

    uint24 defaultFee = 3000;
    uint24 feeAtMinAmount0 = 2700;
    uint24 feeAtMaxAmount0 = 2400;
    uint24 feeAtMinAmount1 = 2100;
    uint24 feeAtMaxAmount1 = 2000;
    uint256 minAmount0 = 1e18;
    uint256 maxAmount0 = 10e18;
    uint256 minAmount1 = 1e18;
    uint256 maxAmount1 = 10e18;

    uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144); // Namespace the hook to avoid collisions

    VolumeBasedFeeHook.SwapVolumeParams swapVolumeParams =
        VolumeBasedFeeHook.SwapVolumeParams({
            defaultFee: defaultFee,
            feeAtMinAmount0: feeAtMinAmount0,
            feeAtMaxAmount0: feeAtMaxAmount0,
            feeAtMinAmount1: feeAtMinAmount1,
            feeAtMaxAmount1: feeAtMaxAmount1,
            minAmount0: minAmount0,
            maxAmount0: maxAmount0,
            minAmount1: minAmount1,
            maxAmount1: maxAmount1
        });

    int256 amountSpecifiedFuzz;
    uint8 zeroForOneFuzz;

    function setUp() public {
        deployFreshManagerAndRouters();

        hook = VolumeBasedFeeHook(address(flags));

        newHook = VolumeBasedFeeHook(
            address(uint160(Hooks.BEFORE_SWAP_FLAG) + 2 ** 96)
        );

        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(hook)
        );

        deployMintAndApprove2Currencies();
        (key, ) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );
    }

    function test_revert_invalidFeeAtMinAmount0() public {
        uint24 invalidFeeAtMinAmount0 = defaultFee + 1; // Fee higher than defaultFee

        swapVolumeParams.feeAtMinAmount0 = invalidFeeAtMinAmount0;

        vm.expectRevert(VolumeBasedFeeHook.InvalidFees.selector);
        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(newHook)
        );
    }

    function test_revert_invalidFeeAtMaxAmount0() public {
        uint24 invalidFeeAtMaxAmount0 = feeAtMinAmount0 + 1; // Fee higher than feeAtMinAmount0

        swapVolumeParams.feeAtMaxAmount0 = invalidFeeAtMaxAmount0;

        vm.expectRevert(VolumeBasedFeeHook.InvalidFees.selector);
        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(newHook)
        );
    }

    function test_revert_invalidFeeAtMinAmount1() public {
        uint24 invalidFeeAtMinAmount1 = defaultFee + 1; // Fee higher than defaultFee

        swapVolumeParams.feeAtMinAmount1 = invalidFeeAtMinAmount1;

        vm.expectRevert(VolumeBasedFeeHook.InvalidFees.selector);
        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(newHook)
        );
    }

    function test_revert_invalidFeeAtMaxAmount1() public {
        uint24 invalidFeeAtMaxAmount1 = feeAtMinAmount1 + 1; // Fee higher than feeAtMinAmount1

        swapVolumeParams.feeAtMaxAmount1 = invalidFeeAtMaxAmount1;

        vm.expectRevert(VolumeBasedFeeHook.InvalidFees.selector);
        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(newHook)
        );
    }

    function test_revert_invalidAmountThresholds_minAmount0() public {
        uint256 invalidMinAmount0 = maxAmount0 + 1; // minAmount0 greater than maxAmount0

        swapVolumeParams.minAmount0 = invalidMinAmount0;

        vm.expectRevert(VolumeBasedFeeHook.InvalidAmountThresholds.selector);
        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(newHook)
        );
    }

    function test_revert_invalidAmountThresholds_minAmount1() public {
        uint256 invalidMinAmount1 = maxAmount1 + 1; // minAmount1 greater than maxAmount1

        swapVolumeParams.minAmount1 = invalidMinAmount1;

        vm.expectRevert(VolumeBasedFeeHook.InvalidAmountThresholds.selector);
        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, swapVolumeParams),
            address(newHook)
        );
    }

    function test_swap_updateDynamicFee_defaultFee() public {
        bool zeroForOne = true;
        int256 amountSpecified = -1e18 + 1; // Swap amount that doesn't hit min or max thresholds

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, // amount0 (not checked)
            0, // amount1 (not checked)
            0, // sqrtPriceX96 (not checked)
            0, // liquidity (not checked)
            0, // tick (not checked)
            defaultFee
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_updateDynamicFee_mintAmount0_feeAtMinAmount0() public {
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            feeAtMinAmount0
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_updateDynamicFee_mintAmount0_feeAtMaxAmount0() public {
        bool zeroForOne = true;
        int256 amountSpecified = -10e18; // Exact input swap hitting max threshold

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            feeAtMaxAmount0
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_updateDynamicFee_mintAmount1_feeAtMinAmount1() public {
        bool zeroForOne = false;
        int256 amountSpecified = -1e18; // Exact input swap hitting min threshold for token1

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            feeAtMinAmount1
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_updateDynamicFee_mintAmount1_feeAtMaxAmount1() public {
        bool zeroForOne = false;
        int256 amountSpecified = -10e18; // Exact input swap hitting max threshold for token1

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            feeAtMaxAmount1
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_middleVolume_exactInput_zeroForOne() public {
        bool zeroForOne = true;
        int256 amountSpecified = -int256((minAmount0 + maxAmount0) / 2); // Dynamically calculate middle value
        uint24 expectedFee = uint24(
            feeAtMinAmount0 -
                ((feeAtMinAmount0 - feeAtMaxAmount0) *
                    ((minAmount0 + maxAmount0) / 2 - minAmount0)) /
                (maxAmount0 - minAmount0)
        );

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            expectedFee
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_middleVolume_exactOutput_zeroForOne() public {
        bool zeroForOne = true;
        int256 amountSpecified = int256((minAmount1 + maxAmount1) / 2); // Dynamically calculate middle value
        uint24 expectedFee = uint24(
            feeAtMinAmount1 -
                ((feeAtMinAmount1 - feeAtMaxAmount1) *
                    ((minAmount1 + maxAmount1) / 2 - minAmount1)) /
                (maxAmount1 - minAmount1)
        );

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            expectedFee
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_middleVolume_exactInput_notZeroForOne() public {
        bool zeroForOne = false;
        int256 amountSpecified = -int256((minAmount1 + maxAmount1) / 2); // Dynamically calculate middle value
        uint24 expectedFee = uint24(
            feeAtMinAmount1 -
                ((feeAtMinAmount1 - feeAtMaxAmount1) *
                    ((minAmount1 + maxAmount1) / 2 - minAmount1)) /
                (maxAmount1 - minAmount1)
        );

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            expectedFee
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_swap_middleVolume_exactOutput_notZeroForOne() public {
        bool zeroForOne = false;
        int256 amountSpecified = int256((minAmount0 + maxAmount0) / 2); // Dynamically calculate middle value
        uint24 expectedFee = uint24(
            feeAtMinAmount0 -
                ((feeAtMinAmount0 - feeAtMaxAmount0) *
                    ((minAmount0 + maxAmount0) / 2 - minAmount0)) /
                (maxAmount0 - minAmount0)
        );

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            expectedFee
        );

        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    /*
     * Having equal values for both fee at min/max amount
     * Allows having a single reduced fee for volumes
     * Bigger than or equal to "minAmount"
     */ 
    function test_swap_sameMinMaxFees() public {
        // Set up new params where min and max fees are the same
        VolumeBasedFeeHook.SwapVolumeParams
            memory sameFeesParams = VolumeBasedFeeHook.SwapVolumeParams({
                defaultFee: 3000,
                feeAtMinAmount0: 2000, // Same fee for min and max amount0
                feeAtMaxAmount0: 2000,
                feeAtMinAmount1: 1500, // Same fee for min and max amount1
                feeAtMaxAmount1: 1500,
                minAmount0: 1e18,
                maxAmount0: 10e18,
                minAmount1: 1e18,
                maxAmount1: 10e18
            });

        deployCodeTo(
            "VolumeBasedFeeHook.sol:VolumeBasedFeeHook",
            abi.encode(manager, sameFeesParams),
            address(newHook)
        );

        // Initialize new pool with the hook
        (PoolKey memory newKey, ) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            IHooks(address(newHook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Test swap for token0
        bool zeroForOne = true;
        int256 amountSpecified = -5e18; // Amount between min and max

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            newKey.toId(),
            address(this),
            0, 0, 0, 0, 0,
            2000
        );

        swap(newKey, zeroForOne, amountSpecified, ZERO_BYTES);

        // Test swap for token1
        zeroForOne = false;
        amountSpecified = -5e18; // Amount between min and max
        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            newKey.toId(),
            address(this),
            0, 0, 0, 0, 0,
            1500
        );
        swap(newKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_fuzz_swapParams(
        uint24 _defaultFee,
        uint24 _feeAtMinAmount0,
        uint24 _feeAtMaxAmount0,
        uint24 _feeAtMinAmount1,
        uint24 _feeAtMaxAmount1,
        uint256 _minAmount0,
        uint256 _maxAmount0,
        uint256 _minAmount1,
        uint256 _maxAmount1,
        int256 _amountSpecified,
        uint8 _zeroForOne
    ) public {
        _setupFuzzedParams(
            _defaultFee,
            _feeAtMinAmount0,
            _feeAtMaxAmount0,
            _feeAtMinAmount1,
            _feeAtMaxAmount1,
            _minAmount0,
            _maxAmount0,
            _minAmount1,
            _maxAmount1,
            _amountSpecified,
            _zeroForOne
        );
        _setupAmountSpecified(_amountSpecified);

        VolumeBasedFeeHook.SwapVolumeParams memory params = VolumeBasedFeeHook
            .SwapVolumeParams({
                defaultFee: defaultFee,
                feeAtMinAmount0: feeAtMinAmount0,
                feeAtMaxAmount0: feeAtMaxAmount0,
                feeAtMinAmount1: feeAtMinAmount1,
                feeAtMaxAmount1: feeAtMaxAmount1,
                minAmount0: minAmount0,
                maxAmount0: maxAmount0,
                minAmount1: minAmount1,
                maxAmount1: maxAmount1
            });

        VolumeBasedFeeHookHarness swapVolume = VolumeBasedFeeHookHarness(
            address(uint160(Hooks.BEFORE_SWAP_FLAG) + 2 ** 96)
        );

        deployCodeTo(
            "VolumeBasedFeeHook.t.sol:VolumeBasedFeeHookHarness",
            abi.encode(manager, params),
            address(swapVolume)
        );

        (key, ) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            IHooks(address(swapVolume)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        _validateParams(swapVolume.getSwapVolumeParams());

        uint24 expectedFee = swapVolume.exposed_calculateFee(
            SwapParams({
                zeroForOne: zeroForOneFuzz == 1,
                amountSpecified: amountSpecifiedFuzz,
                sqrtPriceLimitX96: zeroForOneFuzz == 1
                    ? MIN_PRICE_LIMIT
                    : MAX_PRICE_LIMIT
            })
        );

        vm.expectEmit(false, false, false, false, address(manager));
        emit IPoolManagerEvents.Swap(
            key.toId(),
            address(this),
            0, 0, 0, 0, 0,
            expectedFee
        );

        swap(key, zeroForOneFuzz == 1, amountSpecifiedFuzz, ZERO_BYTES);
    }

    function _setupFuzzedParams(
        uint24 _defaultFee,
        uint24 _feeAtMinAmount0,
        uint24 _feeAtMaxAmount0,
        uint24 _feeAtMinAmount1,
        uint24 _feeAtMaxAmount1,
        uint256 _minAmount0,
        uint256 _maxAmount0,
        uint256 _minAmount1,
        uint256 _maxAmount1,
        int256 _amountSpecified,
        uint8 _zeroForOne
    ) private {
        defaultFee = uint24(bound(_defaultFee, 0, 1000000));
        feeAtMinAmount0 = uint24(bound(_feeAtMinAmount0, 0, defaultFee));
        feeAtMaxAmount0 = uint24(bound(_feeAtMaxAmount0, 0, feeAtMinAmount0));
        feeAtMinAmount1 = uint24(bound(_feeAtMinAmount1, 0, defaultFee));
        feeAtMaxAmount1 = uint24(bound(_feeAtMaxAmount1, 0, feeAtMinAmount1));
        minAmount0 = bound(_minAmount0, 1, uint256(type(uint128).max) - 1);
        maxAmount0 = bound(
            _maxAmount0,
            minAmount0 + 1,
            uint256(type(uint128).max)
        );
        minAmount1 = bound(_minAmount1, 1, uint256(type(uint128).max) - 1);
        maxAmount1 = bound(
            _maxAmount1,
            minAmount1 + 1,
            uint256(type(uint128).max)
        );
        zeroForOneFuzz = _zeroForOne % 2;
        amountSpecifiedFuzz = _amountSpecified;
    }

    function _setupAmountSpecified(int256 _amountSpecified) private {
        vm.assume(
            _amountSpecified != 0 && _amountSpecified != type(int256).min
        );

        bool exactInput = _amountSpecified < 0;
        int256 absAmountSpecified = exactInput
            ? -_amountSpecified
            : _amountSpecified;

        uint256 minAmount = zeroForOneFuzz == 1
            ? (exactInput ? minAmount0 : minAmount1)
            : (exactInput ? minAmount1 : minAmount0);

        uint256 maxAmount = zeroForOneFuzz == 1
            ? (exactInput ? maxAmount0 : maxAmount1)
            : (exactInput ? maxAmount1 : maxAmount0);

        uint256 boundedAmount;
        // The goal is to test swaps with amounts that are lower than, between, and higher than the min/max thresholds.
        // We use modulo to distribute the fuzzed amounts across these three scenarios.
        uint256 scenario = uint256(absAmountSpecified) % 3;

        if (scenario == 0) {
            // Scenario 1: Swap amount is less than the minimum threshold. Fee should be defaultFee.
            boundedAmount = bound(
                uint256(absAmountSpecified),
                1,
                minAmount > 1 ? minAmount - 1 : 1
            );
        } else if (scenario == 1) {
            // Scenario 2: Swap amount is between the minimum and maximum thresholds. Fee should be interpolated.
            boundedAmount = bound(
                uint256(absAmountSpecified),
                minAmount,
                maxAmount
            );
        } else {
            // scenario == 2
            // Scenario 3: Swap amount is greater than the maximum threshold. Fee should be feeAtMaxAmount.
            boundedAmount = bound(
                uint256(absAmountSpecified),
                maxAmount,
                uint256(type(uint128).max)
            );
        }

        amountSpecifiedFuzz = exactInput
            ? -int256(boundedAmount)
            : int256(boundedAmount);
    }

    function _validateParams(
        VolumeBasedFeeHook.SwapVolumeParams memory paramsOut
    ) private view {
        assertEq(paramsOut.defaultFee, defaultFee, "defaultFee mismatch");
        assertEq(
            paramsOut.feeAtMinAmount0,
            feeAtMinAmount0,
            "feeAtMinAmount0 mismatch"
        );
        assertEq(
            paramsOut.feeAtMaxAmount0,
            feeAtMaxAmount0,
            "feeAtMaxAmount0 mismatch"
        );
        assertEq(
            paramsOut.feeAtMinAmount1,
            feeAtMinAmount1,
            "feeAtMinAmount1 mismatch"
        );
        assertEq(
            paramsOut.feeAtMaxAmount1,
            feeAtMaxAmount1,
            "feeAtMaxAmount1 mismatch"
        );
        assertEq(paramsOut.minAmount0, minAmount0, "minAmount0 mismatch");
        assertEq(paramsOut.maxAmount0, maxAmount0, "maxAmount0 mismatch");
        assertEq(paramsOut.minAmount1, minAmount1, "minAmount1 mismatch");
        assertEq(paramsOut.maxAmount1, maxAmount1, "maxAmount1 mismatch");
    }

    function _fetchPoolLPFee(
        PoolKey memory _key
    ) internal view returns (uint256 lpFee) {
        PoolId id = _key.toId();
        (, , , lpFee) = manager.getSlot0(id);
    }
}

contract VolumeBasedFeeHookHarness is VolumeBasedFeeHook {
    constructor(
        IPoolManager _poolManager,
        SwapVolumeParams memory params
    ) VolumeBasedFeeHook(_poolManager, params) {}

    function exposed_calculateFee(
        SwapParams calldata swapParams
    ) external view returns (uint24) {
        return _calculateFee(swapParams);
    }
}
