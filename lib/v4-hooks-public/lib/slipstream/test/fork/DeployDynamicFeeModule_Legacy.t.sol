pragma solidity ^0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import {DeployDynamicFeeModule_LegacyFactory} from "script/DeployDynamicFeeModule_LegacyFactory.s.sol";

import {DynamicSwapFeeModule} from "contracts/core/fees/DynamicSwapFeeModule.sol";
import {CustomSwapFeeModule} from "contracts/core/fees/CustomSwapFeeModule.sol";
import {CLFactory} from "contracts/core/CLFactory.sol";
import {CLPool} from "contracts/core/CLPool.sol";

contract DeployDynamicFeeModuleForkTest_Legacy is Test {
    using stdJson for string;

    DeployDynamicFeeModule_LegacyFactory public deployDynamicFee;

    DynamicSwapFeeModule public dynamicFeeModule;

    // deployed contracts
    CLFactory public clFactory;
    CustomSwapFeeModule public feeModule;

    address[] public pools;
    uint24[] public fees;

    function setUp() public {
        vm.createSelectFork({urlOrAlias: "base", blockNumber: 44222075});
        clFactory = CLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
        feeModule = CustomSwapFeeModule(clFactory.swapFeeModule());

        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/logs/dynamicFees_legacy.json"));

        // load in vars
        string memory jsonConstants = vm.readFile(path);
        pools = abi.decode(jsonConstants.parseRaw(".pools"), (address[]));
        fees = abi.decode(jsonConstants.parseRaw(".customFees"), (uint24[]));
    }

    function test_deployDynamicFee() public {
        dynamicFeeModule = DynamicSwapFeeModule(0x090b2A6bb475c00e2256e2095A60887cD710803b);

        assertTrue(address(dynamicFeeModule) != address(0));

        assertEq(address(dynamicFeeModule.factory()), address(clFactory));
        assertEq(dynamicFeeModule.defaultScalingFactor(), 0);
        assertEq(dynamicFeeModule.defaultFeeCap(), 30_000); // 3%

        // Assert both DynamicFeeModules use the same state
        DynamicSwapFeeModule oldModule = DynamicSwapFeeModule(clFactory.swapFeeModule());
        assertEq(address(dynamicFeeModule.factory()), address(oldModule.factory()));
        assertEq(dynamicFeeModule.defaultScalingFactor(), oldModule.defaultScalingFactor());
        // assertEq(dynamicFeeModule.defaultFeeCap(), oldModule.defaultFeeCap()); // Default Fee Cap is 30_000 in new DynamicFeeModule
        assertEq(uint256(dynamicFeeModule.secondsAgo()), uint256(oldModule.secondsAgo()));

        uint256 length = clFactory.allPoolsLength();

        address pool;
        uint24 customFee;
        uint24 existingCustomFee;
        // iterate through a subset of all pools to limit test workload
        for (uint256 i = 0; i < length / 100; i++) {
            pool = clFactory.allPools(i);
            /// @dev Ensure custom fee is consistent with JSON input
            customFee = dynamicFeeModule.customFee(pool);

            /// @dev Ensure new DynamicFeeModule migrates existing custom fees from the legacy module
            existingCustomFee = feeModule.customFee(pool);
            assertEqUint(customFee, existingCustomFee);
        }
    }
}
