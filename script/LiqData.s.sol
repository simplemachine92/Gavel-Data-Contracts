// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/LiqData.sol";

contract MyScript is Script {
    // Used to deploy dataprovider locally
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        LiqData data = new LiqData();

        vm.stopBroadcast();
    }
}
