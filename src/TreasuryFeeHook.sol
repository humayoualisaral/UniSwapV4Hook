// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title  TreasuryFeeHook
 * @notice Immutable hook that charges a strict 99% fee ONLY on SELL swaps.
 *         No admin, no ownership, fully hardcoded logic.
 */
contract TreasuryFeeHook is BaseHook {
    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    // --- Hardcoded Config ------------------------------------------------------
    address public constant TREASURY = 0x3a22a82aE40e0a269D1B5B2BD322b8762E438ccB;
    uint256 public constant FEE_BPS = 9900; // 99% fee hardcoded
    uint256 private constant BPS_DENOM = 10_000;

    /// @notice Tokens treated as "base" - receiving them = user SOLD their token.
    mapping(address => bool) public isBaseCurrency;

    // --- Events ----------------------------------------------------------------
    event FeeSentToTreasury(
        PoolId  indexed poolId,
        address indexed outputToken,
        uint256         feeAmount
    );

    // --- Constructor -----------------------------------------------------------
    constructor(
        IPoolManager _poolManager,
        address[]    memory _baseCurrencies
    ) BaseHook(_poolManager) {
        // Set base currencies once during deployment
        for (uint256 i; i < _baseCurrencies.length; ++i) {
            isBaseCurrency[_baseCurrencies[i]] = true;
        }
    }

    // --- Hook permissions ------------------------------------------------------
    function getHookPermissions()
        public pure override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 false,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               false,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            false,
            beforeSwap:                      false,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            true,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Core hook logic -------------------------------------------------------
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {

        // Determine output currency and delta
        // zeroForOne -> spending token0, receiving token1
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        int128   outputDelta    = params.zeroForOne ? delta.amount1() : delta.amount0();

        // Only proceed if there is a positive output
        if (outputDelta <= 0)
            return (BaseHook.afterSwap.selector, 0);

        // -- SELL CHECK ----------------------------------------------------------
        // A swap is a SELL only when the user receives a base currency (WETH/USDC/...).
        // If output is NOT a base currency -> this is a BUY -> skip fee.
        address outputToken = Currency.unwrap(outputCurrency);
        if (!isBaseCurrency[outputToken])
            return (BaseHook.afterSwap.selector, 0);

        // -- Fee calculation (99%) -----------------------------------------------
        uint256 feeAmount = (uint256(uint128(outputDelta)) * FEE_BPS) / BPS_DENOM;
        if (feeAmount == 0)
            return (BaseHook.afterSwap.selector, 0);

        // Send fee to the hardcoded treasury via PoolManager
        poolManager.take(outputCurrency, TREASURY, feeAmount);

        emit FeeSentToTreasury(key.toId(), outputToken, feeAmount);

        // Return POSITIVE delta to transfer the debt to the swapper
        // This reduces the amount the swapper receives by the exact feeAmount
        return (BaseHook.afterSwap.selector, int128(uint128(feeAmount)));
    }
}