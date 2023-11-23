// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import {EMPTY_HASH} from "../constants/Constants.sol";
import {SubnetID} from "../structs/Subnet.sol";
import {BottomUpCheckpoint, CrossMsg} from "../structs/Checkpoint.sol";

/// @title Helper library for manipulating Checkpoint struct
/// @author LimeChain team
library CheckpointHelper {
    bytes32 private constant EMPTY_BOTTOMUPCHECKPOINT_HASH =
        keccak256(
            abi.encode(
                BottomUpCheckpoint({
                    subnetID: SubnetID(0, new address[](0)),
                    blockHeight: 0,
                    blockHash: 0,
                    nextConfigurationNumber: 0,
                    crossMessagesHash: 0
                })
            )
        );

    function toHash(BottomUpCheckpoint memory bottomupCheckpoint) public pure returns (bytes32) {
        return keccak256(abi.encode(bottomupCheckpoint));
    }

    function isEmpty(BottomUpCheckpoint memory bottomUpCheckpoint) public pure returns (bool) {
        return toHash(bottomUpCheckpoint) == EMPTY_BOTTOMUPCHECKPOINT_HASH;
    }
}
