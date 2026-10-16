// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title FactoryList
/// @notice An append-only list of the launch factories a contract serves.
///
/// WHY A LIST AND NOT ONE FACTORY. The hook, the locker, the fee collector and the attestor each
/// used to take ONE factory, once. A new factory -- a new token, a new opening rule -- then meant a
/// new hook at a new mined address, and a hook's address is what routers and hook lists know it by.
/// With a list, a later factory is added to the same contracts and the hook keeps its address.
///
/// WHAT AN ADDED FACTORY CAN AND CANNOT DO. It can open NEW pools and launches, exactly as the first
/// one can. It cannot touch anything that already exists: every pool and launch is recorded once,
/// by the factory that created it, with its fee and rules fixed then, and nothing in these
/// contracts lets a factory -- any factory -- write to a record after it is made. Factories are
/// never removed or replaced, so no launch ever loses the factory it was made by.
///
/// WHO ADDS ONE. `factoryAdmin`, the platform's admin key; no timelock. It starts as the address
/// that deploys the contract, so the deploy can add the first factory in the same run, and the
/// deploy then hands it to the admin (`setFactoryAdmin`). That key can add a factory of its own
/// that opens new pools on its own terms. It is a power over new launches only.
abstract contract FactoryList {
    /// @notice Whether `factory` may act here.
    mapping(address => bool) public isFactory;

    /// @notice Every factory ever added, in order. Never shrinks.
    address[] private _factories;

    /// @notice May add a factory (and, on the hook, name who else may add liquidity).
    address public factoryAdmin;

    event FactoryAdded(address indexed factory, uint256 index);
    event FactoryAdminSet(address indexed previous, address indexed next);

    error ZeroFactory();
    error FactoryAlreadyAdded(address factory);
    error NotFactoryAdmin();
    error ZeroFactoryAdmin();

    modifier onlyFactoryAdmin() {
        if (msg.sender != factoryAdmin) revert NotFactoryAdmin();
        _;
    }

    function _initFactoryAdmin(address admin_) internal {
        if (admin_ == address(0)) revert ZeroFactoryAdmin();
        factoryAdmin = admin_;
        emit FactoryAdminSet(address(0), admin_);
    }

    /// @notice Hand the role to another key. The current admin only.
    function setFactoryAdmin(address next) external onlyFactoryAdmin {
        if (next == address(0)) revert ZeroFactoryAdmin();
        emit FactoryAdminSet(factoryAdmin, next);
        factoryAdmin = next;
    }

    /// @notice Add a factory that may open NEW pools or launches here. Append-only: no factory is
    ///         ever removed or replaced, and none can change a record already made.
    function addFactory(address factory_) external onlyFactoryAdmin {
        _addFactory(factory_);
    }

    function _addFactory(address factory_) internal {
        if (factory_ == address(0)) revert ZeroFactory();
        if (isFactory[factory_]) revert FactoryAlreadyAdded(factory_);
        isFactory[factory_] = true;
        _factories.push(factory_);
        emit FactoryAdded(factory_, _factories.length - 1);
    }

    /// @notice Every factory added, oldest first.
    function factories() external view returns (address[] memory) {
        return _factories;
    }

    function factoryCount() external view returns (uint256) {
        return _factories.length;
    }

    function factoryAt(uint256 index) external view returns (address) {
        return _factories[index];
    }
}
