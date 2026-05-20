// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "forge-std/Script.sol";

import "contracts/core/fees/DynamicSwapFeeModule.sol";

contract DeployDynamicFeeModule_CapFactory is Script {
    using stdJson for string;

    // CLFactory address
    address public constant clFactory = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;

    DynamicSwapFeeModule public dynamicFeeModule;

    address[] public pools;
    uint24[] public fees;

    function run() external {
        // Define the constructor parameters
        uint256 defaultScalingFactor = 0;
        uint256 defaultFeeCap = 30_000; // 3%

        _populatePoolsAndFees();

        vm.startBroadcast();
        dynamicFeeModule = new DynamicSwapFeeModule({
            _factory: clFactory,
            _defaultScalingFactor: defaultScalingFactor,
            _defaultFeeCap: defaultFeeCap,
            _pools: pools,
            _fees: fees
        });
        vm.stopBroadcast();

        // Log the address of the deployed contract
        console.log("DynamicSwapFeeModule deployed at:", address(dynamicFeeModule));
    }

    function _populatePoolsAndFees() internal {
        string memory root = vm.projectRoot();
        string memory path = string(abi.encodePacked(root, "/logs/dynamicFees_cap.json"));

        // load in vars
        string memory jsonConstants = vm.readFile(path);
        pools = abi.decode(jsonConstants.parseRaw(".pools"), (address[]));
        fees = abi.decode(jsonConstants.parseRaw(".customFees"), (uint24[]));
    }
}
