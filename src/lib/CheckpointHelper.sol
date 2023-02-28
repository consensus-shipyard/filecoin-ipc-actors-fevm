// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "../structs/Checkpoint.sol";

library CheckpointHelper {

    error CheckpointNotFound(int64 epoch);

    function getPrevCheckpoint(mapping(int64 => Checkpoint) storage checkpoints, int64 epoch, int64 checkPeriod) public view returns (Checkpoint memory) {
        epoch -= checkPeriod;
        while(checkpoints[epoch].signature.length == 0 && epoch > 0) {
            epoch -= checkPeriod;
        }
        if(epoch <= 0)
            revert CheckpointNotFound(epoch);
      
        return checkpoints[epoch];
    }

    function getCheckpoint(mapping(int64 => Checkpoint) storage checkpoints, int64 epoch) public view returns (Checkpoint memory) {
        return checkpoints[epoch];
    }
}