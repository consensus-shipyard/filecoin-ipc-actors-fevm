// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../../src/errors/IPCErrors.sol";
import {EMPTY_BYTES, METHOD_SEND} from "../../src/constants/Constants.sol";
import {CrossMsg, StorableMsg} from "../../src/structs/CrossNet.sol";
import {FvmAddress} from "../../src/structs/FvmAddress.sol";
import {SubnetID, Subnet, IPCAddress, Validator} from "../../src/structs/Subnet.sol";
import {SubnetIDHelper} from "../../src/lib/SubnetIDHelper.sol";
import {FvmAddressHelper} from "../../src/lib/FvmAddressHelper.sol";
import {CrossMsgHelper} from "../../src/lib/CrossMsgHelper.sol";
import {GatewayDiamond, FEATURE_MULTILEVEL_CROSSMSG} from "../../src/GatewayDiamond.sol";
import {GatewayGetterFacet} from "../../src/gateway/GatewayGetterFacet.sol";
import {GatewayManagerFacet} from "../../src/gateway/GatewayManagerFacet.sol";
import {GatewayRouterFacet} from "../../src/gateway/GatewayRouterFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/DiamondCutFacet.sol";
import {GatewayMessengerFacet} from "../../src/gateway/GatewayMessengerFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/DiamondLoupeFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/DiamondCutFacet.sol";
import {IntegrationTestBase} from "../IntegrationTestBase.sol";
import {FilAddress} from "fevmate/utils/FilAddress.sol";

