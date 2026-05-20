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

    // Tokens
    MockERC20 memecoin;
    MockERC20 weth;
    MockERC20 usdc;

    PoolKey wethPool;
    PoolKey usdcPool;

    // Constants matching the Hook contract
    address constant TREASURY = 0x3a22a82aE40e0a269D1B5B2BD322b8762E438ccB;
    uint256 constant FEE_BPS  = 9900; // 99%

    // === Setup ================================================================

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy mock tokens
        memecoin = new MockERC20("MEME", "MEME", 18);
        weth     = new MockERC20("WETH", "WETH", 18);
        usdc     = new MockERC20("USDC", "USDC",  6);

        // Register WETH and USDC as base currencies
        address[] memory bases = new address[](2);
        bases[0] = address(weth);
        bases[1] = address(usdc);

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG               |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine salt matching constructor args
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(TreasuryFeeHook).creationCode,
            abi.encode(address(manager), bases)
        );

        hook = new TreasuryFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            bases
        );

        // -- Build pool keys ---------------------------------------------------

        // MEME / WETH pool
        (address t0, address t1) = address(memecoin) < address(weth)
            ? (address(memecoin), address(weth))
            : (address(weth), address(memecoin));

        wethPool = PoolKey({
            currency0:   Currency.wrap(t0),
            currency1:   Currency.wrap(t1),
            fee:         10_000,
            tickSpacing: 200,
            hooks:       IHooks(address(hook))
        });

        // MEME / USDC pool
        (t0, t1) = address(memecoin) < address(usdc)
            ? (address(memecoin), address(usdc))
            : (address(usdc), address(memecoin));

        usdcPool = PoolKey({
            currency0:   Currency.wrap(t0),
            currency1:   Currency.wrap(t1),
            fee:         10_000,
            tickSpacing: 200,
            hooks:       IHooks(address(hook))
        });

        // Initialize both pools at tick 0
        manager.initialize(wethPool, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(usdcPool, TickMath.getSqrtPriceAtTick(0));

        // Mint tokens
        memecoin.mint(address(this), 1_000_000e18);
        weth.mint(address(this),     1_000_000e18);
        usdc.mint(address(this),     1_000_000e18);

        // Approve all routers
        address[9] memory routers = [
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
        for (uint256 i; i < routers.length; ++i) {
            memecoin.approve(routers[i], type(uint256).max);
            weth.approve(routers[i],     type(uint256).max);
            usdc.approve(routers[i],     type(uint256).max);
        }

        // Add liquidity
        ModifyLiquidityParams memory lp = ModifyLiquidityParams({
            tickLower:      -1000,
            tickUpper:       1000,
            liquidityDelta:  1000e18,
            salt:            0
        });
        modifyLiquidityRouter.modifyLiquidity(wethPool, lp, "");
        modifyLiquidityRouter.modifyLiquidity(usdcPool, lp, "");
    }

    // === Helpers ==============================================================

    function _isToken0(PoolKey memory key, address token) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == token;
    }

    // === Sell tests (99% fee expected) ========================================

    function test_Sell_MemeForWeth_FeeCharged() public {
        uint256 before = weth.balanceOf(TREASURY);

        bool zeroForOne = _isToken0(wethPool, address(memecoin));
        swap(wethPool, zeroForOne, -int256(1e18), "");

        uint256 feeReceived = weth.balanceOf(TREASURY) - before;
        assertGt(feeReceived, 0, "No fee on MEME->WETH sell");
        console.log("[WETH pool] MEME->WETH fee to treasury:", feeReceived);
    }

    function test_Sell_MemeForUsdc_FeeCharged() public {
        uint256 before = usdc.balanceOf(TREASURY);

        bool zeroForOne = _isToken0(usdcPool, address(memecoin));
        swap(usdcPool, zeroForOne, -int256(1e18), "");

        uint256 feeReceived = usdc.balanceOf(TREASURY) - before;
        assertGt(feeReceived, 0, "No fee on MEME->USDC sell");
        console.log("[USDC pool] MEME->USDC fee to treasury:", feeReceived);
    }

    // === Buy tests (zero fee expected) =======================================

    function test_Buy_WethForMeme_NoFee() public {
        uint256 treasuryBefore = memecoin.balanceOf(TREASURY);

        bool zeroForOne = _isToken0(wethPool, address(weth));
        swap(wethPool, zeroForOne, -int256(1e18), "");

        uint256 feeReceived = memecoin.balanceOf(TREASURY) - treasuryBefore;
        assertEq(feeReceived, 0, "Fee charged on buy (WETH->MEME) - must be 0");
    }

    function test_Buy_UsdcForMeme_NoFee() public {
        uint256 treasuryBefore = memecoin.balanceOf(TREASURY);

        bool zeroForOne = _isToken0(usdcPool, address(usdc));
        swap(usdcPool, zeroForOne, -int256(1e18), "");

        uint256 feeReceived = memecoin.balanceOf(TREASURY) - treasuryBefore;
        assertEq(feeReceived, 0, "Fee charged on buy (USDC->MEME) - must be 0");
    }

    // === Fee math accuracy ====================================================

    function test_FeePercentage_IsCorrect() public {
        uint256 userBefore     = weth.balanceOf(address(this));
        uint256 treasuryBefore = weth.balanceOf(TREASURY);

        bool zeroForOne = _isToken0(wethPool, address(memecoin));
        swap(wethPool, zeroForOne, -int256(1e18), "");

        uint256 userReceived     = weth.balanceOf(address(this)) - userBefore;
        uint256 treasuryReceived = weth.balanceOf(TREASURY)      - treasuryBefore;
        uint256 totalOutput      = userReceived + treasuryReceived;

        // treasury should get exactly 9900/10000 (99%) of total output
        assertApproxEqRel(
            treasuryReceived,
            totalOutput * FEE_BPS / 10_000,
            0.01e18,
            "Fee % mismatch"
        );

        console.log("user received:     ", userReceived);
        console.log("treasury received: ", treasuryReceived);
    }

    // === Sanity: initial state ================================================

    function test_InitialState() public view {
        assertEq(hook.TREASURY(), TREASURY);
        assertEq(hook.FEE_BPS(),  FEE_BPS);
        assertTrue(hook.isBaseCurrency(address(weth)));
        assertTrue(hook.isBaseCurrency(address(usdc)));
        assertFalse(hook.isBaseCurrency(address(memecoin)));
    }
}