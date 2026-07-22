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

Execução real de `script/Demo.s.sol` em 2026-07-22. Endereços dos contratos (fase 1 +
fase 2 de deploy):

| Contrato | Endereço |
|---|---|
| MockUSDT | [`0x8737...b112`](https://sepolia.etherscan.io/address/0x87374912f372378f94af3f93b36e06126e53b112#code) |
| MockWBTC | [`0xA202...8bb7`](https://sepolia.etherscan.io/address/0xa202111580a6d9afa3f0f7e48fe49de650528bb7#code) |
| CashbackDistributor | [`0x2A08...A1bE`](https://sepolia.etherscan.io/address/0x2a08c09d10f5d6b15c176241317e9ad20d5da1be#code) |
| NiaraSettlement | [`0xd7DE...D178`](https://sepolia.etherscan.io/address/0xd7deabcac261cbdc9bb898baf8e60da1355bd178#code) |
| BackingGateway | [`0x6C90...835c`](https://sepolia.etherscan.io/address/0x6c90bc018d9fc396093cc0394801f4de175e835c#code) |
| AssetToken (nDEMO) | [`0xcE92...b37f`](https://sepolia.etherscan.io/address/0xce920ba910c1ecb8e767f37933b38520892eb37f#code) |

Vendedor/emissor: `0x8763606AE3C03733AF248cfEF549573e3073101a` (deployer). Comprador:
`0x5E6b075b52684dC3a4d84d13465F02273c05e3eC` (conta derivada automaticamente pelo
script, só para esta demonstração).

Sequência de transações, na ordem em que aconteceram:

| # | Etapa | Transação | Valores |
|---|---|---|---|
| 1 | `requestBacking` | [`0x677d...bfeba`](https://sepolia.etherscan.io/tx/0x677d8911650268013fcfa186fece5efe672b0b6ec079f2347d0771006fabfeba) | Pedido de lastro para 1.000 nDEMO |
| 2 | `attestBacking` | [`0x30dc...ea8033`](https://sepolia.etherscan.io/tx/0x30dc02748869c5f5286d30c54c7382ef95ad803728fdfb8a301a55edcfea8033) | 1.000 nDEMO atestados (custódia confirmada) |
| 3 | `mintAttested` | [`0x7290...da23fb`](https://sepolia.etherscan.io/tx/0x729053bb2d16cfee77e8227f26f4c5cf3e2e20a997ba29545cb8ae3559da23fb) | 1.000 nDEMO cunhados para o vendedor |
| 4 | Funding do comprador (ETH) | [`0x201e...9d5e513`](https://sepolia.etherscan.io/tx/0x201e8bfa9138093dc244a5d3019925199e5059dc7a420615eefe9af6f9d5e513) | 0,01 ETH — só para o comprador pagar seu próprio gás |
| 5 | Funding do comprador (USDT) | [`0xd840...781b1b5`](https://sepolia.etherscan.io/tx/0xd840a3a18250caa7670cdfee4d670eee06de57be02250cc462aa7ec16781b1b5) | `MockUSDT.mint` — 10.000 USDT de demonstração |
| 6 | `approve` (AssetToken, vendedor) | [`0x59b7...e0cae`](https://sepolia.etherscan.io/tx/0x59b7f334df0f24fc62bf3662c575779d898b307578bf86840f3a9e9f336e0cae) | Aprovação de 100 nDEMO para o `NiaraSettlement` |
| 7 | `approve` (USDT, comprador) | [`0x65ff...b522c`](https://sepolia.etherscan.io/tx/0x65fffb2329315038ff1f8c0a207c7a9ade519e21f67933ed952723d49b8b522c) | Aprovação de 10.000 USDT para o `NiaraSettlement` |
| 8 | `settle` | [`0x1e1d...d17b33e`](https://sepolia.etherscan.io/tx/0x1e1ddcc072a7770e9d6e8725b0b6f8a91e129b7b036bc01b22a28d701d17b33e) | 100 nDEMO ↔ 10.000 USDT; **taxa retida: 50 USDT** (0,5%) |
| 9 | `withdraw` (cashback) | [`0x87fd...8e0795a6`](https://sepolia.etherscan.io/tx/0x87fdcf2607af747e9a5256f18b6fb7db2895de942d05b3d6bd4f16a38e0795a6) | Emissor saca **5 USDT** de cashback (10% da taxa de 50 USDT) |

Conferido on-chain após a demo: `cashbackBalance(nDEMO, USDT)` voltou a 0, e o saldo
final de USDT do emissor/vendedor é 9.955 USDT (9.950 do recebimento líquido da venda
+ 5 do cashback sacado) — bate exatamente com o esperado.

---

## Segunda demo: papéis em carteiras distintas (`script/PresentationDemo.s.sol`)

Versão para **apresentação pública**, pensada para deixar explícito que o cashback vai
para um terceiro alheio à negociação — não para o comprador nem para o vendedor.
Diferença central em relação à primeira demo (que continua intacta, documentada acima,
e não foi alterada): lá o mesmo deployer acumulava todos os papéis; aqui **cada papel é
uma carteira própria**:

| Papel | Endereço | Observação |
|---|---|---|
| Admin (deployer / governança) | `0x8763606AE3C03733AF248cfEF549573e3073101a` | o mesmo de sempre — só governança, não participa do fluxo |
| Operador | `0xe37e5C7ee77119CE789f22Df50ccB8ebDFb665eD` | `requestBacking`, `mintAttested`, `settle` |
| Custodiante | `0xD3d3323ce7Bce15A27CA38C12c9C2Cef21020252` | `attestBacking` |
| **Empresa emissora** | `0xf8Eb1CDC6edDE176ee8Dcb57D4BB8Be464e120F8` | `issuerWallet` — recebe e saca o cashback; **não é nem comprador nem vendedor** |
| Vendedor | `0xdF60E0Da8071028BD2C90656848854De5A5B0b7F` | entrega o `AssetToken` na liquidação |
| Comprador | `0xc1051639110730DE92D717d5F0Bd7dC229FAD8AA` | paga na liquidação |

As 5 carteiras de papel são derivadas deterministicamente por rótulo
(`makeAddrAndKey`, sem depender de nenhuma chave privada além da do deployer) e
financiadas com 0,003 ETH cada, só para pagar o próprio gás.

⚠️ **Importante**: este script **reutiliza os mesmos seis contratos já implantados**
pela primeira demo (endereços na seção anterior) — não implanta nada novo. Ele só
**reatribui**, via timelock, `OPERATOR_ROLE`/`CUSTODIAN_ROLE`
(`BackingGateway`)/`SETTLEMENT_OPERATOR_ROLE` (`NiaraSettlement`) para as carteiras
acima — de forma **aditiva**, sem revogar os papéis do deployer original — e **troca o
`issuerWallet`** do `AssetToken` (`nDEMO`) da carteira do deployer para a "empresa
emissora" acima. Essa troca é permanente daqui para frente (o design do contrato prevê
rotação de emissor — ver seção "Decisões de design"): o cashback creditado na primeira
demo já tinha sido sacado antes desta mudança, então nada do histórico documentado
acima é afetado; só o cashback gerado **a partir de agora** vai para a nova empresa
emissora.

### Fase 1 — reatribuição agendada (concluída em 2026-07-22)

| # | Ação | Transação |
|---|---|---|
| 1 | `proposeGrantRole` OPERATOR_ROLE→operador | [`0x32b7...019003`](https://sepolia.etherscan.io/tx/0x32b7bbb76050d21473ef1d6737cb0da84880bba44e8e9a3dd88e3116a4019003) |
| 2 | `proposeGrantRole` CUSTODIAN_ROLE→custodiante | [`0x4faa...2d3db`](https://sepolia.etherscan.io/tx/0x4faa10237506e3f58b7d28b9e27211b288beccc5474004892ab249bed2e2d3db) |
| 3 | `proposeGrantRole` SETTLEMENT_OPERATOR_ROLE→operador | [`0x02d7...c06246`](https://sepolia.etherscan.io/tx/0x02d789f80ed10648faf2c3506870ed3ccd83607042dc3aa9466a0e8f99c06246) |
| 4 | `proposeSetIssuerWallet` → empresa emissora | [`0xee29...160882`](https://sepolia.etherscan.io/tx/0xee299db2fa36beabe9e1d56db589dedb8b53571fb5253cddde09ed3208160882) |
| 5-9 | Financiamento (0,003 ETH cada) das 5 carteiras de papel | [`0xe1f8...9ce62`](https://sepolia.etherscan.io/tx/0xe1f82c0f718169e4f635de78f5e996c78aa1a006336c00f8868edb571c99ce62), [`0x8ab3...c63e75e`](https://sepolia.etherscan.io/tx/0x8ab38a707d803e270395cef88161d58ee448f06a35c383e05c945f730c63e75e), [`0x7750...90a9b8b`](https://sepolia.etherscan.io/tx/0x7750722b0646f091a6454fae5e9604c76acb21e5e5a8f49d0b7c7054390a9b8b), [`0x88a4...9181d1b`](https://sepolia.etherscan.io/tx/0x88a48101086b83297c11978b758bca9db8d6f86ed06aebef0bf4f67359181d1b), [`0xb670...455227`](https://sepolia.etherscan.io/tx/0xb670dee3fa219bd90c4823ea15fd471624354fe4eda9d1a1906395f282455227) |

### Fase 2 — reatribuição executada (concluída em 2026-07-22)

Confirmado on-chain antes de transmitir: `executeAfter` das 4 propostas já havia
decorrido (`1784754288`) em relação ao timestamp do bloco no momento (`1784754612`).
Depois da execução, também confirmado on-chain: os novos papéis foram concedidos, os
papéis antigos do deployer permanecem intactos (reatribuição aditiva, não uma
migração), e `AssetToken.issuerWallet()` passou a apontar para a empresa emissora.

| # | Ação | Transação |
|---|---|---|
| 1 | `executeGrantRole` OPERATOR_ROLE→operador | [`0x205a...3e32c`](https://sepolia.etherscan.io/tx/0x205a98d2c7711913a5310878e2d3db9657e99587ebe63c8122c860382a43e32c) |
| 2 | `executeGrantRole` CUSTODIAN_ROLE→custodiante | [`0x932b...5c7ef5`](https://sepolia.etherscan.io/tx/0x932b45385f16b04d1ef0de0c002017979112e3ee56ce31c04597535c1c5c7ef5) |
| 3 | `executeGrantRole` SETTLEMENT_OPERATOR_ROLE→operador | [`0xc1ed...92c30e3`](https://sepolia.etherscan.io/tx/0xc1ed525034b5c49ecfcebc9dcde40832295899203c495a7315f30de4192c30e3) |
| 4 | `executeSetIssuerWallet` → empresa emissora | [`0x7b76...b3481a6`](https://sepolia.etherscan.io/tx/0x7b76b708331827ae23aa91e82b97ff12d95afca1e71f47cdf1775bb0ab3481a6) |

### Demo

_A preencher depois que `runDemo()` for transmitido._

```bash
forge script script/PresentationDemo.s.sol --sig "runDemo()" --rpc-url sepolia --broadcast
```

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
  Deploy.s.sol           (fase 1: deploy + propose da fiação; fase 2 via --sig "executeWiring()")
  Demo.s.sol             (fluxo completo em transações reais, para demonstração pública)
  PresentationDemo.s.sol (2ª demo: mesmos contratos, papéis em carteiras distintas, para apresentação)
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
