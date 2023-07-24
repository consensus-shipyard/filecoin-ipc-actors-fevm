// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {SubnetActorDiamond} from "./SubnetActorDiamond.sol";
import {IDiamond} from "./interfaces/IDiamond.sol";

contract SubnetRegistry {
    address public immutable gateway;

    /// The getter and manager facet shared by diamond
    address public getterFacet;
    address public managerFacet;

    /// The subnet getter facet functions selectors
    bytes4[] public subnetGetterSelectors;
    /// The subnet manager facet functions selectors
    bytes4[] public subnetManagerSelectors;

    /// @notice Mapping that tracks the deployed subnet actors per user.
    /// Key is the hash of Subnet ID, values are addresses.
    /// mapping owner => nonce => subnet
    mapping(address => mapping(uint64 => address)) public subnets;

    /// @notice Mapping that tracks the latest nonce of the deployed
    /// subnet for each user.
    /// owner => nonce
    mapping(address => uint64) public userNonces;

    /// @notice Event emitted when a new subnet is deployed.
    event SubnetDeployed(address subnetAddr);

    error WrongGateway();
    error ZeroGatewayAddress();
    error UnknownSubnet();

    constructor(
        address _gateway,
        address _getterFacet,
        address _managerFacet,
        bytes4[] memory _subnetGetterSelectors,
        bytes4[] memory _subnetManagerSelectors
    ) {
        gateway = _gateway;

        getterFacet = _getterFacet;
        managerFacet = _managerFacet;

        subnetGetterSelectors = _subnetGetterSelectors;
        subnetManagerSelectors = _subnetManagerSelectors;
    }

    /// @notice Deploys a new subnet actor.
    /// @param _params The constructor params for Subnet Actor Diamond.
    function newSubnetActor(
        SubnetActorDiamond.ConstructorParams calldata _params
    ) external returns (address subnetAddr) {
        if (_params.ipcGatewayAddr != gateway) {
            revert WrongGateway();
        }

        IDiamond.FacetCut[] memory diamondCut = new IDiamond.FacetCut[](2);

        // set the diamond cut for subnet getter
        diamondCut[0] = IDiamond.FacetCut({
            facetAddress: getterFacet,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: subnetGetterSelectors
        });

        // set the diamond cut for subnet manager
        diamondCut[1] = IDiamond.FacetCut({
            facetAddress: managerFacet,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: subnetManagerSelectors
        });

        subnetAddr = address(new SubnetActorDiamond(diamondCut, _params));

        emit SubnetDeployed(subnetAddr);
    }

    /// @notice Returns the address of the latest subnet actor
    /// deployed by a user
    function latestSubnetDeployed(address owner) external view returns (address subnet) {
        subnet = subnets[owner][userNonces[owner] - 1];
        if (subnet == address(0)) {
            revert ZeroGatewayAddress();
        }
    }

    /// @notice Returns the address of a subnet actor deployed for a
    /// specific nonce by a user
    function getSubnetDeployedByNonce(address owner, uint64 nonce) external view returns (address subnet) {
        subnet = subnets[owner][nonce];
        if (subnet == address(0)) {
            revert ZeroGatewayAddress();
        }
    }
}
