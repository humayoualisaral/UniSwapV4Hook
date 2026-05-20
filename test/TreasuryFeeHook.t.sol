// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers}       from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks}           from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager}    from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}         from "v4-core/src/types/PoolKey.sol";
import {Currency}        from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath}        from "v4-core/src/libraries/TickMath.sol";
import {IHooks}          from "v4-core/src/interfaces/IHooks.sol";
import {HookMiner}       from "v4-hooks-public/src/utils/HookMiner.sol";
import {MockERC20}       from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";

contract TreasuryFeeHookTest is Test, Deployers {

    TreasuryFeeHook hook;
    MockERC20       memecoin;
    MockERC20       weth;
    PoolKey         poolKey;

    address constant TREASURY =
        0x3a22a82aE40e0a269D1B5B2BD322b8762E438ccB;

    function setUp() public {
        deployFreshManagerAndRouters();

        memecoin = new MockERC20("MEME", "MEME", 18);
        weth     = new MockERC20("WETH", "WETH", 18);
        if (address(memecoin) > address(weth))
            (memecoin, weth) = (weth, memecoin);

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG               |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (, bytes32 salt) = HookMiner.find(
            address(this), flags,
            type(TreasuryFeeHook).creationCode,
            abi.encode(address(manager))
        );

        hook = new TreasuryFeeHook{salt: salt}(IPoolManager(address(manager)));

        poolKey = PoolKey({
            currency0:   Currency.wrap(address(memecoin)),
            currency1:   Currency.wrap(address(weth)),
            fee:         10_000,
            tickSpacing: 200,
            hooks:       IHooks(address(hook))
        });

        manager.initialize(
            poolKey,
            TickMath.getSqrtPriceAtTick(0)
        );


        memecoin.mint(address(this), 1_000e18);
        weth.mint(address(this),     1_000e18);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            memecoin.approve(toApprove[i], type(uint256).max);
            weth.approve(toApprove[i], type(uint256).max);
        }

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower:      -1000,
                tickUpper:       1000,
                liquidityDelta:  1e18,
                salt:            0
            }),
            ""
        );
    }


    function test_SellFeeGoesToTreasury() public {
        uint256 before     = weth.balanceOf(TREASURY);
        bool    zeroForOne = address(memecoin) == Currency.unwrap(poolKey.currency0);

        swap(poolKey, zeroForOne, -int256(1e18), "");

        uint256 received = weth.balanceOf(TREASURY) - before;
        assertGt(received, 0, "treasury got nothing on sell");
        console.log("treasury received (sell):", received);
    }

    // ─── Buy: WETH → memecoin ─────────────────────────────────────────────────
    // Hook now taxes ALL swaps — buys also send fee to treasury

    function test_BuyFeeGoesToTreasury() public {
        uint256 before     = memecoin.balanceOf(TREASURY);
        bool    zeroForOne = address(weth) == Currency.unwrap(poolKey.currency0);

        weth.mint(address(this), 100e18);
        weth.approve(address(swapRouter), type(uint256).max);

        swap(poolKey, zeroForOne, -int256(1e18), "");

        uint256 received = memecoin.balanceOf(TREASURY) - before;
        assertGt(received, 0, "treasury got nothing on buy");
        console.log("treasury received (buy):", received);
    }

    // ─── Fee split is ~99% ────────────────────────────────────────────────────

    function test_FeeIs99Percent() public {
        uint256 userBefore     = weth.balanceOf(address(this));
        uint256 treasuryBefore = weth.balanceOf(TREASURY);
        bool    zeroForOne     = address(memecoin) == Currency.unwrap(poolKey.currency0);

        swap(poolKey, zeroForOne, -int256(1e18), "");

        uint256 userReceived     = weth.balanceOf(address(this)) - userBefore;
        uint256 treasuryReceived = weth.balanceOf(TREASURY)      - treasuryBefore;
        uint256 totalOutput      = userReceived + treasuryReceived;

        assertApproxEqRel(
            treasuryReceived,
            totalOutput * 9_900 / 10_000,
            0.01e18,
            "treasury fee should be ~99%"
        );

        console.log("user received:     ", userReceived);
        console.log("treasury received: ", treasuryReceived);
        console.log("total output:      ", totalOutput);
    }

    // ─── Constants ────────────────────────────────────────────────────────────

    function test_TreasuryAddress() public view {
        assertEq(hook.TREASURY(), TREASURY);
    }

    function test_FeeBps() public view {
        assertEq(hook.FEE_BPS(), 9_900);
    }
}
