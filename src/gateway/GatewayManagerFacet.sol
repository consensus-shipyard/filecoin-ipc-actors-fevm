// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import {GatewayActorModifiers} from "../lib/LibGatewayActorStorage.sol";
import {CrossMsg} from "../structs/Checkpoint.sol";
import {Status} from "../enums/Status.sol";
import {FvmAddress} from "../structs/FvmAddress.sol";
import {SubnetID, Subnet} from "../structs/Subnet.sol";
import {Membership} from "../structs/Subnet.sol";
import {AlreadyRegisteredSubnet, CannotReleaseZero, NotEnoughFunds, NotEnoughFundsToRelease, NotEmptySubnetCircSupply, NotRegisteredSubnet} from "../errors/IPCErrors.sol";
import {LibGateway} from "../lib/LibGateway.sol";
import {SubnetIDHelper} from "../lib/SubnetIDHelper.sol";
import {CrossMsgHelper} from "../lib/CrossMsgHelper.sol";
import {FilAddress} from "fevmate/utils/FilAddress.sol";
import {ReentrancyGuard} from "../lib/LibReentrancyGuard.sol";

contract GatewayManagerFacet is GatewayActorModifiers, ReentrancyGuard {
    using FilAddress for address payable;
    using SubnetIDHelper for SubnetID;

    /// @notice register a subnet in the gateway. It is called by a subnet when it reaches the threshold stake
    function register() external payable {
        if (msg.value < s.minStake) {
            revert NotEnoughFunds();
        }

        SubnetID memory subnetId = s.networkName.createSubnetId(msg.sender);

        (bool registered, Subnet storage subnet) = LibGateway.getSubnet(subnetId);

        if (registered) {
            revert AlreadyRegisteredSubnet();
        }

        subnet.id = subnetId;
        subnet.stake = msg.value;
        subnet.status = Status.Active;
        subnet.genesisEpoch = block.number;

        s.subnetKeys.push(subnetId.toHash());

        s.totalSubnets += 1;
    }

    /// @notice addStake - add collateral for an existing subnet
    function addStake() external payable {
        if (msg.value <= 0) {
            revert NotEnoughFunds();
        }

        (bool registered, Subnet storage subnet) = LibGateway.getSubnet(msg.sender);

        if (!registered) {
            revert NotRegisteredSubnet();
        }

        subnet.stake += msg.value;

        if (subnet.status == Status.Inactive) {
            if (subnet.stake >= s.minStake) {
                subnet.status = Status.Active;
            }
        }
    }

    /// @notice release amount for an existing subnet
    /// @dev it can be used to release the stake or reward of the validator
    /// @notice release collateral for an existing subnet
    function releaseStake(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert CannotReleaseZero();
        }

        (bool registered, Subnet storage subnet) = LibGateway.getSubnet(msg.sender);

        if (!registered) {
            revert NotRegisteredSubnet();
        }
        if (subnet.stake < amount) {
            revert NotEnoughFundsToRelease();
        }

        subnet.stake -= amount;

        if (subnet.stake < s.minStake) {
            subnet.status = Status.Inactive;
        }
        payable(subnet.id.getActor()).sendValue(amount);
    }

    function releaseRewardForRelayer(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert CannotReleaseZero();
        }

        (bool registered, Subnet storage subnet) = LibGateway.getSubnet(msg.sender);
        if (!registered) {
            revert NotRegisteredSubnet();
        }

        payable(subnet.id.getActor()).sendValue(amount);
    }

    /// @notice kill an existing subnet. It's balance must be empty
    function kill() external {
        (bool registered, Subnet storage subnet) = LibGateway.getSubnet(msg.sender);

        if (!registered) {
            revert NotRegisteredSubnet();
        }
        if (subnet.circSupply > 0) {
            revert NotEmptySubnetCircSupply();
        }

        uint256 stake = subnet.stake;

        s.totalSubnets -= 1;

        delete s.subnets[subnet.id.toHash()];

        payable(msg.sender).sendValue(stake);
    }

    /// @notice fund - commit a top-down message releasing funds in a child subnet. There is an associated fee that gets distributed to validators in the subnet as well
    /// @param subnetId - subnet to fund
    /// @param to - the address to send funds to
    function fund(SubnetID calldata subnetId, FvmAddress calldata to) external payable {
        CrossMsg memory crossMsg = CrossMsgHelper.createFundMsg({
            subnet: subnetId,
            signer: msg.sender,
            to: to,
            value: msg.value,
            fee: 0 // injecting funds into a subnet should is free
        });

        // commit top-down message.
        LibGateway.commitTopDownMsg(crossMsg);
    }

    /// @notice release method locks funds in the current subnet and sends a cross message up the hierarchy to the parent gateway to release the funds
    function release(FvmAddress calldata to, uint256 fee) external payable validFee(fee) {
        CrossMsg memory crossMsg = CrossMsgHelper.createReleaseMsg({
            subnet: s.networkName,
            signer: msg.sender,
            to: to,
            value: msg.value - fee,
            fee: fee
        });

        LibGateway.commitBottomUpMsg(crossMsg);
    }
}
