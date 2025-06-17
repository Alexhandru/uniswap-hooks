pragma solidity ^0.8.24;

import {BaseHook} from "../base/BaseHook.sol";
import {IVolumeBasedFeeHook} from "../interfaces/IVolumeBasedFeeHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * @dev Volume-based dynamic fee hook that adjusts swap fees based on transaction volume.
 * The hook implements a tiered fee structure where fees decrease as transaction volume increases.
 *
 * The fee calculation works differently for each token (currency0 and currency1):
 * - Below minAmount: Uses defaultFee
 * - Between minAmount and maxAmount: Linear interpolation between feeAtMinAmount and feeAtMaxAmount
 * - Above maxAmount: Uses feeAtMaxAmount
 *
 * Fee relationships must maintain:
 * - feeAtMinAmount <= defaultFee
 * - feeAtMaxAmount < feeAtMinAmount
 * - minAmount < maxAmount
 *
 * NOTE: The fee calculation is symmetric for both swap directions and both exact input/output swaps.
 */
contract VolumeBasedFeeHook is IVolumeBasedFeeHook, BaseHook {
    using PoolIdLibrary for PoolKey;
    using CustomRevert for bytes4;

    /// @dev The default fee applied when swap amount is below minAmount
    uint24 immutable defaultFee;
    /// @dev Fee applied at minAmount0 threshold for currency0
    uint24 immutable feeAtMinAmount0;
    /// @dev Fee applied at maxAmount0 threshold for currency0
    uint24 immutable feeAtMaxAmount0;
    /// @dev Fee applied at minAmount1 threshold for currency1
    uint24 immutable feeAtMinAmount1;
    /// @dev Fee applied at maxAmount1 threshold for currency1
    uint24 immutable feeAtMaxAmount1;
    /// @dev Minimum amount threshold for currency0
    uint256 immutable minAmount0;
    /// @dev Maximum amount threshold for currency0
    uint256 immutable maxAmount0;
    /// @dev Minimum amount threshold for currency1
    uint256 immutable minAmount1;
    /// @dev Maximum amount threshold for currency1
    uint256 immutable maxAmount1;

    /**
     * @dev Constructor that validates and sets the fee parameters.
     * Reverts if:
     * - Any fee at min amount is higher than the default fee
     * - Any fee at max amount is higher than or equal to its corresponding fee at min fee
     * - Any min amount is greater than or equal to its max amount
     */
    constructor(
        IPoolManager _poolManager,
        SwapVolumeParams memory params
    ) BaseHook(_poolManager) {
        if (params.feeAtMinAmount0 > params.defaultFee)
            InvalidFees.selector.revertWith();
        if (params.feeAtMaxAmount0 >= params.feeAtMinAmount0)
            InvalidFees.selector.revertWith();
        if (params.feeAtMinAmount1 > params.defaultFee)
            InvalidFees.selector.revertWith();
        if (params.feeAtMaxAmount1 >= params.feeAtMinAmount1)
            InvalidFees.selector.revertWith();
        if (params.minAmount0 >= params.maxAmount0)
            InvalidAmountThresholds.selector.revertWith();
        if (params.minAmount1 >= params.maxAmount1)
            InvalidAmountThresholds.selector.revertWith();

        defaultFee = params.defaultFee;
        feeAtMinAmount0 = params.feeAtMinAmount0;
        feeAtMaxAmount0 = params.feeAtMaxAmount0;
        feeAtMinAmount1 = params.feeAtMinAmount1;
        feeAtMaxAmount1 = params.feeAtMaxAmount1;
        minAmount0 = params.minAmount0;
        maxAmount0 = params.maxAmount0;
        minAmount1 = params.minAmount1;
        maxAmount1 = params.maxAmount1;
    }


    /**
     * @dev Handles the beforeSwap hook by calculating and updating the dynamic LP fee based on
     * the swap amount.
     * @return The hook selector, zero delta (no hooks modifying swap amounts), and zero fee
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        poolManager.updateDynamicLPFee(key, _calculateFee(swapParams));
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /**
     * @dev Calculates the appropriate fee based on swap parameters and direction.
     * Handles both exact input and exact output swaps in both directions.
     * @param swapParams The parameters of the swap including amount and direction
     * @return calculatedFee The calculated fee as a uint24
     */
    function _calculateFee(
        SwapParams calldata swapParams
    ) internal view virtual returns (uint24 calculatedFee) {
        if (swapParams.zeroForOne) {
            if (swapParams.amountSpecified < 0) {
                calculatedFee = _calculateFeePerScenario(
                    uint256(-swapParams.amountSpecified),
                    minAmount0,
                    maxAmount0,
                    feeAtMaxAmount0,
                    feeAtMinAmount0
                );
            } else {
                calculatedFee = _calculateFeePerScenario(
                    uint256(swapParams.amountSpecified),
                    minAmount1,
                    maxAmount1,
                    feeAtMaxAmount1,
                    feeAtMinAmount1
                );
            }
        } else {
            if (swapParams.amountSpecified < 0) {
                calculatedFee = _calculateFeePerScenario(
                    uint256(-swapParams.amountSpecified),
                    minAmount1,
                    maxAmount1,
                    feeAtMaxAmount1,
                    feeAtMinAmount1
                );
            } else {
                calculatedFee = _calculateFeePerScenario(
                    uint256(swapParams.amountSpecified),
                    minAmount0,
                    maxAmount0,
                    feeAtMaxAmount0,
                    feeAtMinAmount0
                );
            }
        }
    }

    /**
     * @dev Calculates the fee for a specific volume based on the defined thresholds.
     * Implements linear interpolation between min and max amounts.
     * @param volume The transaction volume to calculate fee for
     * @param minAmount The minimum amount threshold
     * @param maxAmount The maximum amount threshold
     * @param feeAtMaxAmount The fee at maximum amount
     * @param feeAtMinAmount The fee at minimum amount
     * @return calculatedFee The calculated fee as a uint24
     */
    function _calculateFeePerScenario(
        uint256 volume,
        uint256 minAmount,
        uint256 maxAmount,
        uint24 feeAtMaxAmount,
        uint24 feeAtMinAmount
    ) internal view virtual returns (uint24) {
        if (volume == minAmount) {
            return feeAtMinAmount;
        }

        if (volume >= maxAmount) {
            return feeAtMaxAmount;
        }

        if (volume < minAmount) {
            return defaultFee;
        }

        uint256 deltaFee = feeAtMinAmount - feeAtMaxAmount;
        uint256 feeDifference = (deltaFee * (volume - minAmount)) /
            (maxAmount - minAmount);
        return feeAtMinAmount - uint24(feeDifference);
    }

    /**
     * @dev Returns the current fee parameters of the hook.
     * @return SwapVolumeParams struct containing all fee and amount threshold parameters
     */
    function getSwapVolumeParams()
        external
        view
        virtual
        returns (SwapVolumeParams memory)
    {
        return
            SwapVolumeParams({
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
    }

    /**
     * @dev Sets the hook permissions. Only requires beforeSwap permission to update dynamic fees.
     * @return permissions The hook permissions
     */
    function getHookPermissions()
        public
        pure
        virtual
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }
}
