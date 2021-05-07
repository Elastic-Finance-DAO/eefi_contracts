// SPDX-License-Identifier: NONE
pragma solidity ^0.7.0;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@balancer-labs/balancer-core-v2/contracts/lib/openzeppelin/ERC20Burnable.sol';

contract EEFIToken is ERC20Burnable, Ownable {
    constructor() 
    ERC20("Amplesense Elastic Finance token", "EEFI")
    Ownable() {
    }

    function mint(address account, uint256 amount) public onlyOwner {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public onlyOwner {
        _burn(account, amount);
    }
}