// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.19;

import "../src/errors/IPCErrors.sol";
import {Test} from "forge-std/Test.sol";
import {TestUtils} from "./TestUtils.sol";
import {NumberContractFacetSeven, NumberContractFacetEight} from "./NumberContract.sol";
import {EMPTY_BYTES, METHOD_SEND, EMPTY_HASH} from "../src/constants/Constants.sol";
import {ConsensusType} from "../src/enums/ConsensusType.sol";
import {Status} from "../src/enums/Status.sol";
import {CrossMsg, BottomUpCheckpoint, StorableMsg} from "../src/structs/Checkpoint.sol";
import {FvmAddress} from "../src/structs/FvmAddress.sol";
import {SubnetID, IPCAddress, Subnet, ValidatorInfo, Validator} from "../src/structs/Subnet.sol";
import {StorableMsg} from "../src/structs/Checkpoint.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IGateway} from "../src/interfaces/IGateway.sol";
import {IDiamond} from "../src/interfaces/IDiamond.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {FvmAddressHelper} from "../src/lib/FvmAddressHelper.sol";
import {StorableMsgHelper} from "../src/lib/StorableMsgHelper.sol";
import {SubnetIDHelper} from "../src/lib/SubnetIDHelper.sol";
import {SubnetActorDiamond, FunctionNotFound} from "../src/SubnetActorDiamond.sol";
import {GatewayDiamond} from "../src/GatewayDiamond.sol";
import {GatewayGetterFacet} from "../src/gateway/GatewayGetterFacet.sol";
import {GatewayMessengerFacet} from "../src/gateway/GatewayMessengerFacet.sol";
import {GatewayManagerFacet} from "../src/gateway/GatewayManagerFacet.sol";
import {GatewayRouterFacet} from "../src/gateway/GatewayRouterFacet.sol";
import {SubnetActorManagerFacet} from "../src/subnet/SubnetActorManagerFacet.sol";
import {SubnetActorGetterFacet} from "../src/subnet/SubnetActorGetterFacet.sol";
import {DiamondCutFacet} from "../src/diamond/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/diamond/DiamondLoupeFacet.sol";
import {FilAddress} from "fevmate/utils/FilAddress.sol";
import {LibStaking} from "../src/lib/LibStaking.sol";
import {LibDiamond} from "../src/lib/LibDiamond.sol";

import {console} from "forge-std/console.sol";