contract GatewayL2ActorDiamondTest is Test, IntegrationTestBase {
    using SubnetIDHelper for SubnetID;
    using CrossMsgHelper for CrossMsg;

    function setUp() public override {
        address[] memory path2 = new address[](2);
        path2[0] = CHILD_NETWORK_ADDRESS;
        path2[1] = CHILD_NETWORK_ADDRESS_2;

        GatewayDiamond.ConstructorParams memory gwConstructorParams = defaultGatewayParams();

        gatewayDiamond = createGatewayDiamond(gwConstructorParams);
        gwGetter = GatewayGetterFacet(address(gatewayDiamond));
        gwManager = GatewayManagerFacet(address(gatewayDiamond));
        gwRouter = GatewayRouterFacet(address(gatewayDiamond));
        gwMessenger = GatewayMessengerFacet(address(gatewayDiamond));
        gwLouper = DiamondLoupeFacet(address(gatewayDiamond));
        gwCutFacet = DiamondCutFacet(address(gatewayDiamond));
    }

    function defaultGatewayParams() internal pure override returns (GatewayDiamond.ConstructorParams memory) {
        address[] memory path2 = new address[](2);
        path2[0] = CHILD_NETWORK_ADDRESS;
        path2[1] = CHILD_NETWORK_ADDRESS_2;

        GatewayDiamond.ConstructorParams memory params = GatewayDiamond.ConstructorParams({
            networkName: SubnetID({root: ROOTNET_CHAINID, route: path2}),
            bottomUpCheckPeriod: DEFAULT_CHECKPOINT_PERIOD,
            msgFee: DEFAULT_CROSS_MSG_FEE,
            minCollateral: DEFAULT_COLLATERAL_AMOUNT,
            majorityPercentage: DEFAULT_MAJORITY_PERCENTAGE,
            genesisValidators: new Validator[](0),
            activeValidatorsLimit: DEFAULT_ACTIVE_VALIDATORS_LIMIT
        });

        return params;
    }

    function testGatewayDiamond_CommitParentFinality_BigNumberOfMessages() public {
        uint256 n = 2000;
        FvmAddress[] memory validators = new FvmAddress[](1);
        validators[0] = FvmAddressHelper.from(vm.addr(100));
        vm.deal(vm.addr(100), 1);

        uint256[] memory weights = new uint[](1);
        weights[0] = 100;

        SubnetID memory id = gwGetter.getNetworkName();

        CrossMsg[] memory topDownMsgs = new CrossMsg[](n);
        for (uint64 i = 0; i < n; i++) {
            topDownMsgs[i] = CrossMsg({
                message: StorableMsg({
                    from: IPCAddress({subnetId: id, rawAddress: FvmAddressHelper.from(address(this))}),
                    to: IPCAddress({subnetId: id, rawAddress: FvmAddressHelper.from(address(this))}),
                    value: 0,
                    nonce: i,
                    method: this.callback.selector,
                    params: EMPTY_BYTES,
                    fee: DEFAULT_CROSS_MSG_FEE
                }),
                wrapped: false
            });
        }

        vm.startPrank(FilAddress.SYSTEM_ACTOR);

        gwRouter.applyCrossMessages(topDownMsgs);
        require(gwGetter.getSubnetTopDownMsgsLength(id) == 0, "unexpected top-down message");
        (bool ok, uint64 tdn) = gwGetter.getAppliedTopDownNonce(id);
        require(!ok && tdn == 0, "unexpected nonce");

        vm.stopPrank();
    }

    function testGatewayDiamond_Propagate_Works_WithFeeRemainderNew() external {
        if (!FEATURE_MULTILEVEL_CROSSMSG) {
            // skip
            return;
        }
        (, address[] memory validators) = setupValidators();
        address caller = validators[0];

        bytes32 postboxId = setupWhiteListMethod(caller);

        vm.deal(caller, 1 ether);

        vm.expectCall(caller, 1 ether - gwGetter.crossMsgFee(), new bytes(0), 1);
        vm.prank(caller);
        gwMessenger.propagate{value: 1 ether}(postboxId);

        require(caller.balance == 1 ether - gwGetter.crossMsgFee(), "unexpected balance");
    }

    function testGatewayDiamond_Propagate_Works_NoFeeReminder() external {
        if (!FEATURE_MULTILEVEL_CROSSMSG) {
            // skip
            return;
        }
        (, address[] memory validators) = setupValidators();
        address caller = validators[0];

        uint256 fee = gwGetter.crossMsgFee();

        bytes32 postboxId = setupWhiteListMethod(caller);

        vm.deal(caller, fee);

        vm.prank(caller);
        vm.expectCall(caller, 0, EMPTY_BYTES, 0);
        gwMessenger.propagate{value: fee}(postboxId);
        require(caller.balance == 0, "unexpected balance");
    }

    function testGatewayDiamond_Propagate_Fails_NotEnoughFee() public {
        if (!FEATURE_MULTILEVEL_CROSSMSG) {
            // skip
            return;
        }
        address caller = vm.addr(100);
        vm.deal(caller, 1 ether);

        vm.expectRevert(NotEnoughFee.selector);
        gwMessenger.propagate(bytes32(""));
    }

    function setupWhiteListMethod(address caller) internal returns (bytes32) {
        registerSubnet(DEFAULT_COLLATERAL_AMOUNT, address(this));

        CrossMsg memory crossMsg = CrossMsg({
            message: StorableMsg({
                from: IPCAddress({
                    subnetId: gwGetter.getNetworkName().createSubnetId(caller),
                    rawAddress: FvmAddressHelper.from(caller)
                }),
                to: IPCAddress({
                    subnetId: gwGetter.getNetworkName().createSubnetId(address(this)),
                    rawAddress: FvmAddressHelper.from(address(this))
                }),
                value: DEFAULT_CROSS_MSG_FEE + 1,
                nonce: 0,
                method: METHOD_SEND,
                params: new bytes(0),
                fee: DEFAULT_CROSS_MSG_FEE
            }),
            wrapped: false
        });
        CrossMsg[] memory msgs = new CrossMsg[](1);
        msgs[0] = crossMsg;

        vm.prank(FilAddress.SYSTEM_ACTOR);
        gwRouter.applyCrossMessages(msgs);

        return crossMsg.toHash();
    }

    function callback() public view {}
}
