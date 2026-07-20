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
- Sem scripts de deploy configurados ainda (`script/` vazio) — criar apenas quando o
  usuário pedir deploy.

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

- Scripts de deploy (`script/`) — a fazer quando houver pedido explícito de deploy em
  testnet (Sepolia, conforme combinado).
- Parâmetro `cashbackBps` (ver acima) — provisório.
- Nenhuma auditoria externa foi feita. Não descrever este código como auditado em
  nenhuma documentação futura.
