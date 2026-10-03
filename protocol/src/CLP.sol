// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CLP
/// @notice Pool share. Only the Store can mint or burn it, and it can't be transferred, bought or
/// sold: membership in the Collective belongs to the depositor, not to whoever holds a token.
contract CLP is ERC20 {
    address public immutable store;

    error NonTransferable();

    constructor(address _store) ERC20("Blood Magic Collective", "CLP") {
        store = _store;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == store, "!authorized");
        require(amount > 0, "!clp-amount");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == store, "!authorized");
        require(amount > 0, "!clp-amount");
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }
}
