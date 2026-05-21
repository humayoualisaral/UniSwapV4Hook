// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";

contract DeployTreasuryHook is Script {
    address constant POOLMANAGER    = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory initCode = abi.encodePacked(
            type(TreasuryFeeHook).creationCode,
            abi.encode(POOLMANAGER)
        );
        bytes32 bytecodeHash = keccak256(initCode);

        console2.log("Mining...");

        address hookAddr;
        bytes32 salt;
        bool found;

        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            hookAddr = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                CREATE2_DEPLOYER,
                salt,
                bytecodeHash
            )))));
            // Exact match on all 14 permission bits — loose check was the
            // root cause of HookAddressNotValid in the first attempt
            if ((uint160(hookAddr) & 0x3FFF) == flags) {
                console2.log("Found at iteration:", i);
                console2.log("Address:", hookAddr);
                found = true;
                break;
            }
        }

        require(found, "No valid salt found");

        vm.startBroadcast();
        // Call the Arachnid deployer directly: calldata = salt ++ initcode
        // This worked in attempt 1 — address matched. Only the mask was wrong then.
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "Deploy failed");

        require(hookAddr.code.length > 0, "Nothing at expected address");
        console2.log("Deployed to:", hookAddr);
        vm.stopBroadcast();
    }
}
