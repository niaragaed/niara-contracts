# CLAUDE.md — niara-contracts

Instruções permanentes para o Claude Code neste repositório. Leia antes de escrever
qualquer código.

Este repositório é **separado** do `niara-site` (o site institucional da Niara). Não
procure nem referencie arquivos daquele projeto a partir daqui.

---

## ⚠️ Contratos financeiros: segurança acima de tudo

Se algo for ambíguo, **pare e pergunte** — não improvise em código que move valor
real. Decisões de design já tomadas (e por quê) estão documentadas no README.md,
seção "Decisões de design".

- **Nunca commitar chave privada, `.env` real ou qualquer segredo.** `.env.example`
  existe só para documentar o formato; preencher valores reais fica local, fora do
  git.
- **Nenhum deploy em nenhuma rede sem pedido explícito do usuário** — nem testnet, nem
  mainnet. Este repositório, por enquanto, é só código e testes locais (`forge build`
  / `forge test`).
- **Toda função pública/externa precisa de teste.** Se adicionar uma função nova sem
  teste correspondente, o trabalho não está pronto.
- **Mint sem atestação de lastro é proibido por invariante estrutural**, não por
  controle de acesso: `AssetToken.mint` verifica `totalSupply() + amount <=
  IBackingGateway(backingGateway).totalAttested(address(this))` diretamente, mesmo
  que `MINTER_ROLE` seja concedido a um endereço fora do `BackingGateway`. Qualquer
  mudança nessa função exige o teste de invariante correspondente continuar passando
  (`test_Invariant_MintBeyondAttestedIsImpossibleRegardlessOfCaller` em
  `test/BackingGateway.t.sol`, e os testes de `test/AssetToken.t.sol`).
- **Nunca remover ou enfraquecer `nonReentrant`, `SafeERC20` ou os teto rígidos de bps**
  (`NiaraSettlement.MAX_FEE_BPS = 100`, `CashbackDistributor.MAX_CASHBACK_BPS =
  10_000`) sem discutir explicitamente com o usuário — são invariantes de segurança
  centrais do modelo, não detalhes de implementação.
- **Mudanças em papéis, taxa, cashback ou carteiras de referência passam pelo timelock**
  (`TimelockedAccessControl`: propose → aguardar `timelockDelay` → execute). Não
  adicione atalhos que apliquem essas mudanças imediatamente.

## Tokens com hook: checks-effects-interactions é obrigatório

**Premissa de design:** o protocolo pretende aceitar tokens de pagamento e ativos com
hooks (ERC-777, ERC-1363), não apenas ERC-20 simples. Todo `transfer`,
`transferFrom`, `mint` ou `burn` deve ser tratado como uma chamada externa que pode
devolver o controle a um contrato hostil no meio da operação.

Por causa disso, **checks-effects-interactions é regra obrigatória para qualquer
código novo**: toda atualização de estado *e toda emissão de evento* precede a chamada
externa. Nunca o contrário.

- **`nonReentrant` sozinho não basta.** Ele impede reentrância na mesma função, mas não
  impede reentrância **cruzada** — um hook chamando outra função do contrato durante a
  chamada externa — nem corrige a **ordem dos logs**: com o `emit` depois do transfer,
  um indexador off-chain vê o `Transfer` (ou os eventos da reentrância) antes do evento
  da operação que os originou, quebrando invariantes assumidas fora da cadeia.
- **`nonReentrant` é sempre o primeiro modifier**, antes de `onlyRole` e
  `whenNotPaused`. Modifiers executam na ordem declarada; o guard não deve depender da
  ordem dos demais. Isso é verificável: os testes `..._RevertsViaGuard` deliberadamente
  *não* concedem o papel ao contrato hostil, então só passam se o erro observado for
  `ReentrancyGuardReentrantCall` e não `AccessControlUnauthorizedAccount`.

As quatro funções com chamada externa seguem esse padrão, cada uma com comentário no
código explicando o porquê:

- `NiaraSettlement.settle` — `emit Settled` antes dos três `safeTransferFrom`.
- `BackingGateway.mintAttested` — `req.minted = true` e `emit BackingMinted` antes de
  `IAssetToken.mint`.
- `BackingGateway.redemptionAttest` — status `SETTLED`, `proofHash`, a baixa em
  `totalAttested` e `emit RedemptionAttested` antes de `IAssetToken.burn`.
- `BackingGateway.cancelRedemptionRequest` — status `CANCELLED` e
  `emit RedemptionRequestCancelled` antes do `safeTransfer` de devolução.

**Cada uma tem um teste de ordem de logs travando a regressão** (`vm.recordLogs` +
`assertLt` entre o índice do evento e o do primeiro `Transfer`) — não remova nem
enfraqueça esses testes ao mexer nas funções:

