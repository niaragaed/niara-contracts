# CLAUDE.md — niara-contracts

Standing instructions for Claude Code in this repository. Read them before writing
any code.

This repository is **separate** from `niara-site` (Niara's institutional site). Do not
look for or reference files from that project here.

---

## ⚠️ Financial contracts: safety above everything

If anything is ambiguous, **stop and ask**. Do not improvise in code that moves real
value. Design decisions already made (and why) are documented in README.md, section
"Design decisions".

- **Never commit a private key, a real `.env` or any secret.** `.env.example` exists
  only to document the format; real values stay local, outside git.
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
  (`NiaraSettlement.MAX_FEE_BPS = 100`, `CashbackDistributor.MAX_CASHBACK_BPS =
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

The four functions with external calls follow this pattern, each with a code comment
explaining why:

- `NiaraSettlement.settle`: `emit Settled` before the three `safeTransferFrom`.
- `BackingGateway.mintAttested`: `req.minted = true` and `emit BackingMinted` before
  `IAssetToken.mint`.
- `BackingGateway.redemptionAttest`: `SETTLED` status, `proofHash`, the decrease in
  `totalAttested` and `emit RedemptionAttested` before `IAssetToken.burn`.
- `BackingGateway.cancelRedemptionRequest`: `CANCELLED` status and
  `emit RedemptionRequestCancelled` before the `safeTransfer` that returns the tokens.

**Each one has a log-order test locking in the regression** (`vm.recordLogs` +
`assertLt` between the event index and the first `Transfer` index). Do not remove or
weaken these tests when changing those functions:

- `test_Settle_EmitsSettledBeforeExternalTransfers` (`test/NiaraSettlement.t.sol`)
- `test_MintAttested_EmitsBackingMintedBeforeExternalTransfer`
- `test_RedemptionAttest_EmitsRedemptionAttestedBeforeExternalTransfer`
- `test_CancelRedemptionRequest_EmitsCancelledBeforeExternalTransfer`
  (the last three in `test/BackingGateway.t.sol`)

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
order, discuss it first.

## Parameter still to be defined

`CashbackDistributor.cashbackBps` is at **1000 bps (10% of the fee)**, a provisional
value. See the code comment: *"TO BE DEFINED: 1% of the fee equals 0.005% of volume,
probably not enough. See the whitepaper, section 4."* Do not treat this number as
final; if the user asks to adjust it, that is expected.

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
5. If something breaks or becomes ambiguous: **stop and explain**, do not improvise.

Git identity for this repository: the one the user configured locally (no `--global`,
no overriding).

---

## Known open items

- Sepolia deployment completed (2026-07-22): both phases (`run()` + `executeWiring()`)
  and `script/Demo.s.sol` ran with a real `--broadcast`, with the user's explicit
  confirmation at each step. Addresses and transactions are documented in the README,
  sections "Testnet deployment" / "Demo transactions". Any new deployment (redeploy,
  another network) still requires an explicit request: never trigger `--broadcast` on
  your own.
- `cashbackBps` parameter (see above): provisional.
- No external audit has been done. Do not describe this code as audited in any future
  documentation.