contract SubnetActorDiamondTest is Test {
    using SubnetIDHelper for SubnetID;
    using FilAddress for address;
    using FvmAddressHelper for FvmAddress;

    address private constant DEFAULT_IPC_GATEWAY_ADDR = address(1024);
    uint64 private constant DEFAULT_CHECKPOINT_PERIOD = 10;
    uint256 private constant DEFAULT_MIN_VALIDATOR_STAKE = 1 ether;
    uint64 private constant DEFAULT_MIN_VALIDATORS = 1;
    string private constant DEFAULT_NET_ADDR = "netAddr";
    uint256 private constant CROSS_MSG_FEE = 10 gwei;
    uint256 private constant DEFAULT_RELAYER_REWARD = 10 gwei;
    uint8 private constant DEFAULT_MAJORITY_PERCENTAGE = 60;
    uint64 private constant ROOTNET_CHAINID = 123;

    address gatewayAddress;
    IGateway gatewayContract;

    bytes4[] saGetterSelectors;
    bytes4[] saManagerSelectors;
    bytes4[] cutFacetSelectors;
    bytes4[] louperSelectors;

    bytes4[] gwRouterSelectors;
    bytes4[] gwManagerSelectors;
    bytes4[] gwGetterSelectors;
    bytes4[] gwMessengerSelectors;

    SubnetActorDiamond saDiamond;
    SubnetActorManagerFacet saManager;
    SubnetActorGetterFacet saGetter;
    DiamondCutFacet cutFacet;
    DiamondLoupeFacet louper;

    GatewayDiamond gatewayDiamond;
    GatewayManagerFacet gwManager;
    GatewayGetterFacet gwGetter;
    GatewayRouterFacet gwRouter;
    GatewayMessengerFacet gwMessenger;

    constructor() {
        saGetterSelectors = TestUtils.generateSelectors(vm, "SubnetActorGetterFacet");
        saManagerSelectors = TestUtils.generateSelectors(vm, "SubnetActorManagerFacet");
        cutFacetSelectors = TestUtils.generateSelectors(vm, "DiamondCutFacet");
        louperSelectors = TestUtils.generateSelectors(vm, "DiamondLoupeFacet");

        gwRouterSelectors = TestUtils.generateSelectors(vm, "GatewayRouterFacet");
        gwGetterSelectors = TestUtils.generateSelectors(vm, "GatewayGetterFacet");
        gwManagerSelectors = TestUtils.generateSelectors(vm, "GatewayManagerFacet");
        gwMessengerSelectors = TestUtils.generateSelectors(vm, "GatewayMessengerFacet");
    }

    function createGatewayDiamond(GatewayDiamond.ConstructorParams memory params) public returns (GatewayDiamond) {
        gwRouter = new GatewayRouterFacet();
        gwManager = new GatewayManagerFacet();
        gwGetter = new GatewayGetterFacet();
        gwMessenger = new GatewayMessengerFacet();

        IDiamond.FacetCut[] memory diamondCut = new IDiamond.FacetCut[](4);

        diamondCut[0] = (
            IDiamond.FacetCut({
                facetAddress: address(gwRouter),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: gwRouterSelectors
            })
        );

        diamondCut[1] = (
            IDiamond.FacetCut({
                facetAddress: address(gwManager),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: gwManagerSelectors
            })
        );

        diamondCut[2] = (
            IDiamond.FacetCut({
                facetAddress: address(gwGetter),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: gwGetterSelectors
            })
        );

        diamondCut[3] = (
            IDiamond.FacetCut({
                facetAddress: address(gwMessenger),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: gwMessengerSelectors
            })
        );

        gatewayDiamond = new GatewayDiamond(diamondCut, params);

        return gatewayDiamond;
    }

    function createSubnetActorDiamondWithFaucets(
        SubnetActorDiamond.ConstructorParams memory params,
        address getterFaucet,
        address managerFaucet
    ) public returns (SubnetActorDiamond) {
        IDiamond.FacetCut[] memory diamondCut = new IDiamond.FacetCut[](2);

        diamondCut[0] = (
            IDiamond.FacetCut({
                facetAddress: getterFaucet,
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: saGetterSelectors
            })
        );

        diamondCut[1] = (
            IDiamond.FacetCut({
                facetAddress: managerFaucet,
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: saManagerSelectors
            })
        );

        saDiamond = new SubnetActorDiamond(diamondCut, params);
        return saDiamond;
    }

    function setUp() public {
        GatewayDiamond.ConstructorParams memory gwConstructorParams = GatewayDiamond.ConstructorParams({
            networkName: SubnetID({root: ROOTNET_CHAINID, route: new address[](0)}),
            bottomUpCheckPeriod: DEFAULT_CHECKPOINT_PERIOD,
            msgFee: CROSS_MSG_FEE,
            minCollateral: DEFAULT_MIN_VALIDATOR_STAKE,
            majorityPercentage: DEFAULT_MAJORITY_PERCENTAGE,
            activeValidatorsLimit: 4,
            genesisValidators: new Validator[](0)
        });

        gatewayDiamond = createGatewayDiamond(gwConstructorParams);

        gwGetter = GatewayGetterFacet(address(gatewayDiamond));
        gwManager = GatewayManagerFacet(address(gatewayDiamond));
        gwRouter = GatewayRouterFacet(address(gatewayDiamond));
        gwMessenger = GatewayMessengerFacet(address(gatewayDiamond));

        gatewayAddress = address(gatewayDiamond);

        _assertDeploySubnetActor(
            gatewayAddress,
            ConsensusType.Fendermint,
            DEFAULT_MIN_VALIDATOR_STAKE,
            DEFAULT_MIN_VALIDATORS,
            DEFAULT_CHECKPOINT_PERIOD,
            DEFAULT_MAJORITY_PERCENTAGE
        );
    }

    function testSubnetActorDiamondReal_LoupeFunction() public view {
        require(louper.facets().length == 4, "unexpected length");
        require(louper.supportsInterface(type(IERC165).interfaceId) == true, "IERC165 not supported");
        require(louper.supportsInterface(type(IDiamondCut).interfaceId) == true, "IDiamondCut not supported");
        require(louper.supportsInterface(type(IDiamondLoupe).interfaceId) == true, "IDiamondLoupe not supported");
    }

    /// @notice Testing the basic join, stake, leave lifecycle of validators
    function testSubnetActorDiamond_BasicLifeCycle() public {
        (address validator1, uint256 privKey1, bytes memory publicKey1) = TestUtils.newValidator(100);
        (address validator2, uint256 privKey2, bytes memory publicKey2) = TestUtils.newValidator(101);

        // total collateral in the gateway
        uint256 collateral = 0;
        uint256 stake = 10;
        uint256 validator1Stake = 10 * DEFAULT_MIN_VALIDATOR_STAKE;

        require(!saGetter.isActiveValidator(validator1), "active validator1");
        require(!saGetter.isWaitingValidator(validator1), "waiting validator1");

        require(!saGetter.isActiveValidator(validator2), "active validator2");
        require(!saGetter.isWaitingValidator(validator2), "waiting validator2");

        // ======== Step. Join ======
        // initial validator joins
        vm.deal(validator1, validator1Stake);
        vm.deal(validator2, DEFAULT_MIN_VALIDATOR_STAKE);

        vm.startPrank(validator1);
        saManager.join{value: validator1Stake}(publicKey1);
        collateral = validator1Stake;

        require(gatewayAddress.balance == collateral, "gw balance is incorrect after validator1 joining");

        // collateral confirmed immediately and network boostrapped
        ValidatorInfo memory v = saGetter.getValidator(validator1);
        require(v.totalCollateral == collateral, "total collateral not expected");
        require(v.confirmedCollateral == collateral, "confirmed collateral not equal to collateral");
        require(saGetter.isActiveValidator(validator1), "not active validator 1");
        require(!saGetter.isWaitingValidator(validator1), "waiting validator 1");
        require(!saGetter.isActiveValidator(validator2), "active validator2");
        require(!saGetter.isWaitingValidator(validator2), "waiting validator2");
        TestUtils.ensureBytesEqual(v.metadata, publicKey1);
        require(saGetter.bootstrapped(), "subnet not bootstrapped");
        require(!saGetter.killed(), "subnet killed");
        require(saGetter.genesisValidators().length == 1, "not one validator in genesis");

        (uint64 nextConfigNum, uint64 startConfigNum) = saGetter.getConfigurationNumbers();
        require(nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER, "next config num not 1");
        require(startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER, "start config num not 1");

        vm.stopPrank();

        // subnet bootstrapped and should go through queue
        // second and third validators join
        vm.prank(validator2);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey2);

        // collateral not confirmed yet
        v = saGetter.getValidator(validator2);
        require(gatewayAddress.balance == collateral, "gw balance is incorrect after validator2 joining");
        require(v.totalCollateral == DEFAULT_MIN_VALIDATOR_STAKE, "total collateral not expected");
        require(v.confirmedCollateral == 0, "confirmed collateral not equal to collateral");
        require(saGetter.isActiveValidator(validator1), "not active validator 1");
        require(!saGetter.isWaitingValidator(validator1), "waiting validator 1");
        require(!saGetter.isActiveValidator(validator2), "active validator2");
        require(!saGetter.isWaitingValidator(validator2), "waiting validator2");
        TestUtils.ensureBytesEqual(v.metadata, new bytes(0));

        (nextConfigNum, startConfigNum) = saGetter.getConfigurationNumbers();
        // join will update the metadata, incr by 1
        // join will call deposit, incr by 1
        require(nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 2, "next config num not 3");
        require(startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER, "start config num not 1");
        vm.stopPrank();

        // ======== Step. Confirm join operation ======
        collateral += DEFAULT_MIN_VALIDATOR_STAKE;
        _confirmChange(validator1, privKey1);
        require(gatewayAddress.balance == collateral, "gw balance is incorrect after validator2 joining");

        v = saGetter.getValidator(validator2);
        require(v.totalCollateral == DEFAULT_MIN_VALIDATOR_STAKE, "unexpected total collateral after confirm join");
        require(
            v.confirmedCollateral == DEFAULT_MIN_VALIDATOR_STAKE,
            "unexpected confirmed collateral after confirm join"
        );
        require(saGetter.isActiveValidator(validator1), "not active validator1");
        require(!saGetter.isWaitingValidator(validator1), "waiting validator1");
        require(saGetter.isActiveValidator(validator2), "not active validator2");
        require(!saGetter.isWaitingValidator(validator2), "waiting validator2");

        (nextConfigNum, startConfigNum) = saGetter.getConfigurationNumbers();
        require(
            nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 2,
            "next config num not 3 after confirm join"
        );
        require(
            startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 2,
            "start config num not 3 after confirm join"
        );

        // ======== Step. Stake more ======
        vm.startPrank(validator1);
        vm.deal(validator1, stake);

        saManager.stake{value: stake}();

        v = saGetter.getValidator(validator1);
        require(v.totalCollateral == validator1Stake + stake, "unexpected total collateral after stake");
        require(v.confirmedCollateral == validator1Stake, "unexpected confirmed collateral after stake");
        require(gatewayAddress.balance == collateral, "gw balance is incorrect after validator1 stakes more");

        (nextConfigNum, startConfigNum) = saGetter.getConfigurationNumbers();
        require(nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 3, "next config num not 4 after stake");
        require(startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 2, "start config num not 3 after stake");

        vm.stopPrank();

        // ======== Step. Confirm stake operation ======
        collateral += stake;
        _confirmChange(validator1, privKey1, validator2, privKey2);
        require(gatewayAddress.balance == collateral, "gw balance is incorrect after confirm stake");

        v = saGetter.getValidator(validator1);
        require(v.totalCollateral == validator1Stake + stake, "unexpected total collateral after confirm stake");
        require(
            v.confirmedCollateral == validator1Stake + stake,
            "unexpected confirmed collateral after confirm stake"
        );

        v = saGetter.getValidator(validator2);
        require(v.totalCollateral == DEFAULT_MIN_VALIDATOR_STAKE, "unexpected total collateral after confirm stake");
        require(
            v.confirmedCollateral == DEFAULT_MIN_VALIDATOR_STAKE,
            "unexpected confirmed collateral after confirm stake"
        );

        (nextConfigNum, startConfigNum) = saGetter.getConfigurationNumbers();
        require(
            nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 3,
            "next config num not 4 after confirm stake"
        );
        require(
            startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 3,
            "start config num not 4 after confirm stake"
        );
        require(saGetter.genesisValidators().length == 1, "genesis validators still 1");

        // ======== Step. Leave ======
        vm.startPrank(validator1);
        saManager.leave();

        v = saGetter.getValidator(validator1);
        require(v.totalCollateral == 0, "total collateral not 0 after confirm leave");
        require(v.confirmedCollateral == validator1Stake + stake, "confirmed collateral incorrect after confirm leave");
        require(gatewayAddress.balance == collateral, "gw balance is incorrect after validator 1 leaving");

        (nextConfigNum, startConfigNum) = saGetter.getConfigurationNumbers();
        require(
            nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 4,
            "next config num not 5 after confirm leave"
        );
        require(
            startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 3,
            "start config num not 4 after confirm leave"
        );
        require(saGetter.isActiveValidator(validator1), "not active validator 1");
        require(saGetter.isActiveValidator(validator2), "not active validator 2");

        vm.stopPrank();

        // ======== Step. Confirm leave ======
        _confirmChange(validator1, privKey1);
        collateral -= (validator1Stake + stake);
        require(gatewayAddress.balance == collateral, "gw balance is incorrect after confirming validator 1 leaving");

        v = saGetter.getValidator(validator1);
        require(v.totalCollateral == 0, "total collateral not 0 after confirm leave");
        require(v.confirmedCollateral == 0, "confirmed collateral not 0 after confirm leave");

        (nextConfigNum, startConfigNum) = saGetter.getConfigurationNumbers();
        require(
            nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 4,
            "next config num not 5 after confirm leave"
        );
        require(
            startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER + 4,
            "start config num not 5 after confirm leave"
        );
        require(!saGetter.isActiveValidator(validator1), "active validator 1");
        require(saGetter.isActiveValidator(validator2), "not active validator 2");

        // ======== Step. Claim collateral ======
        uint256 b1 = validator1.balance;
        vm.startPrank(validator1);
        saManager.claim();
        uint256 b2 = validator1.balance;
        require(b2 - b1 == validator1Stake + stake, "collateral not received");
    }

    function testSubnetActorDiamond_LoupeFunction() public view {
        require(louper.facets().length == 4, "unexpected length");
        require(louper.supportsInterface(type(IERC165).interfaceId) == true, "IERC165 not supported");
        require(louper.supportsInterface(type(IDiamondCut).interfaceId) == true, "IDiamondCut not supported");
        require(louper.supportsInterface(type(IDiamondLoupe).interfaceId) == true, "IDiamondLoupe not supported");
    }

    function testSubnetActorDiamond_Deployment_Works(
        address _ipcGatewayAddr,
        uint256 _minActivationCollateral,
        uint64 _minValidators,
        uint64 _checkPeriod,
        uint8 _majorityPercentage
    ) public {
        vm.assume(_minActivationCollateral > DEFAULT_MIN_VALIDATOR_STAKE);
        vm.assume(_checkPeriod > DEFAULT_CHECKPOINT_PERIOD);
        vm.assume(_majorityPercentage > 51);
        vm.assume(_majorityPercentage <= 100);
        vm.assume(_ipcGatewayAddr != address(0));

        _assertDeploySubnetActor(
            _ipcGatewayAddr,
            ConsensusType.Fendermint,
            _minActivationCollateral,
            _minValidators,
            _checkPeriod,
            _majorityPercentage
        );

        SubnetID memory parent = saGetter.getParent();
        require(parent.isRoot(), "parent.isRoot()");

        require(saGetter.bottomUpCheckPeriod() == _checkPeriod, "bottomUpCheckPeriod");
    }

    function testSubnetActorDiamond_Deployments_Fail_GatewayCannotBeZero() public {
        SubnetActorManagerFacet saDupMangerFaucet = new SubnetActorManagerFacet();
        SubnetActorGetterFacet saDupGetterFaucet = new SubnetActorGetterFacet();

        vm.expectRevert(GatewayCannotBeZero.selector);
        createSubnetActorDiamondWithFaucets(
            SubnetActorDiamond.ConstructorParams({
                parentId: SubnetID(ROOTNET_CHAINID, new address[](0)),
                ipcGatewayAddr: address(0),
                consensus: ConsensusType.Fendermint,
                minActivationCollateral: DEFAULT_MIN_VALIDATOR_STAKE,
                minValidators: DEFAULT_MIN_VALIDATORS,
                bottomUpCheckPeriod: DEFAULT_CHECKPOINT_PERIOD,
                majorityPercentage: DEFAULT_MAJORITY_PERCENTAGE,
                activeValidatorsLimit: 100,
                powerScale: 12,
                permissioned: false,
                minCrossMsgFee: CROSS_MSG_FEE
            }),
            address(saDupGetterFaucet),
            address(saDupMangerFaucet)
        );
    }

    function testSubnetActorDiamond_Join_Fail_NotOwnerOfPublicKey() public {
        address validator = vm.addr(100);

        vm.deal(validator, 1 gwei);
        vm.prank(validator);
        vm.expectRevert(NotOwnerOfPublicKey.selector);

        saManager.join{value: 10}(new bytes(65));
    }

    function testSubnetActorDiamond_Join_Fail_InvalidPublicKeyLength() public {
        address validator = vm.addr(100);

        vm.deal(validator, 1 gwei);
        vm.prank(validator);
        vm.expectRevert(InvalidPublicKeyLength.selector);

        saManager.join{value: 10}(new bytes(64));
    }

    function testSubnetActorDiamond_Join_Fail_ZeroColalteral() public {
        (address validator, bytes memory publicKey) = TestUtils.deriveValidatorAddress(100);

        vm.deal(validator, 1 gwei);
        vm.prank(validator);
        vm.expectRevert(CollateralIsZero.selector);

        saManager.join(publicKey);
    }

    function testSubnetActorDiamond_Bootstrap_Node() public {
        (address validator, uint256 privKey, bytes memory publicKey) = TestUtils.newValidator(100);

        vm.deal(validator, DEFAULT_MIN_VALIDATOR_STAKE);
        vm.prank(validator);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey);

        // validator adds empty node
        vm.prank(validator);
        vm.expectRevert(EmptyAddress.selector);
        saManager.addBootstrapNode("");

        // validator adds a node
        vm.prank(validator);
        saManager.addBootstrapNode("1.2.3.4");

        // not-validator adds a node
        vm.prank(vm.addr(200));
        vm.expectRevert(abi.encodeWithSelector(NotValidator.selector, vm.addr(200)));
        saManager.addBootstrapNode("3.4.5.6");

        string[] memory nodes = saGetter.getBootstrapNodes();
        require(nodes.length == 1, "it returns one node");
        require(
            keccak256(abi.encodePacked((nodes[0]))) == keccak256(abi.encodePacked(("1.2.3.4"))),
            "it returns correct address"
        );

        vm.prank(validator);
        saManager.leave();
        _confirmChange(validator, privKey);

        nodes = saGetter.getBootstrapNodes();
        require(nodes.length == 0, "no nodes");
    }

    function testSubnetActorDiamond_Leave_NotValidator() public {
        (address validator, , ) = TestUtils.newValidator(100);

        // non-empty subnet can't be killed
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(NotValidator.selector, validator));
        saManager.leave();
    }

    function testSubnetActorDiamond_Leave() public {
        (address validator1, uint256 privKey1, bytes memory publicKey1) = TestUtils.newValidator(100);
        (address validator2, uint256 privKey2, bytes memory publicKey2) = TestUtils.newValidator(101);
        (address validator3, uint256 privKey3, bytes memory publicKey3) = TestUtils.newValidator(102);

        vm.deal(validator1, DEFAULT_MIN_VALIDATOR_STAKE);
        vm.deal(validator2, DEFAULT_MIN_VALIDATOR_STAKE);
        vm.deal(validator3, DEFAULT_MIN_VALIDATOR_STAKE);

        vm.prank(validator1);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey1);

        vm.prank(validator2);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey2);

        vm.prank(validator3);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey3);

        _confirmChange(validator1, privKey1);

        require(saGetter.isActiveValidator(validator1), "validator 1 is not active");
        require(saGetter.isActiveValidator(validator2), "validator 2 is not active");
        require(saGetter.isActiveValidator(validator3), "validator 3 is not active");

        // non-empty subnet can't be killed
        vm.expectRevert(NotAllValidatorsHaveLeft.selector);
        vm.prank(validator1);
        saManager.kill();

        // validator1 is leaving the subnet
        vm.startPrank(validator1);
        saManager.leave();
        vm.stopPrank();

        _confirmChange(validator2, privKey2, validator3, privKey3);

        require(!saGetter.isActiveValidator(validator1), "validator 1 is active");
        require(saGetter.isActiveValidator(validator2), "validator 2 is not active");
        require(saGetter.isActiveValidator(validator3), "validator 3 is not active");

        // TODO:
        // if https://github.com/consensus-shipyard/ipc-solidity-actors/issues/311 is resolved
        // then implement a test for Kill and finish this one
        /*
        vm.prank(validator2);
        saManager.leave();

        // anyone can kill a subnet
        vm.startPrank(vm.addr(300));
        saManager.kill();
        */
    }

    function testSubnetActorDiamond_Stake() public {
        (address validator, bytes memory publicKey) = TestUtils.deriveValidatorAddress(100);
        vm.deal(validator, 10 gwei);

        vm.prank(validator);
        vm.expectRevert(CollateralIsZero.selector);
        saManager.stake();

        vm.prank(validator);
        vm.expectRevert(NotStakedBefore.selector);
        saManager.stake{value: 10}();

        vm.prank(validator);
        saManager.join{value: 3}(publicKey);

        ValidatorInfo memory info = saGetter.getValidator(validator);
        require(info.totalCollateral == 3);
    }

    function testSubnetActorDiamond_crossMsgGetter() public view {
        CrossMsg[] memory msgs = new CrossMsg[](1);
        msgs[0] = CrossMsg({
            message: StorableMsg({
                from: IPCAddress({subnetId: saGetter.getParent(), rawAddress: FvmAddressHelper.from(address(this))}),
                to: IPCAddress({subnetId: saGetter.getParent(), rawAddress: FvmAddressHelper.from(address(this))}),
                value: CROSS_MSG_FEE + 1,
                nonce: 0,
                method: METHOD_SEND,
                params: new bytes(0),
                fee: CROSS_MSG_FEE
            }),
            wrapped: false
        });
        require(saGetter.crossMsgsHash(msgs) == keccak256(abi.encode(msgs)));
    }

    function testSubnetActorDiamond_validateActiveQuorumSignatures() public {
        (uint256[] memory keys, address[] memory validators, ) = TestUtils.getThreeValidators(vm);

        bytes[] memory pubKeys = new bytes[](3);
        bytes[] memory signatures = new bytes[](3);

        bytes32 hash = keccak256(abi.encodePacked("test"));

        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures[i] = abi.encodePacked(r, s, v);
            pubKeys[i] = TestUtils.deriveValidatorPubKeyBytes(keys[i]);
            vm.deal(validators[i], 10 gwei);
            vm.prank(validators[i]);
            saManager.join{value: 10}(pubKeys[i]);
        }

        saManager.validateActiveQuorumSignatures(validators, hash, signatures);
    }

    function testSubnetActorDiamond_validateActiveQuorumSignatures_InvalidSignature() public {
        (uint256[] memory keys, address[] memory validators, ) = TestUtils.getThreeValidators(vm);
        bytes[] memory pubKeys = new bytes[](3);
        bytes[] memory signatures = new bytes[](3);

        bytes32 hash = keccak256(abi.encodePacked("test"));
        bytes32 hash0 = keccak256(abi.encodePacked("test1"));

        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures[i] = abi.encodePacked(r, s, v);
            pubKeys[i] = TestUtils.deriveValidatorPubKeyBytes(keys[i]);
            vm.deal(validators[i], 10 gwei);
            vm.prank(validators[i]);
            saManager.join{value: 10}(pubKeys[i]);
        }

        vm.expectRevert(abi.encodeWithSelector(InvalidSignatureErr.selector, 4));
        saManager.validateActiveQuorumSignatures(validators, hash0, signatures);
    }

    function testSubnetActorDiamond_submitCheckpoint_basic() public {
        (uint256[] memory keys, address[] memory validators, ) = TestUtils.getThreeValidators(vm);
        bytes[] memory pubKeys = new bytes[](3);
        bytes[] memory signatures = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            vm.deal(validators[i], 10 gwei);
            pubKeys[i] = TestUtils.deriveValidatorPubKeyBytes(keys[i]);
            vm.prank(validators[i]);
            saManager.join{value: 10}(pubKeys[i]);
        }

        CrossMsg memory crossMsg = CrossMsg({
            message: StorableMsg({
                from: IPCAddress({
                    subnetId: saGetter.getParent(),
                    rawAddress: FvmAddressHelper.from(address(saDiamond))
                }),
                to: IPCAddress({subnetId: saGetter.getParent(), rawAddress: FvmAddressHelper.from(address(saDiamond))}),
                value: CROSS_MSG_FEE + 1,
                nonce: 0,
                method: METHOD_SEND,
                params: new bytes(0),
                fee: CROSS_MSG_FEE
            }),
            wrapped: false
        });
        CrossMsg[] memory msgs = new CrossMsg[](1);
        msgs[0] = crossMsg;

        BottomUpCheckpoint memory checkpoint = BottomUpCheckpoint({
            subnetID: saGetter.getParent().createSubnetId(address(saDiamond)),
            blockHeight: saGetter.bottomUpCheckPeriod(),
            blockHash: keccak256("block1"),
            nextConfigurationNumber: 0,
            crossMessagesHash: keccak256(abi.encode(msgs))
        });

        BottomUpCheckpoint memory checkpointWithIncorrectHeight = BottomUpCheckpoint({
            subnetID: saGetter.getParent(),
            blockHeight: 1,
            blockHash: keccak256("block1"),
            nextConfigurationNumber: 0,
            crossMessagesHash: keccak256(abi.encode(msgs))
        });

        BottomUpCheckpoint memory checkpointWithIncorrectHash = BottomUpCheckpoint({
            subnetID: saGetter.getParent(),
            blockHeight: saGetter.bottomUpCheckPeriod(),
            blockHash: keccak256("block1"),
            nextConfigurationNumber: 0,
            crossMessagesHash: keccak256(abi.encode("1"))
        });

        vm.deal(address(saDiamond), 100 ether);
        vm.prank(address(saDiamond));
        gwManager.register{value: DEFAULT_MIN_VALIDATOR_STAKE + 3 * CROSS_MSG_FEE}(3 * CROSS_MSG_FEE);

        bytes32 hash = keccak256(abi.encode(checkpoint));

        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        vm.expectRevert(InvalidCheckpointEpoch.selector);
        vm.prank(validators[0]);
        saManager.submitCheckpoint(checkpointWithIncorrectHeight, msgs, validators, signatures);

        vm.expectRevert(InvalidCheckpointMessagesHash.selector);
        vm.prank(validators[0]);
        saManager.submitCheckpoint(checkpointWithIncorrectHash, msgs, validators, signatures);

        vm.expectCall(gatewayAddress, abi.encodeCall(IGateway.commitBottomUpCheckpoint, (checkpoint, msgs)), 1);
        vm.prank(validators[0]);
        saManager.submitCheckpoint(checkpoint, msgs, validators, signatures);

        require(saGetter.hasSubmittedInLastBottomUpCheckpointHeight(validators[0]), "validator rewarded");
        require(
            saGetter.lastBottomUpCheckpointHeight() == saGetter.bottomUpCheckPeriod(),
            " checkpoint height correct"
        );

        vm.prank(validators[0]);
        saManager.submitCheckpoint(checkpoint, msgs, validators, signatures);
        require(saGetter.hasSubmittedInLastBottomUpCheckpointHeight(validators[0]), "validator rewarded");
        require(
            saGetter.lastBottomUpCheckpointHeight() == saGetter.bottomUpCheckPeriod(),
            " checkpoint height correct"
        );

        (bool exists, BottomUpCheckpoint memory recvCheckpoint) = saGetter.bottomUpCheckpointAtEpoch(
            saGetter.bottomUpCheckPeriod()
        );
        require(exists, "checkpoint does not exist");
        require(hash == keccak256(abi.encode(recvCheckpoint)), "checkpoint hashes are not the same");

        bytes32 recvHash;
        (exists, recvHash) = saGetter.bottomUpCheckpointHashAtEpoch(saGetter.bottomUpCheckPeriod());
        require(exists, "checkpoint does not exist");
        require(hash == recvHash, "hashes are not the same");
    }

    function testSubnetActorDiamond_submitCheckpointWithReward() public {
        (uint256[] memory keys, address[] memory validators, ) = TestUtils.getThreeValidators(vm);
        bytes[] memory pubKeys = new bytes[](3);
        bytes[] memory signatures = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            vm.deal(validators[i], 10 gwei);
            pubKeys[i] = TestUtils.deriveValidatorPubKeyBytes(keys[i]);
            vm.prank(validators[i]);
            saManager.join{value: 10}(pubKeys[i]);
        }

        // send the first checkpoint
        CrossMsg memory crossMsg = CrossMsg({
            message: StorableMsg({
                from: IPCAddress({
                    subnetId: saGetter.getParent(),
                    rawAddress: FvmAddressHelper.from(address(saDiamond))
                }),
                to: IPCAddress({subnetId: saGetter.getParent(), rawAddress: FvmAddressHelper.from(address(saDiamond))}),
                value: CROSS_MSG_FEE + 1,
                nonce: 0,
                method: METHOD_SEND,
                params: new bytes(0),
                fee: CROSS_MSG_FEE
            }),
            wrapped: false
        });
        CrossMsg[] memory msgs = new CrossMsg[](1);
        msgs[0] = crossMsg;

        BottomUpCheckpoint memory checkpoint = BottomUpCheckpoint({
            subnetID: saGetter.getParent().createSubnetId(address(saDiamond)),
            blockHeight: saGetter.bottomUpCheckPeriod(),
            blockHash: keccak256("block1"),
            nextConfigurationNumber: 0,
            crossMessagesHash: keccak256(abi.encode(msgs))
        });

        vm.deal(address(saDiamond), 100 ether);
        vm.prank(address(saDiamond));
        gwManager.register{value: DEFAULT_MIN_VALIDATOR_STAKE + 6 * CROSS_MSG_FEE}(6 * CROSS_MSG_FEE);

        bytes32 hash = keccak256(abi.encode(checkpoint));

        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        vm.expectCall(gatewayAddress, abi.encodeCall(IGateway.commitBottomUpCheckpoint, (checkpoint, msgs)), 1);
        vm.prank(validators[0]);
        saManager.submitCheckpoint(checkpoint, msgs, validators, signatures);

        require(saGetter.hasSubmittedInLastBottomUpCheckpointHeight(validators[0]), "validator rewarded");
        require(
            saGetter.lastBottomUpCheckpointHeight() == saGetter.bottomUpCheckPeriod(),
            " checkpoint height correct"
        );

        require(saGetter.getRelayerReward(validators[0]) == 0, "there is a reward");

        // send the second checkpoint
        crossMsg = CrossMsg({
            message: StorableMsg({
                from: IPCAddress({
                    subnetId: saGetter.getParent(),
                    rawAddress: FvmAddressHelper.from(address(saDiamond))
                }),
                to: IPCAddress({subnetId: saGetter.getParent(), rawAddress: FvmAddressHelper.from(address(saDiamond))}),
                value: CROSS_MSG_FEE + 1,
                nonce: 1,
                method: METHOD_SEND,
                params: new bytes(0),
                fee: CROSS_MSG_FEE
            }),
            wrapped: false
        });
        msgs[0] = crossMsg;

        checkpoint = BottomUpCheckpoint({
            subnetID: saGetter.getParent().createSubnetId(address(saDiamond)),
            blockHeight: 2 * saGetter.bottomUpCheckPeriod(),
            blockHash: keccak256("block2"),
            nextConfigurationNumber: 0,
            crossMessagesHash: keccak256(abi.encode(msgs))
        });

        hash = keccak256(abi.encode(checkpoint));

        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        vm.prank(validators[0]);
        saManager.submitCheckpoint(checkpoint, msgs, validators, signatures);

        require(saGetter.getRelayerReward(validators[1]) == 0, "unexpected reward");
        require(saGetter.getRelayerReward(validators[2]) == 0, "unexpected reward");
        uint256 validator0Reward = saGetter.getRelayerReward(validators[0]);
        require(validator0Reward == CROSS_MSG_FEE, "there is no reward for validator");

        uint256 b1 = validators[0].balance;
        vm.startPrank(validators[0]);
        saManager.claimRewardForRelayer();
        uint256 b2 = validators[0].balance;
        require(b2 - b1 == validator0Reward, "reward received");
    }

    function testSubnetActorDiamond_DiamondCut() public {
        // add method getNum to subnet actor diamond and assert it can be correctly called
        // replace method getNum and assert it was correctly updated
        // delete method getNum and assert it no longer is callable
        // assert that diamondCut cannot be called by non-owner

        NumberContractFacetSeven ncFacetA = new NumberContractFacetSeven();
        NumberContractFacetEight ncFacetB = new NumberContractFacetEight();

        DiamondCutFacet saDiamondCutter = DiamondCutFacet(address(saDiamond));
        IDiamond.FacetCut[] memory saDiamondCut = new IDiamond.FacetCut[](1);
        bytes4[] memory ncGetterSelectors = TestUtils.generateSelectors(vm, "NumberContractFacetSeven");

        saDiamondCut[0] = (
            IDiamond.FacetCut({
                facetAddress: address(ncFacetA),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: ncGetterSelectors
            })
        );
        //test that other user cannot call diamondcut to add function
        vm.prank(0x1234567890123456789012345678901234567890);
        vm.expectRevert(LibDiamond.NotOwner.selector);
        saDiamondCutter.diamondCut(saDiamondCut, address(0), new bytes(0));

        saDiamondCutter.diamondCut(saDiamondCut, address(0), new bytes(0));

        NumberContractFacetSeven saNumberContract = NumberContractFacetSeven(address(saDiamond));
        assert(saNumberContract.getNum() == 7);

        ncGetterSelectors = TestUtils.generateSelectors(vm, "NumberContractFacetEight");
        saDiamondCut[0] = (
            IDiamond.FacetCut({
                facetAddress: address(ncFacetB),
                action: IDiamond.FacetCutAction.Replace,
                functionSelectors: ncGetterSelectors
            })
        );

        //test that other user cannot call diamondcut to replace function
        vm.prank(0x1234567890123456789012345678901234567890);
        vm.expectRevert(LibDiamond.NotOwner.selector);
        saDiamondCutter.diamondCut(saDiamondCut, address(0), new bytes(0));

        saDiamondCutter.diamondCut(saDiamondCut, address(0), new bytes(0));

        assert(saNumberContract.getNum() == 8);

        //remove facet for getNum
        saDiamondCut[0] = (
            IDiamond.FacetCut({
                facetAddress: 0x0000000000000000000000000000000000000000,
                action: IDiamond.FacetCutAction.Remove,
                functionSelectors: ncGetterSelectors
            })
        );

        //test that other user cannot call diamondcut to remove function
        vm.prank(0x1234567890123456789012345678901234567890);
        vm.expectRevert(LibDiamond.NotOwner.selector);
        saDiamondCutter.diamondCut(saDiamondCut, address(0), new bytes(0));

        saDiamondCutter.diamondCut(saDiamondCut, address(0), new bytes(0));

        //assert that calling getNum fails
        vm.expectRevert(abi.encodePacked(FunctionNotFound.selector, ncGetterSelectors));
        saNumberContract.getNum();
    }

    function testSubnetActorDiamond_Unstake() public {
        (address validator, bytes memory publicKey) = TestUtils.deriveValidatorAddress(100);

        vm.expectRevert(CannotReleaseZero.selector);
        vm.prank(validator);
        saManager.unstake(0);

        vm.expectRevert(abi.encodeWithSelector(NotValidator.selector, validator));
        vm.prank(validator);
        saManager.unstake(10);

        vm.deal(validator, DEFAULT_MIN_VALIDATOR_STAKE);
        vm.prank(validator);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey);
        require(
            saGetter.getValidator(validator).totalCollateral == DEFAULT_MIN_VALIDATOR_STAKE,
            "initial collateral correct"
        );

        vm.expectRevert(NotEnoughCollateral.selector);
        vm.prank(validator);
        saManager.unstake(DEFAULT_MIN_VALIDATOR_STAKE + 100);

        vm.expectRevert(NotEnoughCollateral.selector);
        vm.prank(validator);
        saManager.unstake(DEFAULT_MIN_VALIDATOR_STAKE);

        vm.prank(validator);
        saManager.unstake(5);
        require(
            saGetter.getValidator(validator).totalCollateral == DEFAULT_MIN_VALIDATOR_STAKE - 5,
            "collateral correct after unstaking"
        );
    }

    function testSubnetActorDiamondReal_PreFundRelease_works() public {
        (address validator1, bytes memory publicKey1) = TestUtils.deriveValidatorAddress(100);
        address preFunder = address(102);
        address preReleaser = address(103);

        // total collateral in the gateway
        uint256 collateral = 0;
        uint256 fundAmount = 100;

        require(!saGetter.isActiveValidator(validator1), "active validator1");
        require(!saGetter.isWaitingValidator(validator1), "waiting validator1");

        // ======== Step. Join ======

        // pre-fund and pre-release from same address
        vm.startPrank(preReleaser);
        vm.deal(preReleaser, 2 * fundAmount);
        saManager.preFund{value: 2 * fundAmount}();
        require(saGetter.genesisCircSupply() == 2 * fundAmount, "genesis circ supply not correct");
        saManager.preRelease(fundAmount);
        require(saGetter.genesisCircSupply() == fundAmount, "genesis circ supply not correct");
        (address[] memory genesisAddrs, ) = saGetter.genesisBalances();
        require(genesisAddrs.length == 1, "not one genesis addresses");
        // cannot release more than the initial balance of the address
        vm.expectRevert(NotEnoughBalance.selector);
        saManager.preRelease(2 * fundAmount);
        // release all
        saManager.preRelease(fundAmount);
        (genesisAddrs, ) = saGetter.genesisBalances();
        require(saGetter.genesisCircSupply() == 0, "genesis circ supply not correct");
        require(genesisAddrs.length == 0, "not zero genesis addresses");

        // pre-fund from validator and from pre-funder
        vm.startPrank(validator1);
        vm.deal(validator1, fundAmount);
        saManager.preFund{value: fundAmount}();
        vm.startPrank(preFunder);
        vm.deal(preFunder, fundAmount);
        saManager.preFund{value: fundAmount}();

        // initial validator joins
        vm.deal(validator1, DEFAULT_MIN_VALIDATOR_STAKE);

        vm.startPrank(validator1);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey1);
        collateral = DEFAULT_MIN_VALIDATOR_STAKE;

        require(
            gatewayAddress.balance == collateral + 2 * fundAmount,
            "gw balance is incorrect after validator1 joining"
        );

        require(saGetter.genesisCircSupply() == 2 * fundAmount, "genesis circ supply not correct");
        (genesisAddrs, ) = saGetter.genesisBalances();
        require(genesisAddrs.length == 2, "not two genesis addresses");

        // collateral confirmed immediately and network boostrapped
        ValidatorInfo memory v = saGetter.getValidator(validator1);
        require(v.totalCollateral == DEFAULT_MIN_VALIDATOR_STAKE, "total collateral not expected");
        require(v.confirmedCollateral == DEFAULT_MIN_VALIDATOR_STAKE, "confirmed collateral not equal to collateral");
        require(saGetter.isActiveValidator(validator1), "not active validator 1");
        require(!saGetter.isWaitingValidator(validator1), "waiting validator 1");
        TestUtils.ensureBytesEqual(v.metadata, publicKey1);
        require(saGetter.bootstrapped(), "subnet not bootstrapped");
        require(!saGetter.killed(), "subnet killed");
        require(saGetter.genesisValidators().length == 1, "not one validator in genesis");

        (uint64 nextConfigNum, uint64 startConfigNum) = saGetter.getConfigurationNumbers();
        require(nextConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER, "next config num not 1");
        require(startConfigNum == LibStaking.INITIAL_CONFIGURATION_NUMBER, "start config num not 1");

        // pre-fund not allowed with bootstrapped subnet
        vm.startPrank(preFunder);
        vm.expectRevert(SubnetAlreadyBootstrapped.selector);
        vm.deal(preFunder, fundAmount);
        saManager.preFund{value: fundAmount}();

        vm.stopPrank();
    }

    function testSubnetActorDiamondReal_PreFundAndLeave_works() public {
        (address validator1, bytes memory publicKey1) = TestUtils.deriveValidatorAddress(100);

        // total collateral in the gateway
        uint256 collateral = DEFAULT_MIN_VALIDATOR_STAKE - 100;
        uint256 fundAmount = 100;

        // pre-fund from validator
        vm.startPrank(validator1);
        vm.deal(validator1, fundAmount);
        saManager.preFund{value: fundAmount}();

        // initial validator joins but doesn't bootstrap the subnet
        vm.deal(validator1, collateral);
        vm.startPrank(validator1);
        saManager.join{value: collateral}(publicKey1);
        require(
            address(saDiamond).balance == collateral + fundAmount,
            "subnet balance is incorrect after validator1 joining"
        );
        require(saGetter.genesisCircSupply() == fundAmount, "genesis circ supply not correct");
        (address[] memory genesisAddrs, ) = saGetter.genesisBalances();
        require(genesisAddrs.length == 1, "not one genesis addresses");

        // Leave should return the collateral and the initial balance
        saManager.leave();
        require(address(saDiamond).balance == 0, "subnet balance is incorrect after validator1 leaving");
        require(saGetter.genesisCircSupply() == 0, "genesis circ supply not zero");
        (genesisAddrs, ) = saGetter.genesisBalances();
        require(genesisAddrs.length == 0, "not zero genesis addresses");

        // initial validator joins to bootstrap the subnet
        vm.deal(validator1, DEFAULT_MIN_VALIDATOR_STAKE);

        vm.startPrank(validator1);
        saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKey1);

        // pre-release not allowed with bootstrapped subnet
        vm.startPrank(validator1);
        vm.expectRevert(SubnetAlreadyBootstrapped.selector);
        saManager.preRelease(fundAmount);

        vm.stopPrank();
    }

    function _assertDeploySubnetActor(
        address _ipcGatewayAddr,
        ConsensusType _consensus,
        uint256 _minActivationCollateral,
        uint64 _minValidators,
        uint64 _checkPeriod,
        uint8 _majorityPercentage
    ) public {
        SubnetID memory _parentId = SubnetID(ROOTNET_CHAINID, new address[](0));

        saManager = new SubnetActorManagerFacet();
        saGetter = new SubnetActorGetterFacet();
        cutFacet = new DiamondCutFacet();
        louper = new DiamondLoupeFacet();

        IDiamond.FacetCut[] memory diamondCut = new IDiamond.FacetCut[](4);

        diamondCut[0] = (
            IDiamond.FacetCut({
                facetAddress: address(saManager),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: saManagerSelectors
            })
        );

        diamondCut[1] = (
            IDiamond.FacetCut({
                facetAddress: address(saGetter),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: saGetterSelectors
            })
        );

        diamondCut[2] = (
            IDiamond.FacetCut({
                facetAddress: address(cutFacet),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: cutFacetSelectors
            })
        );

        diamondCut[3] = (
            IDiamond.FacetCut({
                facetAddress: address(louper),
                action: IDiamond.FacetCutAction.Add,
                functionSelectors: louperSelectors
            })
        );

        saDiamond = new SubnetActorDiamond(
            diamondCut,
            SubnetActorDiamond.ConstructorParams({
                parentId: _parentId,
                ipcGatewayAddr: _ipcGatewayAddr,
                consensus: _consensus,
                minActivationCollateral: _minActivationCollateral,
                minValidators: _minValidators,
                bottomUpCheckPeriod: _checkPeriod,
                majorityPercentage: _majorityPercentage,
                activeValidatorsLimit: 100,
                powerScale: 12,
                permissioned: false,
                minCrossMsgFee: CROSS_MSG_FEE
            })
        );

        saManager = SubnetActorManagerFacet(address(saDiamond));
        saGetter = SubnetActorGetterFacet(address(saDiamond));
        cutFacet = DiamondCutFacet(address(saDiamond));
        louper = DiamondLoupeFacet(address(saDiamond));

        require(saGetter.ipcGatewayAddr() == _ipcGatewayAddr, "saGetter.ipcGatewayAddr() == _ipcGatewayAddr");
        require(
            saGetter.minActivationCollateral() == _minActivationCollateral,
            "saGetter.minActivationCollateral() == _minActivationCollateral"
        );
        require(saGetter.minValidators() == _minValidators, "saGetter.minValidators() == _minValidators");
        require(saGetter.consensus() == _consensus, "consensus");
        require(saGetter.getParent().equals(_parentId), "parent");
        require(saGetter.activeValidatorsLimit() == 100, "activeValidatorsLimit");
        require(saGetter.powerScale() == 12, "powerscale");
        require(saGetter.minCrossMsgFee() == CROSS_MSG_FEE, "cross-msg fee");
        require(saGetter.bottomUpCheckPeriod() == _checkPeriod, "bottom-up period");
        require(saGetter.majorityPercentage() == _majorityPercentage, "majority percentage");
        require(
            saGetter.getParent().toHash() == _parentId.toHash(),
            "parent.toHash() == SubnetID({root: ROOTNET_CHAINID, route: path}).toHash()"
        );
    }

    function _confirmChange(address validator, uint256 privKey) internal {
        address[] memory validators = new address[](1);
        validators[0] = validator;

        uint256[] memory privKeys = new uint256[](1);
        privKeys[0] = privKey;

        _confirmChange(validators, privKeys);
    }

    function _confirmChange(address validator1, uint256 privKey1, address validator2, uint256 privKey2) internal {
        address[] memory validators = new address[](2);
        validators[0] = validator1;
        validators[1] = validator2;

        uint256[] memory privKeys = new uint256[](2);
        privKeys[0] = privKey1;
        privKeys[1] = privKey2;

        _confirmChange(validators, privKeys);
    }

    function _confirmChange(
        address validator1,
        uint256 privKey1,
        address validator2,
        uint256 privKey2,
        address validator3,
        uint256 privKey3
    ) internal {
        address[] memory validators = new address[](3);
        validators[0] = validator1;
        validators[1] = validator2;
        validators[2] = validator3;

        uint256[] memory privKeys = new uint256[](3);
        privKeys[0] = privKey1;
        privKeys[1] = privKey2;
        privKeys[2] = privKey3;

        _confirmChange(validators, privKeys);
    }

    function _confirmChange(address[] memory validators, uint256[] memory privKeys) internal {
        uint256 n = validators.length;

        bytes[] memory signatures = new bytes[](n);

        CrossMsg[] memory msgs = new CrossMsg[](0);

        (uint64 nextConfigNum, ) = saGetter.getConfigurationNumbers();

        uint64 h = saGetter.lastBottomUpCheckpointHeight() + saGetter.bottomUpCheckPeriod();

        BottomUpCheckpoint memory checkpoint = BottomUpCheckpoint({
            subnetID: saGetter.getParent().createSubnetId(address(saDiamond)),
            blockHeight: h,
            blockHash: keccak256(abi.encode(h)),
            nextConfigurationNumber: nextConfigNum - 1,
            crossMessagesHash: keccak256(abi.encode(msgs))
        });

        vm.deal(address(saDiamond), 100 ether);

        bytes32 hash = keccak256(abi.encode(checkpoint));

        for (uint256 i = 0; i < n; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKeys[i], hash);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        for (uint256 i = 0; i < n; i++) {
            vm.prank(validators[i]);
            saManager.submitCheckpoint(checkpoint, msgs, validators, signatures);
        }
    }

    function testSubnetActorDiamond_MultipleJoins_Works_GetValidators() public {
        uint256 n = 10;

        (address[] memory validators, uint256[] memory privKeys, bytes[] memory publicKeys) = TestUtils.newValidators(
            n
        );

        for (uint i = 0; i < n; i++) {
            vm.deal(validators[i], 100 * DEFAULT_MIN_VALIDATOR_STAKE);
        }

        vm.prank(validators[0]);
        saManager.join{value: 100 * DEFAULT_MIN_VALIDATOR_STAKE}(publicKeys[0]);

        for (uint i = 1; i < n; i++) {
            vm.prank(validators[i]);
            saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE}(publicKeys[i]);
        }

        _confirmChange(validators[0], privKeys[0]);

        for (uint i = 0; i < n; i++) {
            require(saGetter.isActiveValidator(validators[i]), "not active validator");
        }
    }

    function testSubnetActorDiamond_Join_Works_LessThanMinStake() public {
        uint256 n = 10;

        (address[] memory validators, uint256[] memory privKeys, bytes[] memory publicKeys) = TestUtils.newValidators(
            n
        );

        for (uint i = 0; i < n; i++) {
            vm.deal(validators[i], 100 * DEFAULT_MIN_VALIDATOR_STAKE);
        }

        vm.prank(validators[0]);
        saManager.join{value: 100 * DEFAULT_MIN_VALIDATOR_STAKE}(publicKeys[0]);

        for (uint i = 1; i < n; i++) {
            vm.prank(validators[i]);
            saManager.join{value: DEFAULT_MIN_VALIDATOR_STAKE - 1}(publicKeys[i]);
        }

        _confirmChange(validators[0], privKeys[0]);

        for (uint i = 0; i < n; i++) {
            require(saGetter.isActiveValidator(validators[i]), "not active validator");
        }
    }

    function testSubnetActorDiamond_Join_Works_WithMinimalStake() public {
        uint256 n = 10;

        (address[] memory validators, uint256[] memory privKeys, bytes[] memory publicKeys) = TestUtils.newValidators(
            n
        );

        vm.deal(validators[0], 100 * DEFAULT_MIN_VALIDATOR_STAKE);
        for (uint i = 1; i < n; i++) {
            vm.deal(validators[i], 1);
        }

        vm.prank(validators[0]);
        saManager.join{value: 100 * DEFAULT_MIN_VALIDATOR_STAKE}(publicKeys[0]);

        for (uint i = 1; i < n; i++) {
            vm.prank(validators[i]);
            saManager.join{value: 1}(publicKeys[i]);
        }

        _confirmChange(validators[0], privKeys[0]);

        for (uint i = 0; i < n; i++) {
            require(saGetter.isActiveValidator(validators[i]), "not active validator");
        }
    }

    function testSubnetActorDiamond_NotBootstrapped_LessThanActivation() public {
        uint256 n = 10;

        (address[] memory validators, uint256[] memory privKeys, bytes[] memory publicKeys) = TestUtils.newValidators(
            n
        );

        for (uint i = 0; i < n; i++) {
            vm.deal(validators[i], 1);
            vm.prank(validators[i]);
            saManager.join{value: 1}(publicKeys[i]);
        }

        require(!saGetter.bootstrapped());
    }

    function callback() public view {
        // console.log("callback called");
    }
}
