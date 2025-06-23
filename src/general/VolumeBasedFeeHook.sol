pragma solidity ^0.8.24;

import {BaseHook} from "../base/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
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
 * - feeAtMaxAmount <= feeAtMinAmount
 * - minAmount < maxAmount
 *
 * NOTE: The fee calculation is symmetric for both swap directions and both exact input/output swaps.
 */
contract VolumeBasedFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CustomRevert for bytes4;

    /// @dev Struct of parameters for the hook
    struct SwapVolumeParams {
        uint24 defaultFee;
        uint24 feeAtMinAmount0;
        uint24 feeAtMaxAmount0;
        uint24 feeAtMinAmount1;
        uint24 feeAtMaxAmount1;
        uint256 minAmount0;
        uint256 maxAmount0;
        uint256 minAmount1;
        uint256 maxAmount1;
    }

    /**
     * @dev Thrown when fee relationships are invalid:
     * - feeAtMinAmount is greater than defaultFee
     * - feeAtMaxAmount is greater than feeAtMinAmount
     */
    error InvalidFees();

    /**
     * @dev Thrown when amount thresholds are invalid:
     * - minAmount is greater than or equal to maxAmount
     */
    error InvalidAmountThresholds();

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

    /// @dev Difference between feeAtMinAmount and feeAtMaxAmount for currency0
    uint24 immutable feeAtThresholdsDelta0;

    /// @dev Difference between feeAtMinAmount and feeAtMaxAmount for currency1
    uint24 immutable feeAtThresholdsDelta1;

    /// @dev Minimum amount threshold for currency0
    uint256 immutable minAmount0;

    /// @dev Maximum amount threshold for currency0
    uint256 immutable maxAmount0;

    /// @dev Minimum amount threshold for currency1
    uint256 immutable minAmount1;

    /// @dev Maximum amount threshold for currency1
    uint256 immutable maxAmount1;

    /// @dev Difference between minAmount and maxAmount for currency0
    uint256 immutable amountThresholdsDelta0;

    /// @dev Difference between minAmount and maxAmount for currency1
    uint256 immutable amountThresholdsDelta1;

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

        if (params.feeAtMaxAmount0 > params.feeAtMinAmount0)
            InvalidFees.selector.revertWith();

        if (params.feeAtMinAmount1 > params.defaultFee)
            InvalidFees.selector.revertWith();

        if (params.feeAtMaxAmount1 > params.feeAtMinAmount1)
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

        /**
         * Difference between fee at min amount and fee at max amount for currency0
         * Used for linear interpolation
         */
        feeAtThresholdsDelta0 = params.feeAtMinAmount0 - params.feeAtMaxAmount0;
        feeAtThresholdsDelta1 = params.feeAtMinAmount1 - params.feeAtMaxAmount1;

        minAmount0 = params.minAmount0;
        maxAmount0 = params.maxAmount0;
        minAmount1 = params.minAmount1;
        maxAmount1 = params.maxAmount1;

        /**
         * Difference between min amount and max amount for currency0
         * Used for linear interpolation
         */
        amountThresholdsDelta0 = params.maxAmount0 - params.minAmount0;
        amountThresholdsDelta1 = params.maxAmount1 - params.minAmount1;
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
        /// Swapping currency0 for currency1
        if (swapParams.zeroForOne) {
            /**
             * If amountSpecified is negative, it's an exact input swap
             * Therefore, the known volume is the amount of currency0 being swapped
             */
            if (swapParams.amountSpecified < 0) {
                calculatedFee = _calculateFeePerScenario(
                    uint256(-swapParams.amountSpecified),
                    minAmount0,
                    maxAmount0,
                    feeAtMaxAmount0,
                    feeAtMinAmount0,
                    feeAtThresholdsDelta0,
                    amountThresholdsDelta0
                );
            } else {
                /**
                 * If amountSpecified is positive, it's an exact output swap
                 * Therefore, the known volume is the amount of currency1 being swapped
                 */
                calculatedFee = _calculateFeePerScenario(
                    uint256(swapParams.amountSpecified),
                    minAmount1,
                    maxAmount1,
                    feeAtMaxAmount1,
                    feeAtMinAmount1,
                    feeAtThresholdsDelta1,
                    amountThresholdsDelta1
                );
            }
        /// Swapping currency1 for currency0
        } else {
            /**
             * If amountSpecified is negative, it's an exact input swap
             * Therefore, the known volume is the amount of currency1 being swapped
             */
            if (swapParams.amountSpecified < 0) {
                calculatedFee = _calculateFeePerScenario(
                    uint256(-swapParams.amountSpecified),
                    minAmount1,
                    maxAmount1,
                    feeAtMaxAmount1,
                    feeAtMinAmount1,
                    feeAtThresholdsDelta1,
                    amountThresholdsDelta1
                );
            } else {
                /**
                 * If amountSpecified is positive, it's an exact output swap
                 * Therefore, the known volume is the amount of currency0 being swapped
                 */
                calculatedFee = _calculateFeePerScenario(
                    uint256(swapParams.amountSpecified),
                    minAmount0,
                    maxAmount0,
                    feeAtMaxAmount0,
                    feeAtMinAmount0,
                    feeAtThresholdsDelta0,
                    amountThresholdsDelta0
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
        uint24 feeAtMinAmount,
        uint24 feeAtThresholdsDelta,
        uint256 amountThresholdsDelta
    ) internal view virtual returns (uint24) {
        /**
         * Explicitly check if volume is equal to minAmount
         * To allow benefitting of fee reduction
         * Saving gas on skipping the linear interpolation
         */
        if (volume == minAmount) {
            return feeAtMinAmount;
        }

        if (volume >= maxAmount) {
            return feeAtMaxAmount;
        }

        if (volume < minAmount) {
            return defaultFee;
        }

        /**
         * Volume is between minAmount and maxAmount
         * Calculate the fee using linear interpolation
         */
        return
            feeAtMinAmount -
            uint24(
                (feeAtThresholdsDelta * (volume - minAmount)) /
                    amountThresholdsDelta
            );
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
