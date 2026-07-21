# niara-contracts

Contratos base (Solidity, Foundry) da infraestrutura on-chain da Niara: emissão de
ativos tokenizados com lastro atestado, liquidação atômica entre comprador e vendedor,
e cashback programático ao emissor.

Este repositório é independente do `niara-site` (o site institucional). Aqui não há
frontend — apenas contratos, testes e scripts locais. **Nenhum deploy foi feito em
nenhuma rede.**

---

## Contratos

### `AssetToken.sol`

ERC-20 representando um ativo real tokenizado (ação, ETF, commodity, moeda ou fundo),
com metadados (referência do ativo, classe, país de origem), papéis via
`AccessControl` (MINTER, BURNER, PAUSER, CUSTODIAN, além do admin) e `Pausable` para
emergência.

A invariante central do projeto vive aqui: `mint` só cunha até o total atestado pelo
`BackingGateway` configurado — nunca além. Essa checagem é estrutural (dentro do
próprio `mint`), não apenas uma convenção de controle de acesso.

`issuerWallet` (carteira do emissor, destinatária do cashback) e `backingGateway` só
mudam por proposta+execução com timelock, restrito ao admin.

### `BackingGateway.sol`

Coordena o processo de lastro. **Não executa ordens em bolsa tradicional** — apenas
registra pedidos e atestações; a execução real é responsabilidade de um agente
off-chain autorizado (custodiante).

Fluxo de emissão:

```
requestBacking(asset, quantidade)         [OPERATOR_ROLE]
        │  emite evento consumido por um agente off-chain,
        │  que compra o ativo real no mercado tradicional
        ▼
attestBacking(requestId, proofHash, quantidadeAdquirida)   [CUSTODIAN_ROLE]
        │  só então totalAttested[asset] aumenta
        ▼
mintAttested(requestId, destinatário)     [OPERATOR_ROLE]
        │  chama AssetToken.mint, que reverifica totalSupply <= totalAttested
        ▼
   tokens cunhados
```

Fluxo de resgate (inverso):

```
redemptionRequest(asset, quantidade)      [qualquer detentor]
        │  tokens ficam custodiados no gateway (ainda não queimados)
        ▼
redemptionAttest(requestId, proofHash)    [CUSTODIAN_ROLE]
        │  só então: queima os tokens custodiados e reduz totalAttested
        ▼
   ativo real liberado off-chain
```

> Este contrato NÃO executa ordens em bolsa. Ele registra pedidos e atestações. A
> execução é responsabilidade de agente off-chain autorizado. A recompra de ações
> pela própria companhia emissora é atividade regulada e **não** está implementada
> aqui — o modelo assume aquisição em mercado por um custodiante.

### `NiaraSettlement.sol`

Liquidação atômica: na mesma transação, transfere o `AssetToken` do vendedor ao
comprador, o pagamento (USDT ou WBTC) do comprador ao vendedor, e retém a taxa — na
própria moeda de liquidação, sem swap, sem DEX, sem oráculo. Qualquer falha reverte
tudo. Opera inteiramente por `allowance` — nunca custodia saldo das partes.

Taxa: 50 bps (0,5%) padrão, com teto rígido e imutável em 100 bps (1%) que nem o admin
pode superar. Restrito a `SETTLEMENT_OPERATOR_ROLE` (o motor de casamento de ordens da
Niara) — allowance autoriza o movimento de fundos, mas só o operador autorizado decide
quando disparar uma liquidação.

### `CashbackDistributor.sol`

Recebe a taxa (já transferida pelo `NiaraSettlement`) e credita o emissor em padrão
*pull*: os valores se acumulam por (ativo, moeda de liquidação) e o emissor saca
quando quiser via `withdraw`. Só credita se `AssetToken.cashbackEligible()` for
verdadeiro. O restante da taxa vira receita do protocolo, sacável pela tesouraria.

Parcela de cashback: **1000 bps (10% da taxa) — valor provisório**. Ver comentário no
código: *"A DEFINIR — 1% da taxa equivale a 0,005% do volume, provavelmente
insuficiente. Ver whitepaper, seção 4."*

### `governance/TimelockedAccessControl.sol`

Base de governança herdada por todos os quatro contratos. Qualquer concessão/revogação
de papel, e qualquer parâmetro sensível (taxa, cashback, carteira do emissor, endereço
do `BackingGateway`/`CashbackDistributor`), passa por proposta + execução separadas por
um atraso configurável (padrão usado nos testes: 2 dias; ajustável entre 1 hora e 30
dias). `grantRole`/`revokeRole` diretos do `AccessControl` são desabilitados de
propósito — use `proposeGrantRole`/`executeGrantRole` (e as versões `Revoke`).

Pensada para operar com os papéis administrativos atribuídos a uma carteira multisig
(ex.: Gnosis Safe) — não há lógica de multisig no contrato; qualquer endereço pode ser
titular de um papel.

---

## Decisões de design (documentadas para revisão)

- **CUSTODIAN_ROLE no AssetToken** pode pausar (circuit breaker de emergência ao
  detectar um problema de custódia), mas só PAUSER_ROLE pode despausar — travar é
  unilateral, destravar exige o processo normal de governança.
- **`settle` é restrito a papel**, não permissionless: embora o movimento de fundos
  dependa só de `allowance`, permitir que qualquer chamador escolha os termos entre
  duas partes que aprovaram o contrato seria uma superfície de abuso.
