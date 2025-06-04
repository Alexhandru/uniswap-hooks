// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVolumeBasedFeeHook
 * @dev Interface for the VolumeBasedFeeHook that implements dynamic fees based on swap volume.
 */
interface IVolumeBasedFeeHook {
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

    /**
     * @dev Parameters for initializing the VolumeBasedFeeHook
     * @param defaultFee The fee applied when swap amount is below minAmount
     * @param feeAtMinAmount0 Fee applied when token0 swap amount equals minAmount0
     * @param feeAtMaxAmount0 Fee applied when token0 swap amount equals or exceeds maxAmount0
     * @param feeAtMinAmount1 Fee applied when token1 swap amount equals minAmount1
     * @param feeAtMaxAmount1 Fee applied when token1 swap amount equals or exceeds maxAmount1
     * @param minAmount0 Minimum amount threshold for token0
     * @param maxAmount0 Maximum amount threshold for token0
     * @param minAmount1 Minimum amount threshold for token1
     * @param maxAmount1 Maximum amount threshold for token1
     */
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

    function getSwapVolumeParams() external view returns (SwapVolumeParams memory);
}