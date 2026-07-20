// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Token ERC-20 malicioso para testes: ao ser transferido via `transferFrom`,
/// tenta reentrar em um alvo configurável com um calldata arbitrário, simulando um token
/// com hook (estilo ERC-777) usado como vetor de reentrância. Usado apenas em testes para
/// comprovar que `nonReentrant` bloqueia o ataque.
contract MaliciousReentrantToken is ERC20 {
    address public reentrantTarget;
    bytes public reentrantCalldata;
    bool public armed;

    constructor() ERC20("Malicious Reentrant Token", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arma o ataque: na próxima chamada a `transferFrom`, este contrato chamará
    /// `reentrantTarget` com `data` antes de concluir a transferência.
    function arm(address target, bytes calldata data) external {
        reentrantTarget = target;
        reentrantCalldata = data;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool success,) = reentrantTarget.call(reentrantCalldata);
            require(success, "reentrant call did not revert as expected");
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool success,) = reentrantTarget.call(reentrantCalldata);
            require(success, "reentrant call did not revert as expected");
        }
        return super.transfer(to, amount);
    }
}
