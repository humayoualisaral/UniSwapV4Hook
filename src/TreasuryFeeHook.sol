// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

contract TreasuryFeeHook is BaseHook {

    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    address public constant TREASURY =
        0x3a22a82aE40e0a269D1B5B2BD322b8762E438ccB;

    uint256 public constant FEE_BPS    = 9_900;
    uint256 private constant BPS_DENOM = 10_000;

    mapping(PoolId => address) public memecoinOf;

    event PoolRegistered(PoolId indexed poolId, address indexed memecoin, address indexed pairedToken);
    event FeeSentToTreasury(PoolId indexed poolId, address indexed outputToken, uint256 feeAmount);

    error PoolAlreadyRegistered(PoolId poolId);
    error MemecoinNotInPool();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public pure override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 true,
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

    // BaseHook's external hooks are non-virtual and call the internal underscored
    // versions. Implement the internal hooks here.
    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        // Pool registration is done via registerPool helper in tests (hookData
        // isn't provided by the current PoolManager.initialize interface), so
        // just return the selector.
        return BaseHook.afterInitialize.selector;
    }

function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
    internal
    virtual
    override
    returns (bytes4, int128)
{
    PoolId  pid      = key.toId();
    address memecoin = memecoinOf[pid];

    if (memecoin == address(0))
        return (BaseHook.afterSwap.selector, 0);

    bool memecoinIsCurrency0 = (memecoin == Currency.unwrap(key.currency0));
    bool isSell = (memecoinIsCurrency0 == params.zeroForOne);

    if (!isSell)
        return (BaseHook.afterSwap.selector, 0);
// Output delta is POSITIVE from pool perspective (tokens going OUT to user)
int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();

// Must be POSITIVE — tokens leaving pool
if (outputDelta <= 0)
    return (BaseHook.afterSwap.selector, 0);

// No need to flip sign — already positive
uint128 absOutput = uint128(outputDelta);
uint256 feeAmount = (uint256(absOutput) * FEE_BPS) / BPS_DENOM;

if (feeAmount == 0)
    return (BaseHook.afterSwap.selector, 0);

Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
poolManager.take(outputCurrency, TREASURY, feeAmount);

emit FeeSentToTreasury(pid, Currency.unwrap(outputCurrency), feeAmount);
return (BaseHook.afterSwap.selector, int128(uint128(feeAmount)));
}
    /// @notice Test helper to register a pool's memecoin. Used in tests where
    /// PoolManager.initialize does not accept hookData.
    function registerPool(PoolKey calldata key, address memecoin) external {
        PoolId pid = key.toId();
        if (memecoinOf[pid] != address(0)) revert PoolAlreadyRegistered(pid);

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (memecoin != c0 && memecoin != c1) revert MemecoinNotInPool();

        memecoinOf[pid] = memecoin;
        emit PoolRegistered(pid, memecoin, (memecoin == c0) ? c1 : c0);
    }
}