// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {GatewayActorStorage} from "../lib/LibGatewayActorStorage.sol";
import {CrossMsg, BottomUpCheckpoint, StorableMsg, ChildCheck} from "../structs/Checkpoint.sol";
import {LibGateway} from "../lib/LibGateway.sol";
import {LibVoting} from "../lib/LibVoting.sol";
import {Status} from "../enums/Status.sol";
import {SubnetID, Subnet} from "../structs/Subnet.sol";

contract GatewayGetterFacet {
    // solhint-disable-next-line private-vars-leading-underscore
    // slither-disable-next-line uninitialized-state-variables
    GatewayActorStorage internal s;

    function crossMsgFee() external view returns (uint256) {
        return s.crossMsgFee;
    }

    function bottomUpNonce() external view returns (uint64) {
        return s.bottomUpNonce;
    }

    function totalSubnets() external view returns (uint64) {
        return s.totalSubnets;
    }

    function minStake() external view returns (uint256) {
        return s.minStake;
    }

    function initialized() external view returns (bool) {
        return s.initialized;
    }

    function bottomUpCheckPeriod() external view returns (uint64) {
        return s.bottomUpCheckPeriod;
    }

    function topDownCheckPeriod() external view returns (uint64) {
        return s.topDownCheckPeriod;
    }

    function getNetworkName() external view returns (SubnetID memory) {
        return s.networkName;
    }

    function bottomUpCheckpoints(uint64 e) external view returns (BottomUpCheckpoint memory) {
        return s.bottomUpCheckpoints[e];
    }

    /// @notice returns the subnet with the given id
    /// @param subnetId the id of the subnet
    /// @return found whether the subnet exists
    /// @return subnet -  the subnet struct
    function getSubnet(SubnetID calldata subnetId) external view returns (bool, Subnet memory) {
        return LibGateway.getSubnet(subnetId);
    }

    function subnets(bytes32 h) external view returns (Subnet memory subnet) {
        return s.subnets[h];
    }

    /// @notice get number of top-down messages for the given subnet
    function getSubnetTopDownMsgsLength(SubnetID memory subnetId) external view returns (uint256) {
        (, Subnet storage subnet) = LibGateway.getSubnet(subnetId);

        return subnet.topDownMsgs.length;
    }

    function getGenesisEpoch() public view returns (uint64) {
        return LibVoting.getGenesisEpoch();
    }

    function totalWeight() public view returns (uint256) {
        return s.totalWeight;
    }

    function appliedTopDownNonce() public view returns (uint64) {
        return s.appliedTopDownNonce;
    }

    function postboxHasOwner(bytes32 id, address caller) public view returns (bool) {
        return s.postboxHasOwner[id][caller];
    }

    function postbox(bytes32 id) public view returns (StorableMsg memory storableMsg, bool wrapped) {
        return (s.postbox[id].message, s.postbox[id].wrapped);
    }

    /// @notice get the top-down message at the given index for the given subnet
    function getSubnetTopDownMsg(SubnetID memory subnetId, uint256 index) external view returns (CrossMsg memory) {
        (, Subnet storage subnet) = LibGateway.getSubnet(subnetId);
        return subnet.topDownMsgs[index];
    }

    function executableQueue() public view returns (uint64, uint64, uint64) {
        return LibVoting.executableQueue();
    }

    function lastVotingExecutedEpoch() public view returns (uint64) {
        return LibVoting.lastVotingExecutedEpoch();
    }

    function majorityPercentage() public view returns (uint64) {
        return LibVoting.majorityPercentage();
    }
}