- `test_Settle_EmitsSettledBeforeExternalTransfers` (`test/NiaraSettlement.t.sol`)
- `test_MintAttested_EmitsBackingMintedBeforeExternalTransfer`
- `test_RedemptionAttest_EmitsRedemptionAttestedBeforeExternalTransfer`
- `test_CancelRedemptionRequest_EmitsCancelledBeforeExternalTransfer`
  (os três últimos em `test/BackingGateway.t.sol`)

Ao adicionar uma função nova com chamada externa, adicione o teste de ordem
equivalente. Para simular o ativo hostil, use `test/mocks/MaliciousHookToken.sol`, que
**registra** o resultado da reentrância (`reentrantSucceeded` /
`reentrantReturnData`) em vez de abortar — o `MaliciousReentrantToken` mais antigo faz
`require(success)` e reverte a transação inteira, o que serve para provar bloqueio mas
impede inspecionar o estado que a reentrância enxergou.

**Exceção documentada:** em `settle`, `cashbackDistributor.recordFee` continua *depois*
da transferência da taxa, porque o distribuidor contabiliza uma taxa que precisa já
estar em seu saldo. É chamada interna ao protocolo e qualquer falha reverte a transação
inteira, evento incluído. Está comentada no código — se precisar mexer nessa ordem,
discuta antes.

## Parâmetro pendente de definição

`CashbackDistributor.cashbackBps` está em **1000 bps (10% da taxa)**, valor
provisório — ver comentário no código: *"A DEFINIR — 1% da taxa equivale a 0,005% do
volume, provavelmente insuficiente. Ver whitepaper, seção 4."* Não trate esse número
como final; se o usuário pedir para ajustá-lo, é esperado.

---

## Stack

- Foundry (forge/cast/anvil), Solidity `^0.8.24`.
- OpenZeppelin Contracts v5.1.0 (`lib/openzeppelin-contracts`, instalado via zip de
  release, não como submódulo git — não rodar `forge update` nessa lib sem revisar
  antes; não há histórico git dentro dela).
- Remappings em `remappings.txt` e replicados em `foundry.toml`.
- Scripts de deploy em `script/`: `Deploy.s.sol` (fase 1 `run()` deploy+propose, fase 2
  `executeWiring()` após o timelock decorrer de verdade) e `Demo.s.sol` (fluxo completo
  em transações reais). Só usados mediante pedido explícito de deploy — nunca disparar
  `--broadcast` por conta própria; ver seção "Deploy em testnet" do README.

## Convenções

- Comentários de código em português (convenção também usada no `niara-site`).
- NatSpec (`@notice`/`@dev`/`@param`/`@return`) em toda função pública/externa nova.
- Erros customizados (`error X()` + `revert X()`), não `require(cond, "string")`,
  exceto onde já usado por bibliotecas externas (OpenZeppelin).
- Padrão de timelock: `proposeX(...)` agenda (`_scheduleAction`), `executeX(...)`
  consome (`_consumeAction`) e aplica a mudança. O `actionId` é
  `keccak256(abi.encode("NOME_DA_ACAO", ...parâmetros))` — se adicionar uma nova ação
  sensível, siga esse padrão em vez de inventar um novo mecanismo.
- **Cuidado com testes usando `vm.prank` seguido de uma chamada que leia uma constante
  do próprio contrato na mesma linha** (ex.: `token.MINTER_ROLE()` dentro de um
  `abi.encodeWithSelector(...)` logo após `vm.prank`): isso é uma chamada externa que
  consome o prank antes da chamada testada. Sempre resolva papéis (`bytes32`) em
  variáveis antes do prank. Ver comentário no topo de `test/AssetToken.t.sol`.

## Fluxo de trabalho

1. Antes de codar, ler os arquivos envolvidos — não presumir.
2. `forge build` e `forge test -vv` ao final de cada mudança; corrigir o que aparecer.
3. Commit local ao final de cada tarefa, mensagem em português, padrão `feat:` /
   `fix:` / `refactor:` / `chore:` / `test:`.
4. Nunca `--force`, nunca reescrever histórico, nunca push sem ser pedido, nunca criar
   repositório remoto sem ser pedido.
5. Se algo quebrar ou ficar ambíguo: **parar e explicar**, não improvisar.

Identidade Git deste repositório: a mesma configurada localmente pelo usuário (sem
`--global`, sem sobrescrever).

---

## Pendências conhecidas

- Deploy em Sepolia concluído (2026-07-22): as duas fases (`run()` + `executeWiring()`)
  e o `script/Demo.s.sol` já rodaram com `--broadcast` de verdade, com confirmação
  explícita do usuário em cada etapa. Endereços e transações documentados no README,
  seção "Deploy em testnet" / "Transações da demonstração". Qualquer novo deploy
  (redeploy, outra rede) continua exigindo pedido explícito — nunca disparar
  `--broadcast` por conta própria.
- Parâmetro `cashbackBps` (ver acima) — provisório.
- Nenhuma auditoria externa foi feita. Não descrever este código como auditado em
  nenhuma documentação futura.
