// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "../lib/SubnetIDHelper.sol";
import "../structs/Checkpoint.sol";

/// @title Helper library for manipulating Checkpoint struct
/// @author LimeChain team
library CheckpointMappingHelper {
    using SubnetIDHelper for SubnetID;

    function getPrevCheckpoint(
        mapping(int64 => Checkpoint) storage checkpoints,
        int64 epoch,
        int64 checkPeriod
    ) public view returns (Checkpoint memory) {
        epoch -= checkPeriod;
        while (checkpoints[epoch].signature.length == 0 && epoch > 0) {
            epoch -= checkPeriod;
        }

        return checkpoints[epoch];
    }

    function getCheckpointPerEpoch(
        mapping(int64 => Checkpoint) storage checkpoints,
        uint256 blockNumber,
        int64 checkPeriod
    )
        public
        view
        returns (bool exists, int64 epoch, Checkpoint storage checkpoint)
    {
        epoch = (int64(uint64(blockNumber)) / checkPeriod) * checkPeriod;
        checkpoint = checkpoints[epoch];
        exists =
            checkpoint.data.source.toHash() !=
            SubnetID(new address[](0)).toHash();
    }
}
