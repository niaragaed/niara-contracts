# CLAUDE.md — niara-contracts

Standing instructions for Claude Code in this repository. Read them before writing
any code.

This repository is **separate** from `niara-site` (Niara's institutional site). Do not
look for or reference files from that project here.

**Multichain exchange:** `EXCHANGE-MULTICHAIN-DESIGN.md` is the source of truth for the multichain exchange (listing, issuance, settlement, P2P escrow) on EVM and Solana.
It is a tracked **copy** of the spec in the Solana repo (`github.com/niaragaed/niara-exchange-solana`):
keep it tracked here and sync it from there.

**EXCHANGE-MULTICHAIN-DESIGN.md is owned by the niara-exchange-solana repo. Never edit it
here. List any spec change this repo needs under "Spec edits needed" in your final report.**
That includes the EVM-side sections (§4.1 and the "EVM vs Solana differences" table in
§4.2): they are changed in the Solana repo and synced back, never edited in this copy.

---

## ⚠️ Financial contracts: safety above everything

If anything is ambiguous, **stop and ask**. Do not improvise in code that moves real
value. Design decisions already made (and why) are documented in README.md, section
"Design decisions".

- **Never commit a private key, a real `.env` or any secret.** `.env.example` exists
  only to document the format; real values stay local, outside git.
- **No private key or mnemonic in `.env`, ever, and no script that reads one**
  (`vm.envUint("PRIVATE_KEY")` and the like are forbidden). Signers are Foundry keystores
  (`~/.foundry/keystores`, passed with `--account`); scripts name them by address
  (`vm.startBroadcast(address)`). Do not create, import or unlock a keystore yourself:
  give the user the commands.
- **No deployment to any network without an explicit request from the user**, neither
  testnet nor mainnet. For now this repository is code and local tests only
  (`forge build` / `forge test`).
- **Every public/external function needs a test.** If you add a new function without a
  matching test, the work is not done.
- **Minting without attested backing is forbidden by a structural invariant**, not by
  access control: `AssetToken.mint` checks `totalSupply() + amount <=
  IBackingGateway(backingGateway).totalAttested(address(this))` directly, even if
  `MINTER_ROLE` is granted to an address outside the `BackingGateway`. Any change to
  that function requires the matching invariant test to keep passing
  (`test_Invariant_MintBeyondAttestedIsImpossibleRegardlessOfCaller` in
  `test/BackingGateway.t.sol`, and the tests in `test/AssetToken.t.sol`).
- **Never remove or weaken `nonReentrant`, `SafeERC20` or the hard bps caps**
  (`NiaraSettlement.MAX_FEE_BPS = 50`, `CashbackDistributor.MAX_CASHBACK_BPS =
  10_000`) without discussing it explicitly with the user. They are core security
  invariants of the model, not implementation details.
- **Changes to roles, fee, cashback or reference wallets go through the timelock**
  (`TimelockedAccessControl`: propose → wait `timelockDelay` → execute). Do not add
  shortcuts that apply these changes immediately.

## Tokens with hooks: checks-effects-interactions is mandatory

**Design premise:** the protocol intends to accept payment tokens and assets with hooks
(ERC-777, ERC-1363), not only plain ERC-20. Every `transfer`, `transferFrom`, `mint`
or `burn` must be treated as an external call that can hand control to a hostile
contract in the middle of the operation.

Because of that, **checks-effects-interactions is a mandatory rule for any new code**:
every state update *and every event emission* comes before the external call. Never the
other way around.

- **`nonReentrant` alone is not enough.** It prevents re-entry into the same function,
  but not **cross-function** re-entry (a hook calling another function of the contract
  during the external call), and it does not fix the **log order**: with the `emit`
  after the transfer, an off-chain indexer sees the `Transfer` (or the re-entry's
  events) before the event of the operation that caused them, breaking invariants
  assumed off-chain.
- **`nonReentrant` is always the first modifier**, before `onlyRole` and
  `whenNotPaused`. Modifiers run in declaration order; the guard must not depend on the
  order of the others. This is verifiable: the `..._RevertsViaGuard` tests deliberately
  *do not* grant the role to the hostile contract, so they only pass if the observed
  error is `ReentrancyGuardReentrantCall` and not `AccessControlUnauthorizedAccount`.

The functions with external calls follow this pattern, each with a code comment
explaining why:

- `NiaraSettlement.settle`: `settledMatches[matchId] = true` (replay guard) and
  `emit Settled` before the three `safeTransferFrom`.
- `BackingGateway.mintAttested`: `req.minted = true` and `emit BackingMinted` before
  `IAssetToken.mint`.
- `BackingGateway.redemptionAttest`: `SETTLED` status, `proofHash`, the decrease in
  `totalAttested` and `emit RedemptionAttested` before `IAssetToken.burn`.
- `BackingGateway.cancelRedemptionRequest`: `CANCELLED` status and
  `emit RedemptionRequestCancelled` before the `safeTransfer` that returns the tokens.
- `ListingRegistry.approveIssuance`: batch `Executed`, `resolvedAt` and
  `emit IssuanceExecuted` before `NativeAssetToken.mint`.
- `ListingRegistry.payListingFee`: `listingFeePaid`, status `Approved`, `approvedAt`,
  `emit ListingFeePaid` and `emit ListingApproved` before the `safeTransferFrom` that pulls
  the listing fee into the distributor.
- `CashbackDistributor.withdraw`: the cashback balance zeroed and
  `emit CashbackWithdrawn` before the `safeTransfer` to the issuer.
- `CashbackDistributor.withdrawProtocolFees`: the protocol balance decreased and
  `emit ProtocolFeesWithdrawn` before the `safeTransfer` to the treasury's recipient.
- `P2PEscrow.openDeal`: the deal stored, `totalEscrowed` increased and `emit DealOpened`
  before the `safeTransferFrom` that pulls the deposit.
- `P2PEscrow.acceptDeal`: `Executed` status, `resolvedAt`, the decrease in
  `totalEscrowed` and `emit DealExecuted` before any of the transfers.
- `P2PEscrow.cancelDeal` / `expireDeal`: `Cancelled` / `Expired` status, `resolvedAt`,
  the decrease in `totalEscrowed` and `emit DealCancelled` / `DealExpired` before the
  `safeTransfer` that returns the deposit.
- `P2PEscrow.sweepExcess`: `emit ExcessSwept` before the `safeTransfer` (it has no state
  to update).

**Each one has a log-order test locking in the regression** (`vm.recordLogs` +
`assertLt` between the event index and the first `Transfer` index). Do not remove or
weaken these tests when changing those functions:

- `test_Settle_EmitsSettledBeforeExternalTransfers` (`test/NiaraSettlement.t.sol`)
- `test_MintAttested_EmitsBackingMintedBeforeExternalTransfer`
- `test_RedemptionAttest_EmitsRedemptionAttestedBeforeExternalTransfer`
- `test_CancelRedemptionRequest_EmitsCancelledBeforeExternalTransfer`
  (these three in `test/BackingGateway.t.sol`)
- `test_ApproveIssuance_EmitsIssuanceExecutedBeforeExternalTransfer`
  (`test/ListingRegistry.t.sol`)
- `test_PayListingFee_EmitsListingFeePaidBeforeExternalTransfer` (`test/ListingFee.t.sol`)
- `test_Withdraw_EmitsCashbackWithdrawnBeforeExternalTransfer`
- `test_WithdrawProtocolFees_EmitsProtocolFeesWithdrawnBeforeExternalTransfer`
  (these two in `test/CashbackDistributor.t.sol`)
- `test_OpenDeal_EmitsDealOpenedBeforeExternalTransfer`
- `test_AcceptDeal_EmitsDealExecutedBeforeExternalTransfers`
- `test_CancelDeal_EmitsDealCancelledBeforeExternalTransfer`
- `test_ExpireDeal_EmitsDealExpiredBeforeExternalTransfer`
- `test_SweepExcess_EmitsExcessSweptBeforeExternalTransfer`
  (these five in `test/P2PEscrow.t.sol`)

When adding a new function with an external call, add the equivalent order test. To
simulate the hostile asset, use `test/mocks/MaliciousHookToken.sol`, which **records**
the result of the re-entry (`reentrantSucceeded` / `reentrantReturnData`) instead of
aborting. The older `MaliciousReentrantToken` does `require(success)` and reverts the
whole transaction, which proves blocking but prevents inspecting the state the re-entry
saw.

**Documented exception:** in `settle`, `cashbackDistributor.recordFee` stays *after*
the fee transfer, because the distributor accounts for a fee that must already be in
its balance. It is an internal protocol call and any failure reverts the whole
transaction, event included. It is commented in the code; if you need to change that
order, discuss it first. `P2PEscrow.acceptDeal` has the same exception for the same
reason: `cashbackDistributor.recordDealFee` comes after the fee transfer. So does
`ListingRegistry.payListingFee`: `recordListingFee` comes after the listing-fee transfer.

**P2PEscrow refunds are never blocked.** `cancelDeal` and `expireDeal` must not read the
registry, `NiaraSettlement` or the pause, and must not gain any new way to revert (no
`whenProtocolNotPaused`, no listing check, no balance-delta check on the refund). Every
exit moves exactly the deal's own deposit; `sweepExcess` only ever moves
`balance - totalEscrowed[token]`. The invariant suite (`test/P2PEscrowInvariant.t.sol`,
mirroring Solana invariants 6 and 7) must keep passing on any change to that contract.

## Parameter still to be defined

`CashbackDistributor.cashbackBps` has no default in the contract: it is a constructor
parameter, bounded by `MAX_CASHBACK_BPS`, and `script/Deploy.s.sol` passes **2000 bps (20%
of the fee)** (`CASHBACK_BPS`). After deployment it changes only through the timelock. The
value is still provisional. See the code comment: *"TO BE DEFINED: the right share is still
a business decision (1% of the fee equals 0.005% of volume, probably not enough). See the
whitepaper, section 4."* Do not treat this number as final; if the user asks to adjust it,
that is expected. Do not reintroduce a hardcoded default in the contract.

---

## Stack

- Foundry (forge/cast/anvil), Solidity `^0.8.24`.
- OpenZeppelin Contracts v5.1.0 (`lib/openzeppelin-contracts`, installed from a release
  zip, not as a git submodule; do not run `forge update` on that lib without reviewing
  first, since there is no git history inside it).
- Remappings in `remappings.txt`, mirrored in `foundry.toml`.
- Deploy scripts in `script/`: `Deploy.s.sol` (phase 1 `run()` deploy + propose, phase 2
  `executeWiring()` after the timelock has really elapsed) and `Demo.s.sol` (full flow
  as real transactions). Only used on an explicit deploy request: never trigger
  `--broadcast` on your own; see the README section "Testnet deployment".
  - **Chain guard:** the scripts run only on Ethereum Sepolia (11155111) and Base Sepolia
    (84532) and revert `UnsupportedChain` anywhere else (`script/NiaraScriptBase.sol`). Do
    not add a chain, and never a mainnet, without an explicit request.
  - Deploy parameters: fee 50 bps (the contract default and cap, only checked by the
    script) and cashback `CASHBACK_BPS` (default 2000), passed to the `CashbackDistributor`
    constructor in phase 1. The deployment proposes and executes only the four role
    grants and the registry's settlement link (the listing fee needs it); it never uses the
    timelock for the cashback rate, and phase 2 only checks it.
    The script's logic is tested in-process by
    `test/script/DeployScript.t.sol`; a local simulation uses Anvil started with one of the
    two chain ids, without `--broadcast`.
  - `script/tokens/TestnetMockToken.sol` is a test token with no value (open mint). It is
    deployment tooling, never to be used or described as a real currency.
  - `Demo.s.sol` runs three flows (equity on the order book, fixed-income P2P deal,
    mock BRL <-> mock USDT currency deal) with six distinct role wallets, tested in-process
    by `test/script/DemoScript.t.sol`. `LocalSimulation.s.sol` chains both deploy phases
    and the demo in one dry run; it only runs against Anvil and is never broadcast.

## No AI attribution (hard rule)

Nothing in this repository credits an AI tool, anywhere:

- no `Co-Authored-By: Claude` or `Claude-Session:` trailers, and no "Generated with Claude Code"
  line, in commit messages;
- no AI tool as a commit author or committer: commits use the project identity
  (`git config user.name`/`user.email` = `Niara <niaragaed@gmail.com>`, set in every clone and
  environment before the first commit — some environments default to `Claude <noreply@anthropic.com>`);
- no "Generated with/by Claude Code" footer in pull request descriptions, comments, issues or files.

It's enforced in two layers: the versioned `.claude/settings.json` turns Claude Code's commit
and PR attribution off (`"attribution": {"commit": "", "pr": ""}`), and the `No AI attribution`
GitHub Actions check (`.github/workflows/no-ai-attribution.yml`) fails on any commit or pull
request description that carries it. Some hosted environments append a footer to PR
descriptions by themselves; if the check flags one, delete that line in the GitHub UI. The rule
applies to every Niara repository, including new ones: copy both files when creating a repo.

---

## Conventions

- **Language: English for everything** (code, identifiers, comments, NatSpec, docs,
  test names, script output and commit messages).
- NatSpec (`@notice`/`@dev`/`@param`/`@return`) on every new public/external function.
- Custom errors (`error X()` + `revert X()`), not `require(cond, "string")`, except
  where already used by external libraries (OpenZeppelin).
- Timelock pattern: `proposeX(...)` schedules (`_scheduleAction`), `executeX(...)`
  consumes (`_consumeAction`) and applies the change. The `actionId` is
  `keccak256(abi.encode("ACTION_NAME", ...params))`. If you add a new sensitive
  action, follow this pattern instead of inventing a new mechanism.
- **Beware of tests using `vm.prank` followed by a call that reads a constant of the
  contract itself on the same line** (e.g. `token.MINTER_ROLE()` inside an
  `abi.encodeWithSelector(...)` right after `vm.prank`): that is an external call that
  consumes the prank before the call under test. Always resolve roles (`bytes32`) into
  variables before the prank. See the comment at the top of `test/AssetToken.t.sol`.

## Workflow

1. Before coding, read the files involved; do not assume.
2. `forge build` and `forge test -vv` at the end of each change; fix whatever shows up.
3. Local commit at the end of each task, message in English, following `feat:` /
   `fix:` / `refactor:` / `chore:` / `test:`.
4. Never `--force`, never rewrite history, never push unless asked, never create a
   remote repository unless asked.
   - **Never use `git reset`, in any form**: no `--hard`, `--soft`, `--mixed`, `--keep`
     or `--merge`, no bare `git reset`, no `git reset <commit>` and no
     `git reset <path>` / `git reset -- <path>` (not even to unstage). It rewrites the
     index or the branch, and some forms the working tree, with no way back.
   - **Never run a git command that changes or discards working-tree files.** Forbidden:
     `git checkout` (of a path, a branch or a commit), `git restore` without `--staged`
     (which includes `--worktree` and `--staged --worktree`), `git stash` (in every form)
     and `git clean`, and anything else that would overwrite or delete uncommitted work.
     The test is the working tree: if the command can change or remove a file there, do
     not run it. To set work aside, commit it.
   - **The only way to unstage is `git restore --staged <path>`**: it only changes the
     index and never touches a working-tree file. Use that form to take a file out of a
     commit you are preparing; no other command is allowed for it.
   - For a temporary edit (e.g. a mutation check), start from a clean, committed tree,
     copy the file to a backup outside the repository before the edit, and put it back
     from that copy afterwards (a plain file copy, not a git command).
5. If something breaks or becomes ambiguous: **stop and explain**, do not improvise.

Git identity for this repository: the one the user configured locally (no `--global`,
no overriding).

---

## Known open items

- **The v1 exchange has NOT been deployed anywhere.** `script/Deploy.s.sol` and
  `script/Demo.s.sol` (v1: registry, factory, settlement, escrow, mock test tokens) were
  only rehearsed as dry runs against local Anvil nodes started with the Sepolia and Base
  Sepolia chain ids (2026-11-12), without `--broadcast`. Deploying to Sepolia or Base
  Sepolia requires an explicit request, and the user's confirmation at each step (phase
  1, phase 2, demo): never trigger `--broadcast` on your own, not even against a local
  node unless asked.
- The July 2026 Sepolia deployment (2026-07-22) documented in the README ("Historical")
  is the earlier backed model (`AssetToken` + `BackingGateway`), made with the previous
  versions of the scripts. It is not the v1 exchange and predates the `ListingRegistry`.
- `cashbackBps` parameter (see above): provisional.
- No external audit has been done. Do not describe this code as audited in any future
  documentation.
