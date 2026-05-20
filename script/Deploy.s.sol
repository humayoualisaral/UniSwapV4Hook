// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager}    from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks}           from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";

contract Deploy is Script {

    // Sepolia PoolManager
    address constant SEPOLIA_PM =
        0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    // Mainnet PoolManager
    address constant MAINNET_PM =
        0x000000000004444c5dc75cB358380D2e3dE08A90;
    // Standard CREATE2 factory (same on all chains)
    // renamed to avoid symbol collision with forge-std Base constants in tests
    address constant DEPLOY_CREATE2_FACTORY =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address pm = block.chainid == 1 ? MAINNET_PM : SEPOLIA_PM;

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG         |
            Hooks.AFTER_SWAP_FLAG               |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine salt so hook address encodes permission bits
        (address hookAddr, bytes32 salt) = HookMiner.find(
            DEPLOY_CREATE2_FACTORY,
            flags,
            type(TreasuryFeeHook).creationCode,
            abi.encode(pm)
        );

        console.log("Hook address:", hookAddr);

        vm.startBroadcast();
        TreasuryFeeHook hook = new TreasuryFeeHook{salt: salt}(
            IPoolManager(pm)
        );
        require(address(hook) == hookAddr, "Address mismatch");
        console.log("Deployed:", address(hook));
        vm.stopBroadcast();
    }
}