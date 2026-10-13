# niara-contracts

Base contracts (Solidity, Foundry) of Niara's on-chain infrastructure: issuance of
tokenized assets with attested backing, atomic settlement between buyer and seller,
and programmatic cashback to the issuer.

This repository is independent of `niara-site` (the institutional site). There is no
frontend here, only contracts, tests and scripts. The contracts were deployed **only
on the Sepolia testnet**, for the demos documented below; nothing is on mainnet.

---

## Contracts

### `AssetToken.sol`

ERC-20 representing a tokenized real-world asset (stock, ETF, commodity, currency or
fund), with metadata (asset reference, class, country of origin), roles via
`AccessControl` (MINTER, BURNER, PAUSER, CUSTODIAN, plus admin) and `Pausable` for
emergencies.

The project's core invariant lives here: `mint` only mints up to the total attested by
the configured `BackingGateway`, never beyond. This check is structural (inside `mint`
itself), not just an access-control convention.

`issuerWallet` (the issuer's wallet, recipient of the cashback) and `backingGateway`
only change through a timelocked proposal + execution, restricted to the admin.

### `BackingGateway.sol`

Coordinates the backing process. **It does not execute orders on a traditional
exchange**: it only records requests and attestations; actual execution is the
responsibility of an authorized off-chain agent (custodian).

Issuance flow:

```
requestBacking(asset, quantity)           [OPERATOR_ROLE]
        │  emits an event consumed by an off-chain agent,
        │  which buys the real asset on the traditional market
        ▼
attestBacking(requestId, proofHash, quantityAcquired)   [CUSTODIAN_ROLE]
        │  only then does totalAttested[asset] increase
        ▼
mintAttested(requestId, recipient)        [OPERATOR_ROLE]
        │  calls AssetToken.mint, which rechecks totalSupply <= totalAttested
        ▼
   tokens minted
```

Redemption flow (reverse):

```
redemptionRequest(asset, quantity)        [any holder]
        │  tokens are held by the gateway (not burned yet)
        ▼
redemptionAttest(requestId, proofHash)    [CUSTODIAN_ROLE]
        │  only then: burns the custodied tokens and reduces totalAttested
        ▼
   real asset released off-chain
```

> This contract does NOT execute exchange orders. It records requests and attestations.
> Execution is the responsibility of an authorized off-chain agent. Share buybacks by
> the issuing company itself are a regulated activity and are **not** implemented here:
> the model assumes market acquisition by a custodian.

### `NiaraSettlement.sol`

Atomic settlement: in the same transaction it moves the `AssetToken` from seller to
buyer, the payment (USDT or WBTC) from buyer to seller, and retains the fee, in the
settlement currency itself, with no swap, no DEX and no oracle. Any failure reverts
everything. It works entirely through `allowance` and never holds the parties' balances.

Fee: 50 bps (0.5%) by default, with a hard, immutable cap of 100 bps (1%) that not even
the admin can exceed. Restricted to `SETTLEMENT_OPERATOR_ROLE` (Niara's order-matching
engine): allowance authorizes moving funds, but only the authorized operator decides
when to trigger a settlement.

### `CashbackDistributor.sol`

Receives the fee (already transferred by `NiaraSettlement`) and credits the issuer in a
*pull* pattern: amounts accumulate per (asset, settlement currency) and the issuer
withdraws whenever it wants via `withdraw`. It only credits if
`AssetToken.cashbackEligible()` is true. The rest of the fee becomes protocol revenue,
withdrawable by the treasury.

Cashback share: **1000 bps (10% of the fee), a provisional value**. See the code
comment: *"TO BE DEFINED: 1% of the fee equals 0.005% of volume, probably not enough.
See the whitepaper, section 4."*

### `governance/TimelockedAccessControl.sol`

Governance base inherited by all four contracts. Every role grant/revocation, and every
sensitive parameter (fee, cashback, issuer wallet, `BackingGateway`/`CashbackDistributor`
address), goes through a proposal + execution separated by a configurable delay
(default used in tests: 2 days; adjustable between 1 hour and 30 days). The direct
`AccessControl` `grantRole`/`revokeRole` are disabled on purpose: use
`proposeGrantRole`/`executeGrantRole` (and the `Revoke` versions).

Designed to run with the admin roles assigned to a multisig wallet (e.g. Gnosis Safe).
There is no multisig logic in the contract; any address can hold a role.

---

## Design decisions (documented for review)

- **CUSTODIAN_ROLE on AssetToken** can pause (emergency circuit breaker when it detects
  a custody problem), but only PAUSER_ROLE can unpause: locking is unilateral, unlocking
  requires the normal governance process.
- **`settle` is role-restricted**, not permissionless: although moving funds depends
  only on `allowance`, letting any caller choose the terms between two parties that
  approved the contract would be an abuse surface.
- **Two-step redemption** (`redemptionRequest` takes custody, `redemptionAttest`
  burns): tokens are only destroyed once the release of the real asset is confirmed,
  which allows cancelling (`cancelRedemptionRequest`) if the off-chain process fails.
- **Cashback `withdraw` reads the current `issuerWallet`** at withdrawal time, not the
  address in effect when the fee was recorded: the balance belongs to the asset's
  issuer, not to a specific historical address.
- **Pausable on AssetToken, BackingGateway and NiaraSettlement**, not on
  CashbackDistributor: the first three move assets/backing; the distributor is purely
  accounting, and a circuit breaker there would risk blocking the issuer's legitimate
  withdrawals for no reason.

---

## How to run

```bash
forge build
forge test -vv
```

Prerequisites: [Foundry](https://book.getfoundry.sh/) installed (`forge`, `cast`,
`anvil`). Dependencies (`forge-std`, `openzeppelin-contracts` v5.1.0) are already in
`lib/`.

No environment variables are needed for build/test. `.env.example` documents what is
needed for a testnet deployment (see the section below).

---

## Testnet deployment (Sepolia)

⚠️ Sepolia only. Never mainnet without an explicit request (see CLAUDE.md). Always use
a **throwaway** wallet created only for testnet, with no real value. The private key
lives only in the local `.env` (already in `.gitignore`; check with `git status` before
any commit).

### 1. Prepare the wallet and get test ETH

1. Generate a new wallet just for this (`cast wallet new`, MetaMask in test mode, etc.).
   Never reuse a wallet with real funds.
2. Request Sepolia ETH from a faucet, for example:
   - https://sepoliafaucet.com/
   - https://www.alchemy.com/faucets/ethereum-sepolia
   - https://cloud.google.com/application/web3/faucet/ethereum/sepolia
3. Copy `.env.example` to `.env` and fill in `RPC_URL` (a Sepolia endpoint: Alchemy,
   Infura, etc.), `PRIVATE_KEY` (the throwaway wallet's key) and `ETHERSCAN_API_KEY`
   (for contract verification).

### 2. Two-phase deployment (because of the real timelock)

`TimelockedAccessControl.MIN_TIMELOCK_DELAY` is 1 hour; that wait cannot be skipped,
not even on testnet (see CLAUDE.md). That is why deployment has two phases:

**Phase 1: deploy the contracts and schedule (propose) all the role wiring:**

```bash
forge script script/Deploy.s.sol --rpc-url sepolia
```

Always run first **without** `--broadcast` (simulation/dry run) and check the output
before broadcasting for real. Only after confirming, add `--broadcast --verify`:

```bash
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
```

The output lists the deployed addresses (`DEPLOYED_*`); copy them into your local
`.env`.

**Wait `TIMELOCK_DELAY` seconds** (1 hour by default), then run phase 2, which
executes (consumes) the phase 1 proposals:

```bash
forge script script/Deploy.s.sol --sig "executeWiring()" --rpc-url sepolia --broadcast
```

### 3. Demo script

With the wiring complete, `script/Demo.s.sol` runs the protocol's full flow as real
transactions: `requestBacking → attestBacking → mintAttested → settle → cashback
credited → withdraw`. It needs the same `DEPLOYED_*` variables in `.env`:

```bash
forge script script/Demo.s.sol --rpc-url sepolia --broadcast
```

The demo "buyer" is an account derived automatically by the script (no second private
key needed); it receives a little test ETH and USDT from the deployer just to approve
its own side of the settlement.

### Demo transactions (Sepolia)

Real run of `script/Demo.s.sol` on 2026-07-22. Contract addresses (deploy phase 1 +
phase 2):

| Contract | Address |
|---|---|
| MockUSDT | [`0x8737...b112`](https://sepolia.etherscan.io/address/0x87374912f372378f94af3f93b36e06126e53b112#code) |
| MockWBTC | [`0xA202...8bb7`](https://sepolia.etherscan.io/address/0xa202111580a6d9afa3f0f7e48fe49de650528bb7#code) |
| CashbackDistributor | [`0x2A08...A1bE`](https://sepolia.etherscan.io/address/0x2a08c09d10f5d6b15c176241317e9ad20d5da1be#code) |
| NiaraSettlement | [`0xd7DE...D178`](https://sepolia.etherscan.io/address/0xd7deabcac261cbdc9bb898baf8e60da1355bd178#code) |
| BackingGateway | [`0x6C90...835c`](https://sepolia.etherscan.io/address/0x6c90bc018d9fc396093cc0394801f4de175e835c#code) |
| AssetToken (nDEMO) | [`0xcE92...b37f`](https://sepolia.etherscan.io/address/0xce920ba910c1ecb8e767f37933b38520892eb37f#code) |

Seller/issuer: `0x8763606AE3C03733AF248cfEF549573e3073101a` (deployer). Buyer:
`0x5E6b075b52684dC3a4d84d13465F02273c05e3eC` (account derived automatically by the
script, for this demo only).

Transaction sequence, in the order it happened:

| # | Step | Transaction | Amounts |
|---|---|---|---|
| 1 | `requestBacking` | [`0x677d...bfeba`](https://sepolia.etherscan.io/tx/0x677d8911650268013fcfa186fece5efe672b0b6ec079f2347d0771006fabfeba) | Backing request for 1,000 nDEMO |
| 2 | `attestBacking` | [`0x30dc...ea8033`](https://sepolia.etherscan.io/tx/0x30dc02748869c5f5286d30c54c7382ef95ad803728fdfb8a301a55edcfea8033) | 1,000 nDEMO attested (custody confirmed) |
| 3 | `mintAttested` | [`0x7290...da23fb`](https://sepolia.etherscan.io/tx/0x729053bb2d16cfee77e8227f26f4c5cf3e2e20a997ba29545cb8ae3559da23fb) | 1,000 nDEMO minted to the seller |
| 4 | Buyer funding (ETH) | [`0x201e...9d5e513`](https://sepolia.etherscan.io/tx/0x201e8bfa9138093dc244a5d3019925199e5059dc7a420615eefe9af6f9d5e513) | 0.01 ETH, only for the buyer's own gas |
| 5 | Buyer funding (USDT) | [`0xd840...781b1b5`](https://sepolia.etherscan.io/tx/0xd840a3a18250caa7670cdfee4d670eee06de57be02250cc462aa7ec16781b1b5) | `MockUSDT.mint`: 10,000 demo USDT |
| 6 | `approve` (AssetToken, seller) | [`0x59b7...e0cae`](https://sepolia.etherscan.io/tx/0x59b7f334df0f24fc62bf3662c575779d898b307578bf86840f3a9e9f336e0cae) | Approval of 100 nDEMO for `NiaraSettlement` |
| 7 | `approve` (USDT, buyer) | [`0x65ff...b522c`](https://sepolia.etherscan.io/tx/0x65fffb2329315038ff1f8c0a207c7a9ade519e21f67933ed952723d49b8b522c) | Approval of 10,000 USDT for `NiaraSettlement` |
| 8 | `settle` | [`0x1e1d...d17b33e`](https://sepolia.etherscan.io/tx/0x1e1ddcc072a7770e9d6e8725b0b6f8a91e129b7b036bc01b22a28d701d17b33e) | 100 nDEMO ↔ 10,000 USDT; **fee retained: 50 USDT** (0.5%) |
| 9 | `withdraw` (cashback) | [`0x87fd...8e0795a6`](https://sepolia.etherscan.io/tx/0x87fdcf2607af747e9a5256f18b6fb7db2895de942d05b3d6bd4f16a38e0795a6) | Issuer withdraws **5 USDT** of cashback (10% of the 50 USDT fee) |

Checked on-chain after the demo: `cashbackBalance(nDEMO, USDT)` went back to 0, and the
issuer/seller's final USDT balance is 9,955 USDT (9,950 net from the sale + 5 of
withdrawn cashback), exactly as expected.

---

## Second demo: roles in distinct wallets (`script/PresentationDemo.s.sol`)

Version for **public presentation**, designed to make explicit that the cashback goes
to a third party outside the trade, not to the buyer or the seller. The key difference
from the first demo (which stays intact, documented above, and was not changed): there
the same deployer held every role; here **each role is its own wallet**:

| Role | Address | Note |
|---|---|---|
| Admin (deployer / governance) | `0x8763606AE3C03733AF248cfEF549573e3073101a` | the usual one; governance only, does not take part in the flow |
| Operator | `0xe37e5C7ee77119CE789f22Df50ccB8ebDFb665eD` | `requestBacking`, `mintAttested`, `settle` |
| Custodian | `0xD3d3323ce7Bce15A27CA38C12c9C2Cef21020252` | `attestBacking` |
| **Issuing company** | `0xf8Eb1CDC6edDE176ee8Dcb57D4BB8Be464e120F8` | `issuerWallet`: receives and withdraws the cashback; **neither buyer nor seller** |
| Seller | `0xdF60E0Da8071028BD2C90656848854De5A5B0b7F` | delivers the `AssetToken` at settlement |
| Buyer | `0xc1051639110730DE92D717d5F0Bd7dC229FAD8AA` | pays at settlement |

The 5 role wallets are derived deterministically from a label (`makeAddrAndKey`,
depending on no private key other than the deployer's) and funded with 0.003 ETH each,
only to pay their own gas.

⚠️ **Important**: this script **reuses the same six contracts already deployed** by the
first demo (addresses in the previous section); it deploys nothing new. It only
**reassigns**, through the timelock, `OPERATOR_ROLE`/`CUSTODIAN_ROLE`
(`BackingGateway`)/`SETTLEMENT_OPERATOR_ROLE` (`NiaraSettlement`) to the wallets above,
**additively**, without revoking the original deployer's roles, and **changes the
`issuerWallet`** of the `AssetToken` (`nDEMO`) from the deployer's wallet to the
"issuing company" above. That change is permanent from now on (the contract design
allows issuer rotation; see "Design decisions"): the cashback credited in the first
demo had already been withdrawn before this change, so nothing in the history
documented above is affected; only cashback generated **from now on** goes to the new
issuing company.

### Phase 1: reassignment scheduled (completed on 2026-07-22)

| # | Action | Transaction |
|---|---|---|
| 1 | `proposeGrantRole` OPERATOR_ROLE→operator | [`0x32b7...019003`](https://sepolia.etherscan.io/tx/0x32b7bbb76050d21473ef1d6737cb0da84880bba44e8e9a3dd88e3116a4019003) |
| 2 | `proposeGrantRole` CUSTODIAN_ROLE→custodian | [`0x4faa...2d3db`](https://sepolia.etherscan.io/tx/0x4faa10237506e3f58b7d28b9e27211b288beccc5474004892ab249bed2e2d3db) |
| 3 | `proposeGrantRole` SETTLEMENT_OPERATOR_ROLE→operator | [`0x02d7...c06246`](https://sepolia.etherscan.io/tx/0x02d789f80ed10648faf2c3506870ed3ccd83607042dc3aa9466a0e8f99c06246) |
| 4 | `proposeSetIssuerWallet` → issuing company | [`0xee29...160882`](https://sepolia.etherscan.io/tx/0xee299db2fa36beabe9e1d56db589dedb8b53571fb5253cddde09ed3208160882) |
| 5-9 | Funding (0.003 ETH each) of the 5 role wallets | [`0xe1f8...9ce62`](https://sepolia.etherscan.io/tx/0xe1f82c0f718169e4f635de78f5e996c78aa1a006336c00f8868edb571c99ce62), [`0x8ab3...c63e75e`](https://sepolia.etherscan.io/tx/0x8ab38a707d803e270395cef88161d58ee448f06a35c383e05c945f730c63e75e), [`0x7750...90a9b8b`](https://sepolia.etherscan.io/tx/0x7750722b0646f091a6454fae5e9604c76acb21e5e5a8f49d0b7c7054390a9b8b), [`0x88a4...9181d1b`](https://sepolia.etherscan.io/tx/0x88a48101086b83297c11978b758bca9db8d6f86ed06aebef0bf4f67359181d1b), [`0xb670...455227`](https://sepolia.etherscan.io/tx/0xb670dee3fa219bd90c4823ea15fd471624354fe4eda9d1a1906395f282455227) |

### Phase 2: reassignment executed (completed on 2026-07-22)

Confirmed on-chain before broadcasting: the `executeAfter` of all 4 proposals had
already passed (`1784754288`) relative to the block timestamp at the time
(`1784754612`). After execution, also confirmed on-chain: the new roles were granted,
the deployer's old roles remain intact (additive reassignment, not a migration), and
`AssetToken.issuerWallet()` now points to the issuing company.

| # | Action | Transaction |
|---|---|---|
| 1 | `executeGrantRole` OPERATOR_ROLE→operator | [`0x205a...3e32c`](https://sepolia.etherscan.io/tx/0x205a98d2c7711913a5310878e2d3db9657e99587ebe63c8122c860382a43e32c) |
| 2 | `executeGrantRole` CUSTODIAN_ROLE→custodian | [`0x932b...5c7ef5`](https://sepolia.etherscan.io/tx/0x932b45385f16b04d1ef0de0c002017979112e3ee56ce31c04597535c1c5c7ef5) |
| 3 | `executeGrantRole` SETTLEMENT_OPERATOR_ROLE→operator | [`0xc1ed...92c30e3`](https://sepolia.etherscan.io/tx/0xc1ed525034b5c49ecfcebc9dcde40832295899203c495a7315f30de4192c30e3) |
| 4 | `executeSetIssuerWallet` → issuing company | [`0x7b76...b3481a6`](https://sepolia.etherscan.io/tx/0x7b76b708331827ae23aa91e82b97ff12d95afca1e71f47cdf1775bb0ab3481a6) |

### Demo (completed on 2026-07-22)

Each step was signed by the wallet of the corresponding role, not by the deployer
(except the demo USDT `mint` to the buyer, which any account can do on the mock):

| # | Step | Signed by (role) | Transaction |
|---|---|---|---|
| 1 | `requestBacking` | Operator `0xe37e...65eD` | [`0x357d...02c599`](https://sepolia.etherscan.io/tx/0x357d5ff52a1b8072cac139f6200e1b13910804f13443ef2904ecd39ec002c599) |
| 2 | `attestBacking` | Custodian `0xD3d3...20252` | [`0x0776...1053a`](https://sepolia.etherscan.io/tx/0x077646d2ab9dbb57698f81332c2ed8920e1bcaf06b7cf963c9741b89cae1053a) |
| 3 | `mintAttested` | Operator `0xe37e...65eD` | [`0x5307...9a08ca`](https://sepolia.etherscan.io/tx/0x5307b7e415581c9065e570c3f0ed87a1108dc5e3f9c7907fc505a57c7e9a08ca) |
| 4 | Demo USDT `mint` to the buyer | Admin/deployer `0x8763...3101a` | [`0x95a4...84d2a`](https://sepolia.etherscan.io/tx/0x95a4b6c60bb490a4aa8eaf42d466a76029b98e9b4ed10632aca733f0e8884d2a) |
| 5 | `approve` (AssetToken) | Seller `0xdF60...B0b7F` | [`0xa667...9e67`](https://sepolia.etherscan.io/tx/0xa6675e20c66243e8e61b00df6c79ccb6f6ff87b3ef677e76b699aa00b7ae9e67) |
| 6 | `approve` (USDT) | Buyer `0xc105...AD8AA` | [`0x5a9d...968e9`](https://sepolia.etherscan.io/tx/0x5a9dfe7e79828e1e6c0483289f82a1c2d8b2b1bab3ba801d8a17b82b709968e9) |
| 7 | **`settle`** | Operator `0xe37e...65eD` | [`0x5bad8660e43bb277517e6de57490ca5ffe77a8a5684122cd978f1dcaf2ecf5a6`](https://sepolia.etherscan.io/tx/0x5bad8660e43bb277517e6de57490ca5ffe77a8a5684122cd978f1dcaf2ecf5a6) |
| 8 | `withdraw` (cashback) | **Issuing company** `0xf8Eb...20F8` | [`0xc6e8...e9224`](https://sepolia.etherscan.io/tx/0xc6e87439dc3e0c77da96b3915574c82a04df578b2c3616cf18692c2fbd2e9224) |

#### The `settle` transaction, log by log

Transaction `0x5bad8660e43bb277517e6de57490ca5ffe77a8a5684122cd978f1dcaf2ecf5a6` emits
exactly **6 events**, in the order the contract fires them:

1. `Transfer` (AssetToken nPRES): seller → buyer, **100 nPRES**
2. `Transfer` (USDT): buyer → seller, **9,950 USDT** (net payment, fee already deducted)
3. `Transfer` (USDT): buyer → `CashbackDistributor`, **50 USDT** (the whole fee, in the settlement currency itself)
4. `CashbackCredited` (CashbackDistributor): `issuer = 0xf8Eb1CDC6edDE176ee8Dcb57D4BB8Be464e120F8` (**the issuing company, neither buyer nor seller**), **5 USDT**
5. `FeeRecorded` (CashbackDistributor): `feeAmount = 50 USDT`, `cashbackAmount = 5 USDT`, `eligible = true`
6. `Settled` (NiaraSettlement): summarizes the whole settlement: 100 nPRES ↔ 10,000 USDT, `feeCharged = 50 USDT`

**The numbers add up:**

```
Trade:                 100 nPRES  ↔  10,000 USDT
Fee (0.5% of 10,000):                    50 USDT
  Cashback (10% of the fee, to the issuing company):   5 USDT
  Protocol revenue (90% of the fee):                   45 USDT
Seller receives:       10,000 − 50 =  9,950 USDT
```

#### On-chain confirmation that the cashback went to a third party

Final USDT balances, read directly from the contracts after the demo:

| Account | USDT balance | What it is |
|---|---|---|
| **Issuing company** `0xf8Eb...20F8` | **5.000000** (5 USDT) | Exactly the withdrawn cashback; it received nothing from the trade itself |
| Seller `0xdF60...B0b7F` | 9,950.000000 (9,950 USDT) | Only the net from the sale, no cashback mixed in |
| Buyer `0xc105...AD8AA` | 0 | Paid exactly the 10,000 USDT it was funded with |
| `cashbackBalance(nPRES, USDT)` | 0 | This round's cashback fully withdrawn |
| `protocolBalance(USDT)` | 90.000000 (90 USDT) | Accumulated across both demos: 45 USDT from this one + 45 USDT from the first (never withdrawn by the treasury) |

The issuing company, which never took part in the trade as buyer or seller, is the only
account that received the cashback, confirming exactly what the second demo set out to
show: the cashback goes to a third party (the real asset's issuer), not to one of the
trading parties.

---

## Structure

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
  Deploy.s.sol           (phase 1: deploy + propose the wiring; phase 2 via --sig "executeWiring()")
  Demo.s.sol             (full flow as real transactions, for public demonstration)
  PresentationDemo.s.sol (2nd demo: same contracts, roles in distinct wallets, for presentations)
test/
  mocks/
    MockUSDT.sol                 (6 decimals)
    MockWBTC.sol                 (8 decimals)
    MockBackingGateway.sol       (adjustable totalAttested, to isolate the AssetToken tests)
    MaliciousReentrantToken.sol  (for reentrancy tests)
    MaliciousHookToken.sol       (records what a re-entry saw, for cross-function reentrancy tests)
    TimelockHarness.sol          (minimal concrete instance of TimelockedAccessControl)
  AssetToken.t.sol
  BackingGateway.t.sol
  NiaraSettlement.t.sol
  CashbackDistributor.t.sol
  TimelockedAccessControl.t.sol
  Integration.t.sol              (full flow: backing → settlement → cashback → redemption)
  Invariant.t.sol + invariant/Handler.sol  (stateful fuzzing of the core invariants)
```
