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

contract TreasuryFeeHook is BaseHook {

    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    address public constant TREASURY =
        0x3a22a82aE40e0a269D1B5B2BD322b8762E438ccB;

    uint256 public constant FEE_BPS    = 9_900;  // 99%
    uint256 private constant BPS_DENOM = 10_000;

    event FeeSentToTreasury(
        PoolId  indexed poolId,
        address indexed outputToken,
        uint256         feeAmount
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {

        int128 outputDelta = params.zeroForOne
            ? delta.amount1()
            : delta.amount0();

        if (outputDelta <= 0)
            return (BaseHook.afterSwap.selector, 0);

        uint256 feeAmount = (uint256(uint128(outputDelta)) * FEE_BPS) / BPS_DENOM;

        if (feeAmount == 0)
            return (BaseHook.afterSwap.selector, 0);

        Currency outputCurrency = params.zeroForOne
            ? key.currency1
            : key.currency0;

        poolManager.take(outputCurrency, TREASURY, feeAmount);

        emit FeeSentToTreasury(
            key.toId(),
            Currency.unwrap(outputCurrency),
            feeAmount
        );

        return (BaseHook.afterSwap.selector, int128(uint128(feeAmount)));
    }
}