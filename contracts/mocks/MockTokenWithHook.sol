/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title Mock Token with a pre-transfer hook to test token hooks in internal transfers.
 **/
contract MockTokenWithHook is ERC20, ERC20Burnable {
    event InternalTransferTokenHookCalled(address indexed from, address indexed to, uint256 amount);
    event RegularTransferTokenHookCalled(address indexed from, address indexed to, uint256 amount);

    address public protocol;
    uint8 private _decimals = 18;
    string private _symbol = "MOCK";
    string private _name = "MockToken";

    constructor(
        string memory name,
        string memory __symbol,
        address _protocol
    ) ERC20(name, __symbol) {
        protocol = _protocol;
    }

    function _update(address from, address to, uint256 amount) internal override {
        emit RegularTransferTokenHookCalled(from, to, amount);
        super._update(from, to, amount);
    }

    function internalTransferUpdate(address from, address to, uint256 amount) external {
        require(msg.sender == protocol, "MockTokenWithHook: only protocol can call this function");
        emit InternalTransferTokenHookCalled(from, to, amount);
    }

    function mint(address account, uint256 amount) external returns (bool) {
        _mint(account, amount);
        return true;
    }

    function burnFrom(address account, uint256 amount) public override(ERC20Burnable) {
        ERC20Burnable.burnFrom(account, amount);
    }

    function burn(uint256 amount) public override {
        ERC20Burnable.burn(amount);
    }

    function setDecimals(uint256 dec) public {
        _decimals = uint8(dec);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function setSymbol(string memory sym) public {
        _symbol = sym;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function setName(string memory name_) public {
        _name = name_;
    }
}