- **Redenção em duas etapas** (`redemptionRequest` custodia, `redemptionAttest` queima):
  os tokens só são destruídos quando a liberação do ativo real é confirmada,
  permitindo cancelar (`cancelRedemptionRequest`) se o processo off-chain falhar.
- **`withdraw` do cashback consulta o `issuerWallet` atual** no momento do saque, não o
  endereço vigente quando a taxa foi registrada — o saldo pertence ao emissor do
  ativo, não a um endereço histórico específico.
- **Pausable em AssetToken, BackingGateway e NiaraSettlement**, não em
  CashbackDistributor — os três primeiros movimentam ativos/lastro; o distribuidor é
  puramente contábil e um circuit breaker ali arriscaria travar saques legítimos do
  emissor sem necessidade.

---

## Como rodar

```bash
forge build
forge test -vv
```

Pré-requisitos: [Foundry](https://book.getfoundry.sh/) instalado (`forge`, `cast`,
`anvil`). Dependências (`forge-std`, `openzeppelin-contracts` v5.1.0) já estão em
`lib/`.

Nenhuma variável de ambiente é necessária para build/test. `.env.example` documenta o
que é necessário para deploy em testnet (ver seção abaixo).

---

## Deploy em testnet (Sepolia)

⚠️ Só Sepolia. Nunca mainnet sem pedido explícito (ver CLAUDE.md). Use sempre uma
carteira **descartável**, criada só para testnet, sem nenhum valor real — a chave
privada fica apenas em `.env` local (já no `.gitignore`; confirme com `git status`
antes de qualquer commit).

### 1. Preparar a carteira e obter ETH de teste

1. Gere uma carteira nova só para isso (`cast wallet new`, MetaMask em modo teste, etc.)
   — nunca reutilize uma carteira com fundos reais.
2. Peça ETH de Sepolia em um faucet, por exemplo:
   - https://sepoliafaucet.com/
   - https://www.alchemy.com/faucets/ethereum-sepolia
   - https://cloud.google.com/application/web3/faucet/ethereum/sepolia
3. Copie `.env.example` para `.env` e preencha `RPC_URL` (um endpoint Sepolia — Alchemy,
   Infura, etc.), `PRIVATE_KEY` (a chave da carteira descartável) e
   `ETHERSCAN_API_KEY` (para a verificação de contrato).

### 2. Deploy em duas fases (por causa do timelock real)

`TimelockedAccessControl.MIN_TIMELOCK_DELAY` é 1 hora — nem em testnet dá para pular
essa espera (ver CLAUDE.md). Por isso o deploy é em duas fases:

**Fase 1 — implanta os contratos e agenda (propose) toda a fiação de papéis:**

```bash
forge script script/Deploy.s.sol --rpc-url sepolia
```

Sempre rode primeiro **sem** `--broadcast` (simulação/dry-run) e confira a saída antes
de transmitir de verdade. Só depois de confirmar, adicione `--broadcast --verify`:

```bash
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
```

A saída lista os endereços implantados (`DEPLOYED_*`) — copie-os para o seu `.env`
local.

**Espere `TIMELOCK_DELAY` segundos** (1 hora por padrão) e então rode a fase 2, que
executa (consome) as propostas da fase 1:

```bash
forge script script/Deploy.s.sol --sig "executeWiring()" --rpc-url sepolia --broadcast
```

### 3. Script de demonstração

Com a fiação concluída, `script/Demo.s.sol` executa o fluxo completo do protocolo em
transações reais: `requestBacking → attestBacking → mintAttested → settle → cashback
creditado → withdraw`. Precisa das mesmas variáveis `DEPLOYED_*` no `.env`:

```bash
forge script script/Demo.s.sol --rpc-url sepolia --broadcast
```

O "comprador" de demonstração é uma conta derivada automaticamente pelo script (não
precisa de uma segunda chave privada) — recebe um pouco de ETH e USDT de teste do
deployer só para aprovar sua própria ponta da liquidação.

### Transações da demonstração (Sepolia)

_A preencher após a primeira execução real de `script/Demo.s.sol` — lista dos
endereços implantados e o link de cada transação no Etherscan, na ordem do fluxo._

---

## Estrutura

```
src/
  governance/
    TimelockedAccessControl.sol
  interfaces/
    IAssetToken.sol
    IBackingGateway.sol
    ICashbackDistributor.sol
  AssetToken.sol
  BackingGateway.sol
  NiaraSettlement.sol
  CashbackDistributor.sol
script/
  Deploy.s.sol   (fase 1: deploy + propose da fiação; fase 2 via --sig "executeWiring()")
  Demo.s.sol     (fluxo completo em transações reais, para demonstração pública)
test/
  mocks/
    MockUSDT.sol                 (6 casas decimais)
    MockWBTC.sol                 (8 casas decimais)
    MockBackingGateway.sol       (totalAttested ajustável, para isolar testes do AssetToken)
    MaliciousReentrantToken.sol  (para testes de reentrância)
    TimelockHarness.sol          (instância concreta mínima de TimelockedAccessControl)
  AssetToken.t.sol
  BackingGateway.t.sol
  NiaraSettlement.t.sol
  CashbackDistributor.t.sol
  TimelockedAccessControl.t.sol
  Integration.t.sol              (fluxo completo: lastro → liquidação → cashback → resgate)
  Invariant.t.sol + invariant/Handler.sol  (fuzzing stateful dos invariantes centrais)
```
