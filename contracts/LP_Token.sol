// contracts/Crowns.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.6.7;

import "./openzeppelin/contracts/access/Ownable.sol";
import "./openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./openzeppelin/contracts/math/SafeMath.sol";

/// @author Medet Ahmetson
contract LP_Token is ERC20, Ownable {
    using SafeMath for uint256;

    uint256 private constant _million = 1000000;

    /**
     * @dev Sets the {name} and {symbol} of token.
     * Initializes {decimals} with a default value of 18.
     * Mints all tokens.
     * Transfers ownership to another account. So, the token creator will not be counted as an owner.
     */
    constructor() public ERC20("LP TestGold", "LPT") {
        uint256 supply        = (10 * _million * (10 ** 18));
   
	address newOwner      = 0xC6EF8A96F20d50E347eD9a1C84142D02b1EFedc0;

        _mint(newOwner,       supply);

        transferOwnership(newOwner);
    }
}