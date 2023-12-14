// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.22;

import {METHOD_SEND, EMPTY_BYTES} from "../constants/Constants.sol";
import {StorableMsg, CrossMsg} from "../structs/Checkpoint.sol";
import {SubnetID, IPCAddress} from "../structs/Subnet.sol";
import {SubnetIDHelper} from "../lib/SubnetIDHelper.sol";
import {FvmAddressHelper} from "../lib/FvmAddressHelper.sol";
import {FvmAddress} from "../structs/FvmAddress.sol";
import {FilAddress} from "fevmate/utils/FilAddress.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

/// @title Helper library for manipulating StorableMsg struct
/// @author LimeChain team
library CrossMsgHelper {
    using SubnetIDHelper for SubnetID;
    using FilAddress for address;
    using FvmAddressHelper for FvmAddress;

    function createReleaseMsg(
        SubnetID calldata subnet,
        address signer,
        FvmAddress calldata to,
        uint256 value,
        uint256 fee
    ) external pure returns (CrossMsg memory) {
        return
            CrossMsg({
                message: StorableMsg({
                    from: IPCAddress({subnetId: subnet, rawAddress: FvmAddressHelper.from(signer)}),
                    to: IPCAddress({subnetId: subnet.getParentSubnet(), rawAddress: to}),
                    value: value,
                    nonce: 0,
                    method: METHOD_SEND,
                    params: EMPTY_BYTES,
                    fee: fee
                }),
                wrapped: false
            });
    }

    function createFundMsg(
        SubnetID calldata subnet,
        address signer,
        FvmAddress calldata to,
        uint256 value,
        uint256 fee
    ) external pure returns (CrossMsg memory) {
        return
            CrossMsg({
                message: StorableMsg({
                    from: IPCAddress({subnetId: subnet.getParentSubnet(), rawAddress: FvmAddressHelper.from(signer)}),
                    to: IPCAddress({subnetId: subnet, rawAddress: to}),
                    value: value,
                    nonce: 0,
                    method: METHOD_SEND,
                    params: EMPTY_BYTES,
                    fee: fee
                }),
                wrapped: false
            });
    }

    function toHash(CrossMsg memory crossMsg) external pure returns (bytes32) {
        return keccak256(abi.encode(crossMsg));
    }

    function toHash(CrossMsg[] memory crossMsgs) external pure returns (bytes32) {
        return keccak256(abi.encode(crossMsgs));
    }

    function isEmpty(CrossMsg memory crossMsg) external pure returns (bool) {
        return
            crossMsg.message.nonce == 0 &&
            crossMsg.message.to.subnetId.root == 0 &&
            crossMsg.message.from.subnetId.root == 0;
    }

    function execute(CrossMsg calldata crossMsg) external returns (bytes memory) {
        uint256 value = crossMsg.message.value;
        address recipient = crossMsg.message.to.rawAddress.extractEvmAddress().normalize();

        if (crossMsg.message.method == METHOD_SEND) {
            Address.sendValue(payable(recipient), value);
            return EMPTY_BYTES;
        }

        bytes memory params = crossMsg.message.params;

        if (crossMsg.wrapped) {
            params = abi.encode(crossMsg);
        }

        bytes memory data = bytes.concat(crossMsg.message.method, params);

        // gas-opt: original check: value > 0
        if (value != 0) {
            return Address.functionCallWithValue({target: recipient, data: data, value: value});
        }

        return Address.functionCall(recipient, data);
    }

    // checks whether the cross messages are sorted in ascending order or not
    function isSorted(CrossMsg[] calldata crossMsgs) external pure returns (bool) {
        uint256 prevNonce;
        uint256 length = crossMsgs.length;
        for (uint256 i; i < length; ) {
            uint256 nonce = crossMsgs[i].message.nonce;

            if (prevNonce >= nonce) {
                // gas-opt: original check: i > 0
                if (i != 0) {
                    return false;
                }
            }

            prevNonce = nonce;
            unchecked {
                ++i;
            }
        }

        return true;
    }
}
