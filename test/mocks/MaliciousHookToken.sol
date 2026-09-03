// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Token com hook malicioso (estilo ERC-777/ERC-1363) para testes de reentrância
/// cruzada. Ao ser cunhado, queimado ou transferido, chama um alvo configurável com um
/// calldata arbitrário e **registra** o resultado em vez de abortar — diferente de
/// `MaliciousReentrantToken`, que reverte a transação inteira e por isso não permite
/// inspecionar o estado que a reentrância enxergou.
/// @dev Implementa a superfície de `IAssetToken` usada pelo BackingGateway (`mint`/`burn`)
/// sem nenhum controle de acesso: o objetivo é servir de ativo hostil, não de token válido.
contract MaliciousHookToken is ERC20 {
    address public reentrantTarget;
    bytes public reentrantCalldata;

    bool public armedOnMint;
    bool public armedOnBurn;
    bool public armedOnTransferFrom;
    bool public armedOnTransfer;

    /// @notice Verdadeiro se o hook chegou a disparar a chamada reentrante.
    bool public reentered;
    /// @notice Sucesso da chamada reentrante (false se ela reverteu).
    bool public reentrantSucceeded;
    /// @notice Retorno bruto da chamada reentrante — dado de retorno em caso de sucesso,
    /// ou o erro (selector + argumentos) em caso de revert.
    bytes public reentrantReturnData;

    constructor() ERC20("Malicious Hook Token", "EVILHOOK") {}

    /// @notice Arma a reentrância para disparar dentro de `mint`.
    function armOnMint(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnMint = true;
    }

    /// @notice Arma a reentrância para disparar dentro de `burn`.
    function armOnBurn(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnBurn = true;
    }

    /// @notice Arma a reentrância para disparar dentro de `transferFrom`.
    function armOnTransferFrom(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnTransferFrom = true;
    }

    /// @notice Arma a reentrância para disparar dentro de `transfer`.
    function armOnTransfer(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnTransfer = true;
    }

    function mint(address to, uint256 amount) external {
        if (armedOnMint) {
            armedOnMint = false;
            _reenter();
        }
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (armedOnBurn) {
            armedOnBurn = false;
            _reenter();
        }
        _burn(from, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armedOnTransferFrom) {
            armedOnTransferFrom = false;
            _reenter();
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armedOnTransfer) {
            armedOnTransfer = false;
            _reenter();
        }
        return super.transfer(to, amount);
    }

    function _arm(address target, bytes calldata data) internal {
        reentrantTarget = target;
        reentrantCalldata = data;
        reentered = false;
        reentrantSucceeded = false;
        reentrantReturnData = "";
    }

    /// @dev Deliberadamente não propaga a falha: o teste inspeciona o resultado registrado.
    function _reenter() internal {
        reentered = true;
        (bool ok, bytes memory ret) = reentrantTarget.call(reentrantCalldata);
        reentrantSucceeded = ok;
        reentrantReturnData = ret;
    }
}
