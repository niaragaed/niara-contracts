# Niara Exchange — Multichain Settlement Design (v1)

Status: DRAFT for design freeze · Target: Solana Foundation interview (4–6 weeks)
Chains in scope: Solana Devnet (priority), Ethereum Sepolia, Base Sepolia
Roadmap only (not in v1): Robinhood Chain Testnet, HyperEVM Testnet, Tempo Testnet
(target chains: §9.9)

> Everything here runs on testnets with test tokens. No real assets, no real money,
> no regulatory authorization. Every screen and doc must say so.

---

## 1. Product model (what we are actually building)

A peer-to-peer tokenized securities exchange with **self-custody** and **curated listing**:

1. **Direct issuance, Niara-approved.** An issuer creates its asset token from
   its own wallet (equity, fixed income or credit). The token *is* the
   instrument — native issuance, not a wrapper of an asset held by a custodian.
   When the issuer submits the listing, the mint authority moves to the
   program; from then on every new unit is a numbered batch the issuer
   requests and Niara approves (§3.12). Neither can mint alone.
2. **Curated listing.** A token only becomes tradable on Niara after Niara approves
   its listing. Niara controls *eligibility*, never custody.
3. **Two trading modes, fixed by asset class** (decided 2026-10-22). This mirrors
   real markets: equities trade on exchanges, bonds and credit trade mostly OTC/RFQ.

   | Asset class | Mode | Cashback eligible |
   |---|---|---|
   | `Equity` (renda variável) | Order book (delegate) | yes |
   | `FixedIncome` (renda fixa) | P2P escrow | yes (issuer = bond issuer) |
   | `Credit` (crédito) | P2P escrow | yes (issuer = debtor/originator) |
   | `Currency` (câmbio: stablecoins, e.g. BRL ↔ USDT) | P2P escrow | **no** (forced false) |

   The mode is enforced **on-chain**: `settle` only accepts `Equity` listings,
   and `open_deal`/`accept_deal` only accept `FixedIncome`/`Credit`/`Currency`.


   - **Order book (delegate).** An offer goes live when the owner approves the
     exact order amount to the program's vault PDA (SPL delegate / ERC-20
     allowance). Tokens stay in the user's wallet. Orders are matched
     **off-chain** (Supabase/Postgres) and settled **on-chain, atomically**, by
     the settlement operator.
   - **P2P negotiation (escrow).** Two parties negotiate a bilateral deal
     (propose → counter → accept). Once terms are fixed, the proposer locks
     its side in a per-deal escrow PDA, naming the counterparty (v1 has no
     open offers). The counterparty's acceptance executes the swap
     atomically. No operator is involved and the operator does not need to be trusted.
4. **Revenue: two fees, both in USDT. No custody fee.**
   - **Trading fee**, on every settlement and deal: 0.1% to 0.5% of the
     trade, charged in the **fee mint** (USDT, set in `Config`). The party
     that receives USDT pays it, out of the USDT it receives (§3.4). On-chain
     only the cap is enforced: `fee_bps ≤ MAX_FEE_BPS = 50` (0.5%). The 0.1%
     floor is pricing policy; the program accepts any rate from 0 to 50 bps.
   - **Listing fee**, once per listing: 0.1% to 1% of the issuer's valuation,
     charged **on-chain** in USDT (§3.13). The listing authority quotes it
     (`quote_listing`) and the issuer pays it into the fee vault
     (`pay_listing_fee`); paying is what approves the listing. Only the cap
     is enforced: `listing_fee_bps ≤ MAX_LISTING_FEE_BPS = 100` (1%); the
     0.1% floor is pricing policy, as for the trading fee. The valuation is
     public on-chain.
   - **No custody fee.** Niara never holds the users' assets: tokens stay in
     the owners' wallets, or in a per-deal escrow only while a deal is open
     (§3.5).
   - **Issuer cashback** is a share of the trading fee only, credited to the
     issuer (pull model), so it is in USDT too: 20% at deployment
     (`cashback_bps = 2000`), changed only through the timelock. The listing
     fee earns no cashback.

Accurate one-line description for pitches:
**"Off-chain matching, atomic on-chain settlement, self-custody, curated listing."**
Do NOT describe it as "fully on-chain" or "decentralized exchange" — matching and
listing approval are centralized by design, and an expert will see it immediately.

### Native issuance vs. backed tokenization

| | Native issuance (v1) | Backed tokenization (future) |
|---|---|---|
| What the token is | The instrument itself | A claim on an off-chain asset |
| Custodian needed | No | Yes (attest-before-mint) |
| Existing contract | New: listing registry + issuance | `BackingGateway` (kept, not used in v1) |
| Legal record | Must reconcile with corporate records → **Niara-Register** | Custodian records |

The `BackingGateway` path stays in the codebase for future backed assets (e.g.
tokenized listed stocks). v1 focuses on native issuance.

---

## 2. Architecture overview

```
 Wallets (self-custody)                Off-chain (Supabase, niara-exchange-dev)
 ┌───────────────┐   signed order    ┌──────────────────────────────────────┐
 │ Phantom/Solflare│ ───────────────▶ │ orders → matching engine → matches    │
 │ MetaMask (EVM)  │                  │            │                         │
 └───────────────┘                    │            ▼                         │
        ▲  approve / delegate         │   settlement worker (holds operator  │
        │  (exact order amount)       │   key per chain, minimal funds)      │
        │                             └────────────┬─────────────────────────┘
        │                                          │ SettlementAdapter.settle(match)
        │              ┌───────────────────────────┼───────────────────────────┐
        │              ▼                           ▼                           ▼
        │   Solana Devnet program        Ethereum Sepolia contracts    Base Sepolia contracts
        │   (Anchor, niara_exchange)     (same Solidity as Base)       (same Solidity)
        │              │                           │                           │
        └──────────────┴──────── events (ListingApproved, Settled incl. cashback)
                                                   │
                                                   ▼
                                   Niara-Register indexer → "Global registry" area
```

Single interface on the off-chain side:

```ts
interface SettlementAdapter {
  chain: 'solana-devnet' | 'eth-sepolia' | 'base-sepolia';
  settle(match: Match): Promise<{ txHash: string }>;
  isListed(asset: string): Promise<boolean>;
}
```

---

## 3. Solana program — `niara_exchange` (Anchor)

### 3.1 Design principles

- Mirror the **semantics** of `niara-contracts` (fee cap, cashback pull model,
  atomic settlement, timelock, pause), but written **idiomatically for Solana**:
  PDAs, SPL token accounts, CPIs, `transfer_checked`.
- Support both **SPL Token and Token-2022** via `Interface<'info, TokenInterface>`.
- Emit events with **`emit_cpi!`** (not only `emit!`): log-based events can be
  truncated; CPI events are reliable for the Register indexer.

### 3.2 Accounts (PDAs)

| Account | Seeds | Fields |
|---|---|---|
| `Config` | `["config"]` | `admin`, `listing_authority`, `settlement_operator`, `treasury`, `fee_mint` (the USDT mint: every fee and all cashback are in it, §3.4; set at `initialize_config`, changed only through the timelock), `fee_bps: u16` (≤ `MAX_FEE_BPS = 50`, i.e. 0.5%; §3.4), `cashback_bps: u16` (share **of the fee**, ≤ 10_000), `paused: bool`, `timelock_secs: i64`, `bump` |
| `PendingChange` | `["pending", kind]` | proposed value, `execute_after: i64` (Clock `unix_timestamp`) |
| `Listing` | `["listing", asset_mint]` | `asset_mint`, `issuer`, `asset_class` (`Equity`/`FixedIncome`/`Credit`/`Currency`), `status` (`Pending`/`Approved`/`Suspended`/`Delisted`/`Quoted`; `Quoted` is appended last, §3.13), `cashback_eligible`, `doc_hash: [u8;32]` (offering document hash — registered in Niara-Register), `approved_at`, `next_batch_no: u64` (next issuance batch; 1 after `submit_listing`, 0 for `Currency`), `issued: u64` (Σ executed batches), `burned: u64` (Σ `burn_with_reason`), `cashback_frozen: bool` (§9.5; false at creation), the listing-fee quote (§3.13): `valuation: u64`, `listing_fee_bps: u16`, `listing_fee: u64`, `listing_fee_mint`, `quote_expires_at: i64`, `listing_fee_paid: u64` (0 until paid; all six stay 0 for `Currency`), `bump` |
| `IssuanceBatch` | `["batch", listing, batch_no]` (`batch_no` as `u64` LE) | `listing`, `batch_no`, `amount`, `recipient` (wallet), `doc_hash`, `status` (`Requested`/`Executed`/`Rejected`), `requested_at`, `resolved_at`, `bump`. Never closed: the on-chain issuance record (§3.12) |
| Mint authority | `["mint_authority", asset_mint]` | PDA that holds the mint authority of every issuer-listed asset after `submit_listing`; signs `mint_to_checked` in `approve_issuance`. Holds no data |
| `CashbackLedger` | `["cashback", listing, fee_mint]` | `listing`, `payment_mint` (= the fee mint it was created for), `accrued: u64`, `withdrawn: u64`, `bump`. Created by the permissionless `init_cashback_ledger` for a cashback-eligible listing and the current `Config.fee_mint`, never lazily inside `settle` |
| `FeeLedger` | `["fees", fee_mint]` | `payment_mint` (= the fee mint), `fees_collected` (gross **trading** fee: protocol share + cashback), `cashback_accrued` (Σ `CashbackLedger.accrued` in this mint), `protocol_withdrawn`, `cashback_withdrawn`, `bump`, `vault_bump`, `listing_fees_collected` (Σ listing fees paid in this mint, all protocol revenue, §3.13; appended last). **One**, for the fee mint (USDT); created with the fee vault by `init_fee_vault`. Protocol share available = `fees_collected − cashback_accrued + listing_fees_collected − protocol_withdrawn`. Makes invariants 2 and 4 checkable in one account |
| `SettlementRecord` | `["settled", match_id]` | `bump`. Replay guard: `settle` `init`s it, so a match id settles at most once. Never closed (closing would re-enable the id); the operator pays its rent (~0.00095 SOL per settlement: 9 bytes + account overhead; see §3.10 for the bitmap replacement) |
| `Deal` | `["deal", proposer, deal_id]` (`deal_id: [u8;16]`, the off-chain negotiation UUID) | `deal_id`, `proposer`, `counterparty` (named; no open offers in v1), `asset_mint`, `payment_mint`, `asset_amount`, `payment_amount`, `fee_bps`, `cashback_bps` (the config's rates at `open_deal`, charged at `accept_deal`: the fee is part of the agreed terms, §3.5), `proposer_side` (`Sell`/`Buy`), `expires_at: i64`, `status` (`Open`/`Executed`/`Cancelled`/`Expired`), `opened_at`, `resolved_at`, `bump`, `vault_bump`. Never closed: the status is the replay guard (§3.5); the proposer pays its rent |
| Deal vault | `["deal_vault", deal]` token account of the deposited mint, authority = the `Deal` PDA | holds the proposer's deposit until accept/cancel/expiry, then closed (rent to the proposer). Created by `open_deal` after its checks (the deposited mint depends on the side). A PDA rather than an ATA, for the same reason as the fee vault: anyone can create an ATA, so it could be front-run |
| `Vault authority` | `["vault"]` | PDA signer for fee/cashback vaults and for delegated transfers |
| Fee vault | `["fee_vault", fee_mint]` token account, authority = vault authority | **one**, in the fee mint: holds trading fees (protocol share + unclaimed cashback) and listing fees (+ unaccounted donations until swept). Created by `init_fee_vault` **after** the mint policy check (the handler creates it with system + `InitializeAccount3` CPIs instead of an Anchor `init`, which would run before the check), so a rejected mint never gets one. Lamports sent to the address beforehand do not block it (top up + allocate + assign, as Anchor's `init` does). A PDA rather than an ATA: anyone can create an ATA, so creating one could be front-run to block `init_fee_vault`. Other currencies have no fee vault: no fee is ever charged in them |

### 3.3 Instructions

| Instruction | Signer | Effect |
|---|---|---|
| `initialize_config` | admin | create `Config`, including `fee_mint` (non-default) |
| `init_fee_vault` | anyone (payer) | for `Config.fee_mint` only (`NotFeeMint`): run the mint extension allowlist, then create the fee vault `["fee_vault", fee_mint]` and the `FeeLedger` `["fees", fee_mint]`. Called once after `initialize_config`, and once after a timelocked fee-mint change. Emits `FeeVaultInitialized { fee_mint, fee_vault, fee_ledger }` |
| `submit_listing(asset_class, doc_hash)` | issuer | create `Listing{Pending}` for `Equity`/`FixedIncome`/`Credit`; require `issuer == asset_mint.mint_authority` and `supply == 0`; in the same instruction move the mint authority to the `["mint_authority", asset_mint]` PDA (`set_authority` CPI signed by the issuer) (§3.12) |
| `quote_listing(valuation, listing_fee_bps, expires_at)` | listing_authority | non-`Currency` listing `Pending` or `Quoted`: store the listing-fee quote, status `Quoted` (§3.13) |
| `pay_listing_fee` | `listing.issuer` | listing `Quoted`, quote not expired: pay the quoted fee into the fee vault; status `Approved` (§3.13). The only way an issuer listing is first approved |
| `request_issuance(amount, recipient, doc_hash)` | `listing.issuer` | listing `Pending`, `Quoted` or `Approved`: create the next `IssuanceBatch{Requested}` (§3.12) |
| `approve_issuance` / `reject_issuance` | listing_authority | approve: listing `Approved`, mint the batch to the recipient via the PDA, emit `IssuanceExecuted`; reject: close the request without minting (§3.12) |
| `burn_with_reason(amount, reason, reference)` | holder | burn own tokens of an issuer-listed asset with reason `Redemption`/`Cancellation`, emit `TokensBurned` (§3.12) |
| `list_currency(asset_mint)` | listing_authority | create an `Approved` `Currency` listing directly (stablecoin issuers such as Circle/Tether do not submit listings; Niara curates which currencies trade); `cashback_eligible = false`. Creates no fee vault: only the fee mint has one (`init_fee_vault`) |
| `approve_listing` / `suspend_listing` / `delist` | listing_authority | change status, emit event. `approve_listing` only reinstates (`Suspended` → `Approved`, any class, free) and refuses a `Pending` or `Quoted` listing (`ListingFeeNotPaid`, §3.13). `delist` from `Pending` or `Quoted` is how a listing is rejected |
| `freeze_cashback` / `unfreeze_cashback` | listing_authority | set / clear `listing.cashback_frozen` (§9.5). No timelock, any listing status, allowed while paused; fails on a `Currency` listing (`NotCashbackEligible`) and when the flag would not change (`CashbackAlreadyFrozen` / `CashbackNotFrozen`). Emits `CashbackFreezeSet { listing, asset_mint, frozen, listing_authority }` |
| `init_cashback_ledger` | anyone (payer) | create the `CashbackLedger` for (listing, `Config.fee_mint`) before the listing's first settlement or deal |
| `settle(match_id: [u8;16], asset_amount, payment_amount)` | settlement_operator | order-book mode: atomic swap via delegates; `payment_mint == Config.fee_mint`; `match_id` not all zeros (see 3.4) |
| `open_deal(deal_id, terms, expires_at)` | proposer | P2P mode: `FixedIncome`/`Credit`/`Currency` asset, `Approved` `Currency` payment, one leg in the fee mint (§3.4); `terms = { counterparty, proposer_side, asset_amount, payment_amount }`; `deal_id` not all zeros (`ZeroDealId`); `now < expires_at ≤ now + 30 days`; stores the current `fee_bps`/`cashback_bps` on the deal; proposer deposits its side into the deal vault (see 3.5). Emits `DealOpened` (with the stored rates) |
| `accept_deal` | `deal.counterparty` | P2P mode: counterparty delivers its side; same instruction swaps both legs, charges the fee on the fee-mint leg at the rates stored on the deal (not the current ones), accrues cashback, closes vault; only while `now < expires_at` (see 3.5). Emits `DealExecuted` |
| `cancel_deal` | `deal.proposer` (while `Open`) | refund deposit, close vault. Emits `DealCancelled` |
| `expire_deal` | anyone, once `now ≥ expires_at` | refund deposit to an account of the proposer, close vault (permissionless crank). Emits `DealExpired` |
| `withdraw_cashback(amount)` | `listing.issuer` | pull cashback from fee vault (≤ `accrued − withdrawn` of its `CashbackLedger`), to any account of the payment mint except the vault; reverts while `listing.cashback_frozen` (`CashbackFrozen`) |
| `withdraw_protocol_fees(amount)` | treasury | pull protocol share (≤ `fees_collected − cashback_accrued + listing_fees_collected − protocol_withdrawn` of the `FeeLedger`: the trading fees' protocol share plus every listing fee); can never touch issuers' cashback |
| `sweep_excess` | treasury | move the fee vault's balance above what the ledger owes (`balance − (fees_collected + listing_fees_collected − protocol_withdrawn − cashback_withdrawn)`, i.e. unaccounted donations) to any account of the payment mint except the vault; fails with `NothingToSweep` when there is none. Ledger untouched; afterwards invariant 4 holds with equality. Emits `ExcessSwept { treasury, payment_mint, destination, amount, vault_balance_after }` |
| `propose_change` / `execute_change` / `cancel_change` | admin | timelocked fee/cashback/operator/listing-authority/treasury/fee-mint changes (fee-mint switch: §3.4); the outgoing roles do not sign, so the admin alone can rotate a leaked key. An `Admin` change is proposed and cancelled here, but `execute_change` refuses it (`AdminChangeNeedsAcceptance`) |
| `accept_admin` | the proposed admin | second step of an admin transfer: once the timelock of a pending `ConfigChange::Admin(new_admin)` has elapsed, `new_admin` signs and becomes `Config.admin` (`NotPendingAdmin` for any other signer). Proves the new key can sign, so a typo cannot lose the admin. The new admin only signs (pays nothing, is not written), so a Squads v4 vault can accept through a vault transaction. The pending account's rent goes back to the outgoing admin. Emits `ChangeExecuted` |
| `pause` / `unpause` | admin | circuit breaker (see below) |

**Pause principle.** A pause stops the protocol from paying out based on its
own accounting, but never stops a user from taking back their own escrowed
deposit. While `paused`:
- **blocked:** `settle`, `open_deal`, `accept_deal`, `withdraw_cashback`,
  `withdraw_protocol_fees`, `sweep_excess`, `approve_issuance`,
  `pay_listing_fee`. If the
  incident is an accounting bug (e.g. over-credited cashback), withdrawals are
  exactly the drain path; minting is the highest-impact action there is.
  `pay_listing_fee` writes to the same fee ledger and vault, and it would
  make a new listing tradable in the middle of an incident.
- **always allowed:** `cancel_deal` and `expire_deal` (a user reclaims their own
  deposit, which the protocol's accounting does not decide), `burn_with_reason`
  (a holder destroys its own tokens), listing actions (`submit_listing`,
  `quote_listing`, `list_currency`, `approve_listing`, `suspend_listing`,
  `delist`, `freeze_cashback`, `unfreeze_cashback`),
  `request_issuance` and `reject_issuance` (neither mints),
  `init_cashback_ledger`, `init_fee_vault`, and admin/timelock actions
  (including `accept_admin`).

Listing status gates trading, not payouts: accrued cashback and protocol fees
stay withdrawable after the asset is delisted or the currency is suspended.
The per-listing cashback freeze (§9.5) is the one listing-level switch on
payouts: it stops `withdraw_cashback` for that listing only, and never
trading or accrual.

### 3.4 `settle` — the core

**Fee currency (v1): always USDT.** `Config.fee_mint` is the USDT mint. Every
fee, and therefore all cashback, is charged in it, in both trading modes:
- **Which trades are allowed.** `settle` and `FixedIncome`/`Credit` deals
  require `payment_mint == fee_mint`. A `Currency` deal requires **exactly
  one** leg in the fee mint: BRL ↔ USDT is fine either way round, BRL ↔ EUR is
  rejected in v1 (`NotFeeMint`). The fee mint must also have an `Approved`
  `Currency` listing like any payment mint, so suspending the USDT listing
  stops USDT trading.
- **Who pays.** The party that **receives** USDT pays the fee, deducted from
  the USDT it receives: `fee = ceil(usdt_amount × fee_bps / 10_000)`, it gets
  `usdt_amount − fee` (must be `> 0`, `ZeroSellerProceeds`), and the other
  party receives its own leg in full. In `settle` and in `FixedIncome`/`Credit`
  deals that is the seller (USDT is the payment). In a `Currency` deal it is
  whoever receives USDT: the seller when USDT is `payment_mint`, the buyer
  when USDT is the currency sold (`asset_mint`).
- **How much.** At most **0.5%**: `fee_bps ≤ MAX_FEE_BPS = 50`. It is a
  business rule (Niara charges at most 0.5%), enforced as a constant of the
  program: `initialize_config` and `propose_change` reject a higher rate
  (`FeeTooHigh`), `execute_change` re-validates it, and a deal stores the
  rate of its `open_deal`, so no trade can ever be charged more. Raising the
  cap takes a program upgrade, not a config change.
- **Cashback** is a share of the fee, so it is in USDT too; only
  cashback-eligible listings (never `Currency`) accrue it.
- **One fee vault, one fee ledger** (`["fee_vault", fee_mint]`,
  `["fees", fee_mint]`), created by `init_fee_vault`; cashback ledgers are
  `["cashback", listing, fee_mint]`. Other currencies get no fee vault.
  Listing fees (§3.13) go into the same vault and ledger, in their own
  counter (`listing_fees_collected`).
- **Fee-mint switch** (`ConfigChange::FeeMint`, timelocked like any config
  change). The seeds keep the mint, so a switch never mixes two currencies in
  one account: after `execute_change`, `init_fee_vault` creates the new mint's
  vault and ledger and `init_cashback_ledger` the new cashback ledgers. Fees
  and cashback already collected stay in the old vault and stay withdrawable
  through the old ledgers (withdrawals and `sweep_excess` are keyed by mint,
  not by `Config.fee_mint`). Deals still open whose USDT leg is the old mint
  can no longer be accepted (`NotFeeMint`); they are cancelled or expire as
  usual. Likewise an open listing-fee quote is in the old mint's units and
  can no longer be paid (`NotFeeMint`); the listing authority re-quotes
  (§3.13). It is a migration tool (e.g. a redeployed test USDT), not something
  routine.
- Multi-currency payment with fee conversion (e.g. charging the fee of a
  BRL ↔ EUR deal in USDT) needs a price oracle and is out of v1 (§3.10).

`match_id` is the off-chain **match (fill) id**, a 16-byte UUID (the
`matches.id` primary key), not the maker's order id: one order can be filled by
several matches, and each match settles at most once. An all-zero id is
rejected (`ZeroMatchId`): it is what an unset field looks like, never a real
UUID, and the EVM `settle` rejects a zero `matchId` too (§4.2). `payment_amount` is in
raw units of the payment mint; the program does no price conversion.

Preconditions (all enforced on-chain):
- `!config.paused`; signer is `config.settlement_operator`
- `match_id != [0; 16]` (`ZeroMatchId`)
- `asset_amount > 0`, `payment_amount > 0`
- `buyer != seller`; neither is the vault authority
- `["settled", match_id]` does not exist yet (replay guard: the operator
  cannot settle the same match twice, even within the delegated amounts)
- asset listing: `status == Approved`, `asset_class == Equity`,
  `listing.asset_mint == asset_mint`
- payment mint: `payment_mint == config.fee_mint` (`NotFeeMint`), and it has
  a listing with `asset_class == Currency` and `status == Approved`
- mint policy re-run on both mints (extension allowlist; asset mint has no
  freeze authority)
- token accounts: correct owner (buyer/seller wallet), correct mint, correct
  token program; fee vault and cashback ledger are the PDAs for the fee mint
  (and this listing)
- seller's asset account `delegate == vault_authority` and `delegated_amount ≥ asset_amount`
- buyer's payment account `delegate == vault_authority` and `delegated_amount ≥ payment_amount`

Math (checked, `u128` intermediates):
```
fee      = ceil(payment_amount * fee_bps / 10_000)      // never zero by truncation when fee_bps > 0
cashback = listing.cashback_eligible ? floor(fee * cashback_bps / 10_000) : 0
seller_receives = payment_amount - fee
```
`settle` requires `seller_receives > 0` (`ZeroSellerProceeds`): because the fee
rounds up, a 1-unit payment with `fee_bps > 0` would otherwise hand the asset
over for nothing. The escrow (`accept_deal`) applies the same rule.

CPIs, all in one transaction (atomic — any failure reverts everything).
Each `transfer_checked` uses its own mint's decimals; zero-amount legs (e.g.
`fee` when `fee_bps == 0`) are skipped:
1. `transfer_checked` asset: seller → buyer (authority = vault PDA as delegate)
2. `transfer_checked` payment: buyer → seller, `seller_receives`
3. `transfer_checked` payment: buyer → fee vault, `fee`
4. `FeeLedger.fees_collected += fee`, `FeeLedger.cashback_accrued += cashback`,
   `CashbackLedger.accrued += cashback`
5. `emit_cpi!(Settled { match_id, asset_mint, payment_mint, buyer, seller, asset_amount, payment_amount, fee, cashback })`

### 3.5 Custody model — DECISION (2026-10-22): delegate for listing, escrow for P2P

**Order book → SPL delegate.** An offer goes live when the owner approves the
exact amount to the vault PDA; tokens stay in the wallet until `settle`.
Known limitations, handled explicitly:
- **One delegate per token account.** Several open orders of the same asset need
  an aggregate approval (sum of open sizes). Approving another dApp overwrites
  Niara's delegate and silently invalidates the orders.
- **Revocable at any time.** The matching engine must check `delegate` and
  `delegated_amount` on-chain before matching, and mark orders `stale` if the
  check fails. `settle` re-checks on-chain anyway, so a stale order fails
  safely (reverts, nothing moves).

**P2P negotiation → per-deal escrow.** Used when two parties negotiate a
bilateral deal (OTC / block trade / counteroffers):
1. `open_deal`: the proposer deposits its side (asset if selling, payment if
   buying) into a vault owned by the `Deal` PDA. The deposit is cancelable
   while `Open`, so custody stays non-custodial.
2. `accept_deal`: the counterparty signs. One instruction transfers the
   counterparty's side directly, releases the escrowed side, charges the fee,
   accrues cashback, closes the vault (rent back to the proposer) and emits
   `DealExecuted`.
3. `cancel_deal` / `expire_deal`: refund after cancellation or after `expires_at`.

**P2P escrow rules (v1, implemented).**
- **Markets.** The asset listing must be `Approved` and `FixedIncome`,
  `Credit` or `Currency` (`WrongTradingMode` for `Equity`); the payment mint
  must have an `Approved` `Currency` listing (`InvalidPaymentMint`), the
  two mints must differ (`SameMint`), and one leg must be the fee mint
  (`NotFeeMint`, §3.4): the payment for `FixedIncome`/`Credit`, either leg for
  `Currency`. `open_deal` and `accept_deal` re-run the
  mint extension allowlist on both mints, and the freeze-authority check on
  issuer-listed assets (a `Currency` sold as the asset may have one, like any
  listed currency, §3.8).
- **Currency deals** (e.g. BRL ↔ USDT): `asset_mint` is the currency being
  sold, `payment_mint` the other one; exactly one of them is USDT. The fee is
  charged in USDT, on whichever leg it is, and paid by the party receiving it
  (§3.4); the cashback is zero (`Currency` is never cashback-eligible, so no
  `CashbackLedger` exists for it; `accept_deal` takes the ledger as an
  optional account and requires it only for eligible listings,
  `MissingCashbackLedger`).
- **Bilateral, named counterparty.** v1 has no open offers: `open_deal` names
  the counterparty, which must not be the proposer (`SelfTrade`) or the
  default key (`InvalidAddress`); only that wallet can `accept_deal`
  (`Unauthorized`). `deal_id` is the 16-byte off-chain negotiation id, scoped
  to the proposer (`["deal", proposer, deal_id]`); an all-zero `deal_id` is
  rejected (`ZeroDealId`), like a zero match id in `settle` (§3.4).
- **Expiry.** `now < expires_at ≤ now + 30 days` at `open_deal`
  (`InvalidExpiry`, `MAX_DEAL_DURATION_SECS`). The deal is live while
  `now < expires_at` (`accept_deal` fails with `DealExpired` from
  `expires_at` on) and expirable once `now ≥ expires_at` (`expire_deal` fails
  with `DealNotExpired` before): no gap and no overlap (invariant 7).
- **Custody.** `open_deal` creates the vault `["deal_vault", deal]`, a token
  account of the deposited mint whose authority is the `Deal` PDA, and moves
  the deposit into it (the proposer signs). On `accept_deal` the counterparty
  signs and delivers its side **directly** from its own accounts (no
  delegate); the vault is released by the `Deal` PDA.
- **Execution** (`accept_deal`, one instruction, atomic), with the same math
  as `settle` (§3.4) and the rates stored on the deal at `open_deal`
  (`deal.fee_bps`, `deal.cashback_bps`), applied to the
  **USDT leg** (`usdt_amount` = `payment_amount`, or `asset_amount` when the
  currency sold is USDT): `fee = ceil(usdt_amount × fee_bps / 10_000)`, the
  USDT receiver's share `usdt_amount − fee > 0` required
  (`ZeroSellerProceeds`, checked at `open_deal`; since the rates cannot change
  afterwards, a deal that opens can always pay its fee), cashback by
  `listing.cashback_eligible`. Two legs, each moved in full
  except that the USDT leg is split between its receiver and the fee vault:
  - **escrowed leg**: vault → counterparty (deposit, minus `fee` if it is the
    USDT leg, plus any `vault_excess`); vault → fee vault (`fee`, if USDT leg).
  - **delivered leg**: counterparty → proposer (its side, minus `fee` if it
    is the USDT leg); counterparty → fee vault (`fee`, if USDT leg).
  For `FixedIncome`/`Credit` (USDT = payment) that reads: proposer sells →
  the counterparty pays `seller_receives` to the proposer and `fee` to the fee
  vault; proposer buys → the vault pays `seller_receives` to the counterparty
  and `fee` to the fee vault. `DealExecuted` reports `fee_mint`.
  Then `FeeLedger`/`CashbackLedger` are updated as in `settle`, the vault is
  closed (rent to the proposer) and the deal becomes `Executed`.
- **Refunds.** `cancel_deal`: proposer only (`Unauthorized`), while `Open`
  (also after `expires_at`, as long as nobody expired it first).
  `expire_deal`: anyone, once expired; the refund can only go to a token
  account owned by the proposer. Both return the deposit, close the vault
  (rent to the proposer) and set `Cancelled` / `Expired`. Neither reads
  `Config` or the listings, so a pause or a suspended/delisted listing never
  blocks them (§3.3), while it does block `open_deal` and `accept_deal`.
- **Tokens sent to a vault.** Anyone can transfer into a deal vault, and a
  token account can only be closed empty, so such tokens would otherwise
  block every exit and strand the deposit. Every exit therefore releases the
  vault's whole balance: the excess goes with the deposit (counterparty on
  accept, proposer on cancel/expiry) and is reported as `vault_excess` in the
  event.
- **Replay.** The `Deal` account is never closed: once it leaves `Open` it
  can be neither accepted nor refunded again (the vault is closed at that
  point, so the account checks already fail), and the same `deal_id` cannot be
  reopened by the same proposer. No `SettlementRecord` is involved. The
  proposer pays the deal's rent (~0.0023 SOL: 200 bytes + account overhead)
  for good and gets the vault's rent back.
- **The fee is part of the agreed terms.** `open_deal` copies `fee_bps` and
  `cashback_bps` from `Config` onto the deal and `accept_deal` charges those,
  so a timelocked fee or cashback change executed while the deal is open does
  not affect it: both parties agreed on a net amount, and the counterparty
  sees the rates in the `Deal` account (and in `DealOpened`) before it
  accepts. Deals opened after the change use the new rates. (In order-book
  mode the fee is read at `settle`; there are no stored terms to keep.) The
  fee *mint* is not snapshotted: after a fee-mint switch a deal in the old
  mint can only be refunded (§3.4).
- **Events.** `DealOpened` (with `fee_bps` and `cashback_bps`), `DealExecuted` (with `fee_mint`, `fee`,
  `cashback` and `vault_excess`; same accounting as `Settled`), `DealCancelled`,
  `DealExpired`.

Why this split is sound: in P2P mode **both parties sign their own transaction**,
so no operator and no trust assumption are needed. That mode is fully trustless
at settlement. Order-book mode keeps tokens in the wallet and allows the maker to
be offline, at the cost of trusting the operator on price (see 3.6).

Off-chain negotiation (proposals, counteroffers, chat) lives in Supabase; only
the agreed terms go on-chain at `open_deal`.

### 3.6 Trust assumption — signed order intents

Applies to **order-book mode only** (P2P escrow mode needs no operator).
With delegates (and with EVM allowances), the operator can settle **within** the approved
amounts but could, in theory, pick a worse price than the user intended. Fix:
users sign an **order intent** (Solana: `signMessage` ed25519, verified on-chain via
the Ed25519 program + instructions sysvar; EVM: EIP-712, verified with `ecrecover`).
`settle` then checks the trade respects both signed intents.

- v1 target: **implement if time allows (week 5)**.
- If not implemented: state it as a **documented trust assumption** ("the
  settlement operator is trusted to respect matched prices; signed intents are
  the next milestone"). Never claim trustless settlement without it.

**Program upgrade authority (applies to both modes).** Whoever holds the
program's upgrade authority can replace the program, and with it every rule
above, including the admin timelock: an upgrade takes effect immediately and is
not subject to `propose_change` / `execute_change`. In v1 (testnet) the upgrade
authority is a **single key**, and the same key is the one allowed to call
`initialize_config`. Before mainnet the upgrade authority and the admin
**must** move to a **Squads multisig** (ideally with its own time delay),
rehearsed on devnet first (§9.6); after audit the program may also be made
immutable (freeze the upgrade authority). Until then, "timelocked admin" must
always be stated together with "single-key upgrade authority".

### 3.7 Future compliance layer (talking point, not v1)

Token-2022 extensions give Solana-native securities controls:
- **DefaultAccountState (frozen)** — new holder accounts start frozen; thawed after KYC.
- **TransferHook** — every transfer calls a program that enforces allowlists/lock-ups
  (the Solana equivalent of `RestrictedTransferPolicy` in niara-contracts-PMEs).
- **Metadata** — on-mint instrument metadata.

Note: the v1 mint extension allowlist (§3.8) rejects `DefaultAccountState` and
`TransferHook`. Adopting this compliance layer therefore means revisiting the
allowlist and the settlement/escrow design (e.g. thaw handling, hook accounts
in CPIs, a vetted hook program) — not just enabling the extensions.

### 3.8 Security checklist (Anchor)

- Typed accounts (`Account<>`, `InterfaceAccount<>`), `has_one`, seeds + stored bump
- Owner/mint/token-program checks on every token account
- Checked arithmetic everywhere; no `unwrap` on user-controlled math
- Avoid `init_if_needed` unless strictly necessary (re-init risks); prefer explicit init
- PDA signer only through `CpiContext::new_with_signer` with the vault seeds
- Timelock reads `Clock::get()?.unix_timestamp`
- **Mint extension allowlist** (implemented in `mint_policy.rs`, enforced by
  `submit_listing`, `list_currency` and `init_fee_vault`). Accepted: SPL Token mints, and
  Token-2022 mints whose only extensions are `MetadataPointer` and/or
  `TokenMetadata`. Everything else is rejected with `UnsupportedMintExtension`,
  including extension types the program does not know. It is an allowlist, not
  a denylist, so a future Token-2022 extension is rejected by default.

  | Rejected extension | Why |
  |---|---|
  | `PermanentDelegate` | the delegate can transfer or burn from any account, so it can drain escrow vaults |
  | `TransferFeeConfig` | the receiver gets less than the amount sent, which breaks `payment_amount == seller_receives + fee` |
  | `TransferHook` | runs third-party code inside settlement |
  | `DefaultAccountState` (frozen), `Pausable` | frozen or paused state can strand a settlement or an escrowed deposit |
  | `NonTransferable` | the token cannot move, so settlement can never succeed |
  | `ConfidentialTransferMint` | hidden balances the program cannot check |
  | `MintCloseAuthority` | the mint can be closed (and its address reused) under a live listing |
  | any other or unknown type | not reviewed, so not accepted |

  Extensions are checked at listing time, before the listing creates anything
  for the mint, and by `init_fee_vault` before it creates the fee vault, so
  every rejected mint fails with `UnsupportedMintExtension` on every path. Token-2022 cannot add the rejected
  extensions to a mint after initialization, so the check holds for the life of
  the listing; `settle`, `open_deal` and `accept_deal` still re-run it on both
  the asset and the payment mint as defense in depth, and `pay_listing_fee`
  on the fee mint.
- **Freeze authority.** The extension allowlist does not cover the base mint's
  `freeze_authority`. Asset mints (`submit_listing`) must have
  `freeze_authority == None`, otherwise the issuer could freeze escrow vaults,
  fee vaults or holders' accounts mid-settlement (`FreezeAuthorityNotAllowed`).
  Neither token program can add a freeze authority once it is `None`, so the
  check holds for the life of the listing; `settle`, `open_deal` and
  `accept_deal` re-check it. Currency mints
  (`list_currency`) **may** have one, because real stablecoins do (USDC, USDT):
  this is an accepted, curated risk, also when a currency is the asset leg of
  a P2P deal. A currency issuer can freeze a fee vault, a deal vault or a
  user's account, which makes settlements, deals, refunds and withdrawals in
  that currency revert (nothing moves) until it unfreezes; a deposit in a
  frozen deal vault stays there until then.

### 3.9 Testing

- Unit/integration: LiteSVM (Rust, `cargo test` after `anchor build`; fast, deterministic)
- Invariant/property testing: **`proptest` over LiteSVM** — random sequences of
  instructions (valid and invalid) against the real `.so`, with the invariants
  below checked after every step; same role Foundry invariant fuzzing plays in
  niara-contracts. Trident is not used: as of 2026-11 its latest stable release
  (0.12.0) targets Solana 2.3 crates and documents no Anchor 1.x support.
  Re-evaluate if that changes.
- Implemented (week 2): `tests/test_invariants.rs` builds a world with two
  `Equity` listings (SPL Token, Token-2022), one `FixedIncome`, one `Credit`
  and three `Currency` listings (USD, the fee mint, under a token program
  drawn per case; BRL; EUR), plus a delegated buyer/seller pair for every
  asset × payment combination (including invalid ones), then runs random
  sequences of `settle` (valid and invalid markets, zero amounts, replayed
  and all-zero ids, wrong signer, fills that leave the seller nothing), listing status
  changes, pause/unpause, both withdrawals (incl. overdraws and wrong signers),
  timelocked fee/cashback changes with out-of-range values, re-delegations,
  `init_cashback_ledger`, donations straight into the fee vault and
  `sweep_excess` (incl. wrong signers and empty sweeps; withdrawals and
  sweeps are also aimed at BRL/EUR, which have no fee vault and must always
  fail), and issuance on the
  four issuer listings: `request_issuance` (incl. zero amounts, wrong
  signers, suspended/delisted listings), `approve_issuance`/`reject_issuance`
  of the oldest open batch (incl. wrong signers, non-`Approved` listings,
  paused protocol) and `burn_with_reason` (incl. overdraws). Listing fee
  (§3.13): the four trading listings are approved by quote and payment at
  setup, and three more issuer listings (`Equity`, `FixedIncome`, `Credit`)
  start `Pending`; random `quote_listing` (zero valuation, rates of 0 or
  above the 1% cap, expiries in and out of the 30-day window, wrong
  signers, already-paid and `Currency` listings) and `pay_listing_fee`
  (wrong signers, expired quotes, paused, double payment) have their
  outcome predicted exactly, as do the listing status actions, so
  `approve_listing` never approves an unpaid listing; issuance on the new
  listings is requested while `Pending` or `Quoted` and executes only once
  paid. Invariants 1 to 13 are checked after every step (4 as `vault ==
  unwithdrawn + unswept donations`, so strict equality after every sweep; 11
  also checks the mint authority is still the program PDA; 13 also
  cross-checks the ledger's listing fees against the `ListingFeePaid`
  events), the fee ledgers
  are cross-checked against the sum of `Settled` events, and
  `issued`/`burned` against `IssuanceExecuted`/`TokensBurned`. `PROPTEST_CASES`
  sets the number of sequences (default 48). A mutation check (cashback
  under-recorded in the `FeeLedger`) made it fail and shrink to a minimal
  sequence.
- Escrow (week 3): `tests/test_deal.rs` covers every market (bond, credit
  and BRL paid in USDT; USDT sold for BRL) × side × token program
  combination, the expiry boundary, replays, pause and listing status
  (blocking open/accept, never cancel/expire), every authorization and
  account check, deals without a USDT leg, tokens sent straight into a
  deal vault, and the fee snapshot (a fee or cashback change, up or down,
  executed while a deal is open does not apply to it; a deal opened at fee 0
  still executes after a raise; deals opened afterwards get the new rates).
  The invariant
  fuzzer mixes random deals into the sequences above: one proposer /
  counterparty pair per P2P pair (six valid markets: bond and credit paid in
  USD, and BRL/EUR against USD in both directions, so the fee sits on the
  payment leg or on the asset leg; and nine invalid ones: no USD leg
  (bond/credit paid in BRL/EUR, BRL ↔ EUR), `Equity` asset, `Equity` or
  `FixedIncome` payment, same mint), `open_deal` with zero amounts, reused
  and all-zero ids and expiries in and out of the 30-day window, then `accept_deal`,
  `cancel_deal` and `expire_deal` on tracked deals (wrong signers, a crank
  naming its own refund account, replays of resolved deals) and donations
  into deal vaults. The outcome of every escrow call is predicted exactly
  from the model (status, pause, listings, clock, and the fee rates recorded
  at open, checked against the `Deal` account and `DealOpened`; fee changes
  are interleaved, and a deal that opened must always be able to pay its
  fee), so invariant 7 and the
  pause principle are checked on every call; invariant 6 is checked after
  every step by modelling every party's balances (a deposit stranded or paid
  twice breaks the model), requiring each open deal's vault to hold exactly
  its deposit plus donations and each resolved deal's vault to be closed.
  `DealExecuted` fees and cashback feed the same fee-ledger cross-check as
  `Settled`. A deterministic test accepts, cancels and expires one deal per
  valid pair and side. Mutation check: refunding the deposit without the
  donated excess in the model made both tests fail and shrink.
- Fee mint (USDT): `tests/test_fee_ledger.rs` covers `init_fee_vault`
  (permissionless, once, only for `Config.fee_mint`, mint policy first,
  pre-funded address, while paused), one ledger for every listing and both
  modes, and a timelocked fee-mint switch (old vault still withdrawable,
  old-mint deals refund-only, new trades in the new vault).
- Listing fee (§3.13): `tests/test_listing_fee.rs` covers quote then pay
  for each issuer class and both token programs (stored quote,
  `ListingQuoted`, `ListingFeePaid` then `ListingApproved`, vault and
  ledger), rounding up, the 1% cap and a zero rate, a zero valuation, the
  expiry boundary of the quote (`now < expires_at ≤ now + 30 days`) and of
  the payment (payable while `now < quote_expires_at`), re-quoting (also
  after expiry), wrong signers on both instructions and a rotated listing
  authority, `Currency` listings in every status, the source account
  (owner, mint, balance) and the vault, any other mint and a fee-mint switch
  that voids an open quote, pause (quote allowed, pay blocked), payment
  without a quote, double payment, rejection by delisting, the
  `approve_listing` bypass and free reinstatement, no trading while
  `Quoted`, and the treasury withdrawing listing fees (never cashback). The
  fixtures approve every issuer listing by quote and payment
  (`approve_paid`), so every suite runs with listing fees in the fee vault.
- Build: `scripts/build.sh` wraps `anchor build`, deletes the `.so`/IDL first and
  fails unless fresh artifacts exist, so tests never run against a stale binary.
- Invariants (must hold under fuzzing):
  1. `payment_amount == seller_receives + fee` for every settlement
  2. `Σ cashback accrued ≤ Σ trading fees collected` per fee mint
     (`FeeLedger.cashback_accrued ≤ FeeLedger.fees_collected`, and
     `FeeLedger.cashback_accrued == Σ CashbackLedger.accrued` for that mint).
     Listing fees never accrue cashback, so they are not on the right-hand side
  3. no settlement on a listing whose status ≠ `Approved`
  4. vault balance == unwithdrawn trading fees + listing fees + cashback
     (`fees_collected + listing_fees_collected − protocol_withdrawn −
     cashback_withdrawn`). Anyone can
     transfer into a fee vault, so between sweeps this is `≥`; donations are
     not accounted and cannot be withdrawn as fees or cashback.
     `sweep_excess` moves them to the treasury, and **after a sweep it is
     strict equality**. Fuzzing tracks donations and checks
     `vault == unwithdrawn + unswept donations`
  5. `fee_bps ≤ MAX_FEE_BPS` (50 bps, 0.5%) always, even after timelocked
     changes; fuzzing also checks it on every fee charged
     (`fee ≤ ceil(0.5% × amount)`) and on the rate stored in every deal
  6. an escrowed deposit always ends in exactly one place: counterparty (executed)
     or proposer (cancelled/expired). It is never stranded and never paid twice
  7. no `accept_deal` after `expires_at`; no `expire_deal` before it
  8. mode/class coupling: `settle` never succeeds on a non-`Equity` listing;
     `open_deal`/`accept_deal` never succeed on an `Equity` listing
  9. a `Currency` listing never accrues cashback
  10. `settle` and the escrow instructions only accept a payment mint that has an
      `Approved` `Currency` listing
  11. issuance: `asset_mint.supply == listing.issued − listing.burned`, i.e.
      Σ executed batches − Σ `burn_with_reason`. A holder can still burn
      directly through the token program, so on-chain this is `≤` (§3.12);
      tests and fuzzing have no direct burns and check `==`. No batch executes
      unless the listing is `Approved` and the protocol is not paused
  12. fees are only ever charged in `Config.fee_mint` (USDT): no `FeeLedger`
      or fee vault exists for any other mint, every executed trade has one
      leg in the fee mint, and the party receiving that leg gets
      `amount − fee` while the other party receives its leg in full. Listing
      fees too: `pay_listing_fee` only takes the fee mint
  13. listing fee (§3.13): `listing_fee_paid` is 0 until `pay_listing_fee`
      and then equals
      `listing_fee == ceil(valuation × listing_fee_bps / 10_000)`, with
      `1 ≤ listing_fee_bps ≤ MAX_LISTING_FEE_BPS`; every non-`Currency`
      listing that is `Approved` or `Suspended` has paid; no listing pays
      twice; and per fee mint,
      `Σ listing_fee_paid == FeeLedger.listing_fees_collected`

### 3.10 Out of v1 scope (state it, don't fake it)

Security and token-lifecycle work (guardian role, issuer compromise and
recovery, Niara-created mints with a recovery delegate, cashback protection,
the production cybersecurity program) is in §9, and so is the product vision
(neobank services, wallet service, target chains, price oracle, regulatory
dependencies).

- Fixed income / credit **lifecycle**: coupon payments, amortization, maturity
  redemption, default handling. In v1 these tokens trade but do not pay out;
  the lifecycle (snapshot of holders + on-chain distribution) is roadmap.
- FX pricing feeds: P2P deals in `Currency` use the rate the two parties agree;
  no oracle in v1 (roadmap: §9.10).
- **Multi-currency payment.** v1 charges every fee in USDT, so `settle` pays
  only in USDT and a `Currency` deal needs a USDT leg (§3.4). Paying in other
  currencies (BRL ↔ EUR deals, equities priced in BRL) while still charging
  the fee and the cashback in USDT needs a **price oracle** to convert the fee
  on-chain (e.g. Pyth or Switchboard feeds, with staleness and confidence
  checks), or per-currency fee vaults with their own cashback ledgers (which
  v1 removed). Roadmap (§9.10). In Brazil, FX is regulated by the BCB (Lei 14.286/2021 and the
  VASP rules), which matters for production but not for testnet.
- **Bitmap replay protection.** Each settlement creates a `SettlementRecord`
  that is never closed: ~0.00095 SOL of rent per settlement (rent-exempt
  minimum for 9 data bytes) locked forever, growing linearly with volume.
  Roadmap: replace the per-settlement records with bitmap pages (e.g. a
  `["settled_page", page_no]` account of N bits, with the match id mapped to a
  sequence number assigned by the matching engine), so one rent-exempt account
  covers thousands of settlements. Needs a sequence space the operator cannot
  rewind; until then, one record per match is the simple, auditable choice.
- **Evaluate `solana-v4`.** v1 builds against the Solana 3.x crates (Anchor's
  default `solana-v3` feature). Moving to the `solana-v4` (Agave 4.3) crates is a
  roadmap item, to be evaluated once the program is feature-complete.

### 3.11 Toolchain (pinned)

| Component | Version | Notes |
|---|---|---|
| Anchor (CLI + `anchor-lang`/`anchor-spl`) | **1.2.2** | pinned per project in `Anchor.toml` `[toolchain] anchor_version`, as `=1.2.2` in the program's `Cargo.toml`, and in the committed `Cargo.lock` (every `anchor-*` crate resolves to 1.2.2, no 1.2.1 entries; checked 2026-11-09); installed with `avm` (includes the `close`-into-self and `init_if_needed` Token-2022 fixes) |
| Solana crates | **3.x** (`solana-v3`, Anchor default) | `solana-v4` not enabled; see roadmap |
| Solana CLI | **4.3.0** (Agave) | not pinned in `[toolchain]` (pinning `solana_version` switches the machine-wide active release) |
| Rust | **1.99.1** | `anchor-lang` MSRV is 1.89 |
| Tests | **LiteSVM** (Rust) | Anchor 1.x default template |
| TypeScript client | **`@anchor-lang/core`** 1.2.x | replaces `@coral-xyz/anchor` |

### 3.12 Niara-approved issuance

Native issuance (§1) means the token *is* the instrument, so whoever can mint
can create securities. In v1 neither the issuer nor Niara can mint alone: the
issuer proposes, Niara approves, and only the program executes.

**Mint authority hand-over.** `submit_listing` requires `supply == 0` and, in
the same instruction, moves the mint authority from the issuer to the program
PDA `["mint_authority", asset_mint]` with a `set_authority` CPI signed by the
issuer (who is still the mint authority at that point). From then on nobody can
mint outside the program: the issuer's own `MintTo` fails with the token
program's `OwnerMismatch`, and no instruction of the program ever moves the
authority again. Consequences, stated rather than hidden:
- The issuer must finish any mint setup that needs the mint authority (e.g.
  initializing `TokenMetadata`) before submitting.
- The hand-over is permanent. A listing rejected while `Pending` or
  `Quoted` (delisted) leaves an empty mint nobody can use; the issuer
  creates a new mint. A
  delisted asset keeps its supply (holders can still burn) but never grows.
- Freeze authority is already `None` for asset mints (§3.8), so the mint
  authority is the only authority left on the mint.

**Batches.** Every increase of supply is a numbered `IssuanceBatch`
(`["batch", listing, batch_no]`, `batch_no` as `u64` little-endian):

| Instruction | Signer | Effect |
|---|---|---|
| `request_issuance(amount, recipient, doc_hash)` | `listing.issuer` | listing `Pending`, `Quoted` or `Approved`; `amount > 0`, non-empty `doc_hash`, `recipient` not the default key. Creates batch `listing.next_batch_no` (`Requested`) and increments the counter. Mints nothing. Emits `IssuanceRequested` |
| `approve_issuance` | `listing_authority` | batch `Requested` and listing `Approved`; blocked while paused. Mints `amount` to a token account of the asset mint owned by `recipient` (`mint_to_checked`, signed by the mint-authority PDA); `listing.issued += amount`; batch `Executed`. Emits `IssuanceExecuted { asset_mint, batch_no, amount, recipient, doc_hash, destination }` |
| `reject_issuance` | `listing_authority` | batch `Requested` → `Rejected`; mints nothing. Any listing status, not blocked by pause. Emits `IssuanceRejected` |
| `burn_with_reason(amount, reason, reference)` | holder (token account owner) | non-`Currency` listing, any status; `amount > 0`, non-empty `reference`; `burn_checked` from the holder's account; `listing.burned += amount`. `reason`: `Redemption` \| `Cancellation`. Emits `TokensBurned { asset_mint, holder, holder_account, amount, reason, reference }` |

- Batch numbers start at 1 and are sequential per listing: the batch PDA is
  derived from `listing.next_batch_no`, so a number can be neither skipped nor
  reused. Requested, executed and rejected batches stay on-chain as the
  issuance record (rent paid by the issuer, never closed).
- `doc_hash` is the hash of the document that authorizes the batch (e.g. the
  corporate act approving a capital increase or a debenture series), registered
  in Niara-Register; `reference` plays the same role for a burn.
- Batches may be requested while the listing is `Pending` or `Quoted` (the
  initial offering can be prepared before approval) but execute only once it
  is `Approved`, i.e. once the listing fee is paid (§3.13). A `Suspended`
  listing keeps its requests; they execute after reinstatement or are
  rejected. Batches charge no listing fee.
- Pause: `approve_issuance` is blocked (minting is the highest-impact action
  there is); `request_issuance`, `reject_issuance` and `burn_with_reason` are
  allowed (none pays out on the protocol's accounting; a burn only destroys
  the holder's own tokens).
- `Currency` listings have no issuer that can sign and their mint authority is
  not the program's, so they have no issuance; `burn_with_reason` rejects them
  (`CurrencyNotIssued`).

**State.** `Listing` gains `next_batch_no: u64` (1 after `submit_listing`, 0 for
`Currency`), `issued: u64` (Σ executed batches) and `burned: u64` (Σ
`burn_with_reason`). `IssuanceBatch`: `listing`, `batch_no`, `amount`,
`recipient` (wallet, the holder of record), `doc_hash`, `status`
(`Requested`/`Executed`/`Rejected`), `requested_at`, `resolved_at`, `bump`.

**Invariant 11.** `asset_mint.supply == listing.issued − listing.burned`.
Limit: SPL Token and Token-2022 both let an owner burn its own tokens directly,
which the program can neither block nor observe. On-chain the invariant is
therefore `supply ≤ issued − burned`, with equality while every burn goes
through `burn_with_reason`. A gap is an unexplained burn: the Register flags a
supply decrease with no matching `TokensBurned`. Tests check equality (and one
test shows the gap a direct burn opens).

**Test fixtures.** Trading tests write token balances directly into accounts
(no mint), so their asset mints have balances without supply. Invariant 11 is
checked only on assets issued through batches.

### 3.13 On-chain listing fee

Decision (2026-11-13): the listing fee (§1) is charged on-chain, and paying
it is what approves an issuer listing. It replaces the off-chain charge that
the Register used to record.

**Flow.** `submit_listing` (issuer; `Pending`, unchanged) → `quote_listing`
(listing authority; `Quoted`) → `pay_listing_fee` (issuer; `Approved`).
`Currency` listings keep their path: `list_currency` creates them `Approved`,
and they pay no listing fee.

| Instruction | Signer | Effect |
|---|---|---|
| `quote_listing(valuation, listing_fee_bps, expires_at)` | listing_authority | non-`Currency` listing (`CurrencyHasNoListingFee`) in status `Pending` or `Quoted` (`InvalidStatusTransition`); `valuation > 0`, in base units of the fee mint (`ZeroValuation`); `1 ≤ listing_fee_bps ≤ MAX_LISTING_FEE_BPS = 100` (`InvalidListingFeeBps`); `now < expires_at ≤ now + 30 days` (`InvalidExpiry`, `MAX_QUOTE_DURATION_SECS`). Stores `valuation`, `listing_fee_bps`, `listing_fee = ceil(valuation × listing_fee_bps / 10_000)`, `listing_fee_mint = Config.fee_mint` and `quote_expires_at = expires_at`; status `Quoted`. Allowed while paused (a listing action, §3.3). Emits `ListingQuoted { listing, asset_mint, fee_mint, valuation, listing_fee_bps, listing_fee, expires_at }` |
| `pay_listing_fee` | `listing.issuer` | blocked while paused (`Paused`); status `Quoted` (`ListingNotQuoted`) and `now < quote_expires_at` (`QuoteExpired`); the fee mint passed must be `Config.fee_mint` and the quote's `listing_fee_mint` (`NotFeeMint`); the mint allowlist is re-run on it. Transfers `listing_fee` of the fee mint from a token account owned by the issuer into the fee vault (`transfer_checked`, signed by the issuer), adds it to `FeeLedger.listing_fees_collected`, sets `listing_fee_paid = listing_fee`, status `Approved` and `approved_at = now`. Emits `ListingFeePaid { listing, asset_mint, issuer, fee_mint, valuation, listing_fee_bps, amount }`, then `ListingApproved` (§4.1) |

Rules:
- **The only path to a first approval.** `approve_listing` refuses a
  `Pending` or `Quoted` listing (`ListingFeeNotPaid`). It still reinstates a
  `Suspended` listing of any class, and reinstating charges nothing: a
  suspended issuer listing has already paid. `Pending → Approved` is no
  longer a valid transition. A listing is rejected with `delist`, from
  `Pending` or `Quoted`; `suspend_listing` stays `Approved`-only.
- **Re-quoting** is allowed until the fee is paid: `quote_listing` on a
  `Quoted` listing replaces every quote field, also after the quote expired.
- **Once per listing, not per batch.** After payment the status never
  returns to `Quoted`, so a second payment fails (`ListingNotQuoted`) and so
  does a new quote (`InvalidStatusTransition`). Issuance batches (§3.12) and
  reinstatements charge nothing.
- **Cap, not floor.** On-chain only the cap is enforced
  (`listing_fee_bps ≤ 100`, 1%), plus `listing_fee_bps ≥ 1` so a quote is
  never free. The 0.1% floor is pricing policy, as for the trading fee (§1).
  Raising the cap takes a program upgrade.
- **Rounding up.** `listing_fee = ceil(valuation × listing_fee_bps / 10_000)`
  (checked, `u128` intermediate), so with `valuation ≥ 1` and
  `listing_fee_bps ≥ 1` the fee is at least 1 base unit and at most
  `valuation / 100` rounded up.
- **Accounting.** The listing fee is protocol revenue with no cashback
  share: it goes to `FeeLedger.listing_fees_collected` and never touches
  `fees_collected`, `cashback_accrued` or any `CashbackLedger`.
  `withdraw_protocol_fees` can withdraw it; `sweep_excess` counts it as owed.
- **Fee mint.** The valuation and the fee are in base units of the fee mint
  in force at `quote_listing`, recorded as `listing_fee_mint`. After a
  timelocked fee-mint switch (§3.4) that quote can no longer be paid
  (`NotFeeMint`); the listing authority re-quotes in the new mint.
- **Pause.** `quote_listing` is allowed (a listing action, moves nothing);
  `pay_listing_fee` is blocked (§3.3).
- **Trust.** The listing authority sets the valuation and the rate; the
  program checks only the bounds and the expiry. The issuer sees the quote
  in the `Listing` account and in `ListingQuoted` before it signs
  `pay_listing_fee`, so paying is the issuer's acceptance; an issuer that
  disagrees does not pay, and the listing stays unapproved.
- **The valuation is public.** It is stored in the `Listing` account and
  carried by `ListingQuoted` and `ListingFeePaid`, so anyone can read it, and
  the account history and events keep it after a re-quote. Issuers must be
  told before they are quoted; a valuation that must stay confidential
  cannot go through this path.
- **Layout.** `Listing` gains the six quote fields and `FeeLedger` gains
  `listing_fees_collected`, both before deployment of any account of either
  type: on 2026-11-13 the devnet program is deployed but no setup has run,
  so the upgrade needs no migration.

**Invariant 13** (§3.9): every non-`Currency` listing that is `Approved` or
`Suspended` paid exactly `ceil(valuation × listing_fee_bps / 10_000)`, once,
with `listing_fee_bps ≤ MAX_LISTING_FEE_BPS`, and the fee ledger's
`listing_fees_collected` is the sum of what was paid in its mint.

---

## 4. EVM — changes to `niara-contracts` (Sepolia + Base Sepolia)

Reuse `NiaraSettlement`, `CashbackDistributor`, `TimelockedAccessControl`. Add:

- **`AssetTokenFactory`** — issuer deploys its own ERC-20 instrument from its wallet
  (`assetClass`, `docHash`, issuer = `msg.sender`).
- **`ListingRegistry`** — `submitListing` (issuer) → `approveListing` /
  `suspendListing` (LISTING_AUTHORITY_ROLE, timelocked where sensitive).
- `NiaraSettlement.settle` **reverts unless `registry.isApproved(asset)` AND the
  listing class is `Equity`**.
- Asset classes: `Equity`, `FixedIncome`, `Credit`, `Currency` (extend the existing
  enum or map). `Currency` listings are created by LISTING_AUTHORITY_ROLE, never
  cashback-eligible.
- **v1 deploy scripts, written and not broadcast yet**: two phases, with chainid
  guards so they run on Sepolia `11155111` and Base Sepolia `84532` only,
  keystore signers, and mock USDT / BRL test tokens as the listed currencies,
  like `scripts/setup.ts` on Solana.
- Same invariant fuzzing suite extended with the listing invariant.
- **`P2PEscrow`** (EVM mirror of 3.5), **implemented**: `openDeal` (deposit),
  `acceptDeal(dealKey)` (atomic swap + fee + cashback via `CashbackDistributor`),
  `cancelDeal`, `expireDeal`, `sweepExcess`.
  Accepts only `FixedIncome`/`Credit`/`Currency` listings. What it shares with
  the Solana escrow and where it differs: §4.2.

Note: v1 is a **new deployment** (new registry + factory), made with the deploy
scripts above; nothing of v1 has been broadcast on EVM yet. Whether the July
2026 Sepolia deployment of niara-contracts is still live and documented is
still to be verified; v1 does not depend on it.

### 4.1 Listing events for the Register indexer

A listing becomes tradable at exactly one event on every chain: **`ListingApproved`**.
Both paths emit it, on Solana and on EVM; there is **no separate currency event**
(no `CurrencyListed`). The indexer tells currencies apart by `asset_class` /
`assetClass == Currency`, which always comes with `cashback_eligible == false`, a
zero `doc_hash` and no issuer (`Pubkey::default()` / `address(0)`).

| Listing path | Solana instruction → event | EVM (`ListingRegistry`) function → event |
|---|---|---|
| Issuer submits (`Pending`) | `submit_listing` → `ListingSubmitted { listing, asset_mint, issuer, asset_class, doc_hash }` | `submitListing` → `ListingSubmitted(token, issuer, assetClass, docHash)` |
| Niara quotes the listing fee (`Pending`/`Quoted` → `Quoted`) | `quote_listing` → `ListingQuoted { listing, asset_mint, fee_mint, valuation, listing_fee_bps, listing_fee, expires_at }` | no counterpart yet (see the note under §4.2) |
| An issuer listing is approved (Solana: `Quoted` → `Approved`; EVM: `Pending` → `Approved`) | `pay_listing_fee` (signed by the issuer) → `ListingFeePaid { listing, asset_mint, issuer, fee_mint, valuation, listing_fee_bps, amount }`, then `ListingApproved` | `approveListing` → `ListingApproved` |
| Niara lists a currency (created `Approved`) | `list_currency` → `ListingApproved` | `listCurrency` → `ListingApproved` |
| Reinstatement (`Suspended` → `Approved`, any class) | `approve_listing` → `ListingApproved` (new `approved_at`) | `approveListing` → `ListingApproved` (new `approvedAt`) |
| Suspension (`Approved` → `Suspended`) | `suspend_listing` → `ListingSuspended { listing, asset_mint }` | `suspendListing` → `ListingSuspended(token)` |
| Delisting (final) | `delist` → `ListingDelisted { listing, asset_mint }` | `delist` → `ListingDelisted(token, previousStatus)` |

`ListingApproved` carries the same fields on both chains: Solana
`{ listing, asset_mint, issuer, asset_class, cashback_eligible, doc_hash, approved_at }`,
EVM `ListingApproved(address indexed token, address indexed issuer, AssetClass assetClass,
bool cashbackEligible, bytes32 docHash, uint64 approvedAt)` (EVM has no separate listing
account, so `token` plays the role of both `listing` and `asset_mint`).

### 4.2 EVM vs Solana differences (intentional)

Aligned on both chains:
- asset classes, listing status table (except `Quoted`, Solana only until the
  EVM listing fee lands, see the note after the table below), `ListingApproved`
  on both listing paths (§4.1);
- issuance batches numbered from 1 with `requested_at`/`resolved_at`, `reject_issuance`
  in any listing status, `approve_issuance` blocked while paused, non-zero `doc_hash` /
  burn `reference`;
- `Currency` never cashback-eligible; `settle` only on `Approved` `Equity` against an
  `Approved` `Currency`;
- **fees and cashback always in USDT** (§3.4). EVM: `settle` accepts only
  `NiaraSettlement.feeToken` (`NotFeeToken` otherwise), which needs an `Approved`
  `Currency` listing too and is switched only through the timelock
  (`proposeSetFeeToken` / `executeSetFeeToken`); the seller, who receives the USDT,
  pays the fee;
- **fee rounding**: both chains round the fee **up**,
  `fee = ceil(usdt_amount × fee_bps / 10 000)`, so a non-zero rate never yields a zero
  fee, and both reject a trade whose USDT receiver would get nothing after it, under
  the same error name: `ZeroSellerProceeds` on Solana (`settle`, `open_deal`),
  `ZeroSellerProceeds()` on EVM (`settle`, `openDeal`);
- **fee cap 0.5%** (business rule, §3.4): `fee_bps ≤ 50` on both chains. Solana:
  `MAX_FEE_BPS = 50`; EVM: `NiaraSettlement.MAX_FEE_BPS = 50`;
- **starting cashback rate**: both chains deploy at 2000 bps (20% of the trading fee).
  Solana sets `cashback_bps` in `initialize_config` (the `scripts/setup.ts` default),
  EVM in the `CashbackDistributor` constructor (the `script/Deploy.s.sol` default). On
  both, later changes go through the timelock (`propose_change(CashbackBps)` /
  `proposeSetCashbackBps`);
- **P2P escrow** (§3.5; EVM `P2PEscrow`): the same asset classes
  (`FixedIncome`/`Credit`/`Currency`, never `Equity`); a named counterparty (no open
  offers); expiry at most 30 days ahead; `fee_bps` and `cashback_bps` snapshotted on the
  deal at open and charged at accept; a USDT leg on every deal, and the USDT receiver
  pays the fee; pause and listing status block open and accept but never cancel or
  expire; the fee token is not snapshotted (after a fee-token switch a deal in the old
  token can only be refunded);
- **zero ids rejected**: a zero `match_id` (`settle`) and a zero `deal_id`
  (`open_deal` / `openDeal`) are rejected on both chains. An all-zero id is what an
  unset field looks like, never a real UUID;
- **one shared pause** with the same scope and principle (§3.3); where it lives differs,
  see the table;
- **per-listing cashback freeze** (§9.5). EVM: `ListingRegistry.freezeCashback` /
  `unfreezeCashback` (LISTING_AUTHORITY_ROLE, no timelock, any listing status, allowed
  while paused; `NotCashbackEligible` / `CashbackAlreadyFrozen` / `CashbackNotFrozen`;
  `CashbackFreezeSet(token, frozen, listingAuthority)`); `CashbackDistributor.withdraw`
  reverts `CashbackFrozen` while accrual continues;
- **on-chain replay protection**: a match id settles at most once. EVM:
  `settle(bytes16 matchId, ...)` sets `settledMatches[matchId]` before any transfer and
  reverts `MatchAlreadySettled` on a second attempt; `Settled` carries `matchId` first,
  like Solana's `match_id` (a storage slot instead of a `SettlementRecord` account, so
  no rent).

What still differs, on purpose:

| Topic | Solana (`niara_exchange`) | EVM (`niara-contracts`) | Why |
|---|---|---|---|
| Asset token origin | Issuer creates the mint; `submit_listing` checks `supply == 0` and moves the mint authority to the program PDA | Issuer deploys through `AssetTokenFactory`; the token's only minter is the `ListingRegistry` from birth (no hand-over, no "finish metadata first" step) | An EVM token's code is fixed at deploy, so a factory gives a known implementation; on Solana the issuer's mint must be accepted and checked |
| Asset-side safety check | Mint extension allowlist + no freeze authority, at listing and again in `settle` | Only factory tokens can be submitted (plain ERC-20: no fees, rebasing, hooks, pause) | Same goal (known token behavior), enforced by the implementation instead of by inspecting the mint |
| Listing class and `doc_hash` | Arguments of `submit_listing` | Fixed at `createAssetToken`; `submitListing(token)` copies them from the token | Listing can never disagree with the instrument |
| Where the pause lives | One `Config.paused`, set by `admin`; stops `settle`, `open_deal`/`accept_deal`, withdrawals, `sweep_excess` and `approve_issuance` together; `cancel_deal`/`expire_deal` never read it | One pause too, held by `ListingRegistry` (`pause`/`unpause`, `PAUSER_ROLE` = admin); stops `approveIssuance`, and `NiaraSettlement.settle`, both `CashbackDistributor` withdrawals and `P2PEscrow.openDeal`/`acceptDeal`/`sweepExcess` read it (`ProtocolPausable`, `EnforcedPause()`); those contracts have no pause of their own, and `cancelDeal`/`expireDeal` never read it. `BackingGateway`/`AssetToken` (backed model, no Solana counterpart) keep theirs | EVM has no `Config` account; the registry is the contract every other one already reads. Same scope and same principle |
| Admin transfer | Two steps (§3.3): the admin calls `propose_change(Admin)`, then, once the timelock has elapsed, the new admin signs `accept_admin`; until then the outgoing admin can `cancel_change` | A timelocked grant of the roles to the Safe, then a revocation of the old key's roles that the Safe proposes and executes. That Safe-signed revocation is the acceptance; until it executes, the old key can cancel it (§9.6, tested in `test/MultisigHandover.t.sol`) | Solana has one `Config.admin` field, so the new key must accept before it replaces the old one. `AccessControl` lets both keys hold a role at once, so the old key is removed by a transaction the Safe signs. Either way the new key proves it can sign before the old one loses control |
| Batch and burn bookkeeping | `Listing.issued` / `Listing.burned` counters; `burn_with_reason` is a program instruction (`CurrencyNotIssued` for currencies) | No counters in the registry; supply = Σ `IssuanceExecuted` − Σ `TokensBurned`, derivable from events. `burnWithReason` lives on `NativeAssetToken` and emits `TokensBurned` there; currencies simply don't have it | On EVM the token is Niara's own code, so the burn path can live in it |
| Invariant 11 | `supply ≤ issued − burned` on-chain (holders can burn directly through the token program) | `supply == Σ executed − Σ burned` strictly: `NativeAssetToken` has no other burn path | EVM token has no generic `burn` |
| Issuance destination | Batch names a wallet; `approve_issuance` takes any token account owned by it; `IssuanceExecuted` has `destination` | Batch names an address that receives the mint; `IssuanceExecuted` has no `destination` | ERC-20 balances live at the address, no separate token account |
| Event vs effect order | `approve_issuance` mints, then updates state and emits. The escrow instructions do the same: token transfers and vault close first, then the deal status and the event. `withdraw_cashback` and `withdraw_protocol_fees` update the ledger, transfer, then emit | `approveIssuance` marks the batch, emits `IssuanceExecuted`, then mints (checks-effects-interactions, see CLAUDE.md). The `P2PEscrow` functions do the same: deal status and event first, then the token transfers. Both `CashbackDistributor` withdrawals also emit before the transfer | EVM external calls can re-enter; SPL token CPIs cannot |
| Deal identity | One `Deal` account per deal, the PDA `["deal", proposer, deal_id]`; `accept_deal`, `cancel_deal` and `expire_deal` take that account | A storage entry keyed by `dealKey = keccak256(proposer, dealId)`; `acceptDeal(dealKey)` and the refund functions take the key | Solana addresses state by account, EVM by mapping key. Both scope the id to the proposer, so two proposers can use the same `deal_id` |
| Tokens sent to the escrow | Every exit releases the deal vault's whole balance; the excess goes with the deposit and is reported as `vault_excess` (§3.5) | Every exit moves exactly the deposit; tokens sent to the contract stay there until the treasury takes them with `sweepExcess` | A Solana token account can only be closed empty and each deal has its own vault, so the excess must leave with the deposit. On EVM one contract holds every deposit: a stray transfer blocks nothing and belongs to no deal |
| Deal fee accounting | `accept_deal` updates the `FeeLedger` and the `CashbackLedger` itself (same program as `settle`) | `P2PEscrow` calls `CashbackDistributor.recordDealFee`, which only `ESCROW_ROLE` may call | On EVM the escrow and the distributor are separate contracts, so the distributor must restrict who can record a fee |
| Error names | `DealExpired` (accept from `expires_at` on) | `DealHasExpired` | Name only, the condition is the same. On Solana the error shares its name with the `DealExpired` event; the EVM error has its own. `ZeroSellerProceeds` has the same name on both chains (see the fee rounding item above) |
| Payment-side safety | Mint extension allowlist on the payment mint | Balance-delta check on every leg (`TransferAmountMismatch`) | ERC-20 behavior can't be inspected up front, only observed |
| Cashback accounting and events | `Settled` carries `cashback`; per-listing `CashbackLedger`, one `FeeLedger` for the fee mint, `sweep_excess` | `Settled` has no cashback; `CashbackDistributor` emits `FeeRecorded` / `CashbackCredited`; balances are kept per (asset, token) and per token, so only USDT ever accrues, and a fee-token switch leaves old balances withdrawable; no ledger accounts, no sweep | Pre-existing EVM distributor; `settle` alone enforces the fee token |
| Cashback withdrawal | `withdraw_cashback(amount)` to any account of the payment mint except the vault; blocked while paused and while the listing's cashback is frozen (§9.5) | `withdraw(asset, payment)` pays the whole balance to the token's `issuerWallet()`; blocked while paused and while the listing's cashback is frozen (`Listing.cashbackFrozen`, read from the registry) | Pre-existing EVM distributor's payout shape (no amount, no destination) kept |
| Batch timestamps | `i64` Clock `unix_timestamp` | `uint64` `block.timestamp` | Type only |

**Not yet aligned: the listing fee.** On Solana the listing fee is charged
on-chain and paying it approves an issuer listing (`quote_listing`, then
`pay_listing_fee`, §3.13); `approve_listing` only reinstates. The EVM
`ListingRegistry` has no quote or payment step yet: `approveListing`
approves a `Pending` listing directly, and the listing fee is still charged
off-chain there. This is not an intentional difference; bringing the same
flow to `ListingRegistry` (quote with the 1% cap and a 30-day expiry, payment
in `feeToken` into the protocol's revenue with no cashback share, and
`approveListing` limited to reinstatement) is an EVM work item.

---

## 5. Off-chain (Supabase `niara-exchange-dev`)

Minimal schema:
- `listings(chain, asset, issuer, asset_class, status, doc_hash, tx_hash)` — mirror of on-chain state, populated by indexer
- `orders(id, chain, asset, side, quantity, limit_price, payment_asset, wallet, intent_signature, status, created_at)`
- `matches(id, buy_order, sell_order, quantity, price, status)`
- `settlements(match_id, chain, tx_hash, status, error)`

Settlement worker: Node/TS service (Railway, same pattern as the Register indexer).
- Holds **one operator key per chain**, funded with minimal test balance.
- Operator keys **never** in the frontend, never in `NEXT_PUBLIC_*`, never in git.
- Idempotent: a match is settled at most once (unique constraint on `match_id`
  off-chain; on Solana also on-chain, since `settle` takes the match UUID as
  `match_id` and creates `["settled", match_id]`).

---

## 6. Frontend (`niara-site`) and Register

- Wallets: wagmi v3 (EVM) + Solana Wallet Standard (Phantom, Solflare, Backpack).
- New real flow (separate from the simulated `/trade`):
  create mint → submit listing (mint authority moves to the program) → (admin)
  quote the listing fee → issuer pays it (the listing is approved) → issuer
  requests an issuance batch → (admin) approve batch →
  place order → match → settle → issuer withdraws cashback. Chain selector: Solana / Sepolia / Base Sepolia.
- Deploy on **Vercel**.
- **Niara-Register:** extend the indexer to capture `ListingApproved`
  (both listing paths, §4.1), `ListingFeePaid` (Solana), `Settled`,
  `DealExecuted` (Solana program and
  EVM `P2PEscrow`), `IssuanceExecuted` and `TokensBurned`
  on all three chains into the "Global registry" area (today empty
  because the Exchange has not operated for real). On EVM, `TokensBurned` is
  emitted by each `NativeAssetToken` (not by the registry), so the indexer
  watches every token deployed by the `AssetTokenFactory` (`AssetTokenCreated`).
  On Solana there is **no separate `CashbackCredited` event**: `Settled` and
  `DealExecuted` carry `fee` and `cashback`, so the indexer credits the issuer's
  cashback from them (one event per settlement or deal, nothing to correlate).
  On EVM, `Settled` has no `cashback` field and the `CashbackDistributor` emits
  `CashbackCredited` in the same transaction (§4.2). Listing `doc_hash` can be
  signed and registered through Register's document signature feature.

Narrative: *the Exchange operates, the Register proves it.*

---

## 7. Six-week plan

| Week | Deliverable | Done when |
|---|---|---|
| 1 | Design freeze; Anchor workspace; `Config` + `Listing` + timelock + pause; EVM `ListingRegistry` + factory | unit tests green on both stacks |
| 2 | Solana `settle` (delegate) + cashback + withdrawals; EVM settle gated by registry; deploy EVM to Sepolia + Base Sepolia | invariants pass (proptest/LiteSVM + Foundry); EVM contracts verified on explorers |
| 3 | Solana P2P escrow (`open/accept/cancel/expire_deal`); deploy program to Devnet; Supabase schema; matching engine; EVM settlement adapters | escrow invariants pass; end-to-end settle on Sepolia from the worker |
| 4 | Solana settlement adapter; frontend real flow (EVM + Solana wallets) | end-to-end settle on Devnet from the UI |
| 5 | Register indexer for 3 chains; Vercel deploy; signed order intents (if time) | Register shows real Exchange settlements |
| 6 | Buffer; 2-person test on 2 devices per chain; README/docs; **record the demo video** | interview package ready |

Cut order if behind schedule (last to first): UI polish → signed intents
(document as trust assumption) → Base deploy (trivial to add later). EVM
`P2PEscrow` was on this list and is now implemented (§4). **Never cut:** Solana
settle, Solana P2P escrow, issuer cashback, honest labeling.

---

## 8. Interview package (week 6)

- Explorer links already confirmed (Solana Explorer devnet, Etherscan, Basescan) —
  never depend on a live transaction during the call.
- Short recorded video of the full flow on Solana.
- One slide per question they will ask: why matching is off-chain; how atomic
  settlement maps to Solana's account model; why SPL delegate vs. escrow; how
  curated listing addresses the regulatory tension; what is NOT done yet
  (audit, regulation, signed intents if missing, Token-2022 compliance layer).

---

## 9. Roadmap — security, token lifecycle and product vision

Not in v1 unless marked done. §9.1 to §9.6 are ordered by what an incident
would need first: contain it, recover from it, prove what happened. §9.7 to
§9.11 are product vision, not v1 scope. They claim no regulatory status:
Niara holds no authorization for any of these services (the testnet notice
at the top applies), and none is offered before counsel has assessed its
dependencies (§9.11).

### 9.1 Containment: "pause fast, resume slow"

- **`GUARDIAN` role.** A new `Config` key that can call `pause` and
  `suspend_listing` with **no timelock**, and nothing else. It cannot
  `unpause`, cannot approve or reinstate listings, cannot approve issuance and
  cannot move funds. A leaked guardian key can therefore only stop the system,
  never steal from it, so it can live on more devices (on-call phones, an
  alerting bot) than the admin key.
- **Resuming is deliberate.** `unpause` and reinstating a suspended listing
  stay with the admin and the listing authority respectively; in production
  both sit behind the multisig (§9.6), so recovery needs several people.
- **Issuer wallet rotation.** A compromised issuer key can request issuance
  and withdraw cashback. Niara can rotate `listing.issuer` to a new wallet via
  a timelocked change (same `propose_change`/`execute_change` pattern, one
  pending slot per listing), after off-chain verification of the issuer's
  identity. The timelock gives the real issuer time to object if the request
  itself is the attack. Until rotation, the guardian suspends the listing,
  which stops trading and new issuance (pending batches stay unexecuted).

### 9.2 Recovery after an attack

Goal: if tokens are stolen or minted fraudulently, burn the compromised
supply and reissue to the rightful holders, using the Register history as the
source of truth.

- **What it needs.** A clawback power. On Solana that is Token-2022
  `PermanentDelegate`, which can transfer or burn from any account of the
  mint. It can **only be set at mint creation** and never added later (proved
  for v1's allowlist in `test_mint_extension_lock.rs`), so the decision has to
  be made **before any production mint exists**: mints created without it can
  never gain it.
- **Who may hold it.** Only a Niara recovery authority: a program PDA whose
  instruction requires a multisig approval and a timelock. **Never the
  issuer**: an issuer with a permanent delegate can take any holder's
  securities at will, which defeats self-custody.
- **When it may be used.** Every forced burn needs a documented legal basis
  (court order, regulator determination, or a corporate act within the
  issuer's statutory powers), whose hash is recorded on-chain with the burn,
  like `burn_with_reason`'s `reference`. Reissue goes through the normal
  batch flow (§3.12) with the same reference.
- **v1 decision: rejected.** `PermanentDelegate` stays on the rejected list
  (§3.8): it can drain escrow and fee vaults, and v1 has neither the recovery
  program nor the legal framework to justify it. The cost of that choice is
  that v1 mints can never be clawed back. Revisit before production mints;
  the preferred production design is in §9.3.

### 9.3 Issuer compromise and recovery

Issuance needs two parties (§3.12): the issuer requests, Niara approves. That
protects holders from either party alone, and it also means **Niara cannot
reissue on its own** when the issuer's key is lost or stolen.

**Recovery path (works with v1 mints).**
1. The guardian suspends the listing (§9.1): no trading, no new requests, no
   batch executes. Cashback withdrawals are *not* stopped by suspension
   (listing status gates trading, not payouts), which is why the listing's
   cashback is frozen too (§9.5, in v1).
2. Niara rotates `listing.issuer` to a new issuer wallet, timelocked, after
   verifying the issuer's identity and corporate authorization off-chain.
3. The new issuer wallet requests the reissuance batch (`doc_hash` = the
   corporate act and the incident report); the listing authority approves it
   once the listing is reinstated.

Without step 2 the reissue cannot happen: only `listing.issuer` can request a
batch. With v1 mints (no clawback), reissuing does not remove the compromised
tokens, so supply grows by the reissued amount until those tokens are
returned or burned voluntarily; the Register marks the compromised units.

**Preferred production design: Niara-created mints.** The Niara program
creates the asset mint itself (the Solana equivalent of the EVM
`AssetTokenFactory`, §4) instead of accepting a mint the issuer made:
- The mint authority is the `["mint_authority", asset_mint]` PDA from birth;
  the issuer never holds it. This also **removes the "finish metadata before
  submitting" constraint** of §3.12: the program initializes the metadata at
  creation, with the issuer as update authority.
- `PermanentDelegate` is set at creation to the **Niara recovery authority**
  (program PDA + multisig approval + timelock, §9.2), never to the issuer.
  The allowlist (§3.8) keeps rejecting `PermanentDelegate` in general and
  accepts it only when the delegate is that recovery authority. Because the
  delegate can also move tokens out of program-owned accounts, the recovery
  instruction must refuse fee vaults and deal escrows (or settle them
  explicitly) and only act on holder accounts named in the incident record.
- Optional **`TransferHook`** restricting transfers to KYC'd wallets (a
  Niara-vetted hook program, §3.7) limits off-platform dumping of stolen
  tokens. It is rejected by the v1 allowlist and needs settlement and escrow
  to pass the hook's extra accounts in their CPIs.

**Honest limits.**
- Tokens can leave Niara before the compromise is detected: sold on-platform
  to good-faith buyers, or (without a transfer hook) moved to any wallet.
- Burning tokens from a good-faith third party is a taking of their property:
  it needs a legal basis, either a court order or a clause in the offering
  document that buyers accepted (disclosed in the `doc_hash` document). The
  technical power to claw back does not by itself make a clawback lawful.

### 9.4 Traceability

- **Numbered issuance batches tied to a Register `doc_hash`** — done in v1
  (§3.12).
- **One mint per share class and per debenture series.** Common and preferred
  shares, or two debenture series, are different instruments with different
  rights; they never share a mint. The listing's `doc_hash` identifies the
  class or series.
- **Burns with a reason** — done in v1 for burns through the program
  (`burn_with_reason`); direct burns are visible as unexplained supply drops
  (invariant 11).
- **Holder ledger at any block.** From `IssuanceExecuted`, `Settled`,
  `TokensBurned` and the token transfers, the Register reconstructs who held
  what at any slot. This is **probative evidence, not a substitute** for the
  share register required by Lei 6.404/1976 (book-entry shares are kept by an
  authorized bookkeeping institution); reconciling the two is part of the
  production plan.

### 9.5 Cashback protection

A stolen issuer key is first of all a way to drain accrued cashback: today
`withdraw_cashback` pays to any account the issuer names, and suspending the
listing does not stop it.
- **Registered payout address.** Each listing stores a cashback payout
  address; `withdraw_cashback` pays only there. Changing it is timelocked
  (propose / execute, cancellable by Niara), so an attacker who takes the key
  cannot redirect payouts before the real issuer or Niara reacts.
- **Per-listing freeze — done in v1.** `Listing.cashback_frozen`, set by
  `freeze_cashback` and cleared by `unfreeze_cashback` (§3.3), stops
  `withdraw_cashback` for one listing (`CashbackFrozen`) without pausing the
  whole protocol. Both are signed by the listing authority with **no
  timelock** (containment must act at once), work in any listing status
  (cashback stays withdrawable after delisting, so it must stay freezable)
  and while paused. Accrual continues while frozen (`settle` and
  `accept_deal` do not read the flag); nothing is lost, and everything
  accrued is withdrawable after unfreezing. `Currency` listings, which never
  accrue cashback, cannot be frozen. Tests: `tests/test_cashback_freeze.rs`,
  plus freeze/unfreeze (incl. wrong signers) in the invariant fuzzer, which
  checks that no withdrawal ever succeeds on a frozen listing.
  Still roadmap: when the guardian role (§9.1) lands, it gets
  `freeze_cashback` only; unfreezing follows "resume slow" and stays with the
  listing authority behind the multisig.
- **Issuer key hygiene, checked at onboarding.** Issuers must sign from a
  multisig (Squads on Solana, Safe on EVM) or a hardware wallet. A multisig is
  verifiable on-chain (the issuer address is a Squads vault / Safe contract);
  a hardware wallet can only be attested by process, so the onboarding record
  says which one was checked and how.

### 9.6 Cybersecurity program (production)

**Keys.**
- **Migration to a multisig is mandatory before mainnet, on every chain.** No
  mainnet deployment goes live while a single key holds the admin or the
  program upgrade authority (Solana), or the admin, pause or treasury roles
  (EVM).
  - **Solana:** the program upgrade authority and `Config.admin` go to a
    **Squads v4** vault (ideally with its own time lock). The upgrade
    authority moves with `solana program set-upgrade-authority` (to a PDA,
    so with `--skip-new-upgrade-authority-signer-check`). The admin moves
    with the two-step transfer, `propose_change(Admin)` then `accept_admin`
    signed by the vault (§3.3). Making the program immutable after audit
    (§3.6) is an option for the upgrade authority only, never for the admin.
  - **EVM:** the admin, pause and treasury roles of the four v1 contracts
    that have roles go to a **Safe**: `DEFAULT_ADMIN_ROLE` on
    `ListingRegistry`, `NiaraSettlement`, `CashbackDistributor` and
    `P2PEscrow`; `PAUSER_ROLE` on `ListingRegistry` (the shared pause);
    `TREASURY_ROLE` on `CashbackDistributor` and `P2PEscrow`. The v1 deploy
    script grants all of them to the deployer. `AssetTokenFactory` has no
    roles. The backed-model `BackingGateway` and `AssetToken` (§1) have
    roles too, but they are not part of v1.
  - **Rehearsed first on testnets**: Squads v4 on Solana devnet, Safe on
    Sepolia and Base Sepolia, including at least one full admin handover
    signed by the multisig. On Solana that signature is the vault's
    `accept_admin`. The EVM handover has no on-chain acceptance step: the
    deployer grants the roles to the Safe through the timelock, then the
    Safe proposes and executes the revocation of the deployer's roles. That
    Safe-signed revocation is the acceptance: like `accept_admin`, it
    proves the new key can sign before the old one loses control. Until it
    executes, the deployer still holds its roles and can cancel it (as the
    outgoing Solana admin can `cancel_change` before `accept_admin`).
    The procedure is tested in `niara-contracts`
    `test/MultisigHandover.t.sol`, on a deployment made by
    `script/Deploy.s.sol`: all seven roles move, the old key keeps nothing,
    the Safe can use every role and rotate the operator and the listing
    authority, a grant to a wrong address never costs the deployer its
    roles, every step waits for the timelock, and the deployer can
    `cancelAction` a pending revocation. That test runs in Foundry against
    `MockSafe`, a stand-in with no threshold, so it **does not replace** the
    testnet rehearsal with a real Safe on Sepolia and Base Sepolia.
  - The settlement operator, the listing authority and the treasury are
    rotated by the admin through the timelock (§3.3), so a multisig admin
    can replace a leaked operational key without that key's cooperation.
- `GUARDIAN` (§9.1) is a separate key from `admin`, so stopping the system
  never requires the keys that can change it.
- One settlement operator key per chain, in a **KMS/HSM**, with minimal
  balance and per-key rate limits; never in the frontend or in git (§5).
- Documented key rotation (who, how often, how it is verified on-chain), and
  **no key ever on a developer laptop**.

**On-chain controls.**
- Per-listing volume circuit breakers: settlement volume per listing per
  window above a threshold suspends the listing automatically (or through the
  guardian).
- Alerts on anomalous issuance (batch size vs. history, requests outside
  business hours), large transfers, failed-settlement spikes, and any
  supply/ledger mismatch (invariants 4 and 11 checked off-chain continuously).
- The settlement worker is idempotent (one settlement per match, §5) and
  rate-limited.

**Off-chain infrastructure.**
- Supabase **Row Level Security on every table**; the service-role key only on
  the server, never in the browser or in `NEXT_PUBLIC_*`.
- Least-privilege database roles (the indexer writes only what it indexes,
  the worker only settlement status).
- Backups with periodic **restore drills**.
- Audit log of every admin action (on-chain admin actions are already events;
  off-chain ones, such as listing review and KYC decisions, are logged too).

**Frontend and users.**
- Strict Content-Security-Policy.
- **Transaction preview (simulation) before every signature**, showing the
  balance changes the user is about to approve.
- Clear-signing texts: plain-language descriptions of each instruction and
  of each signed order intent (§3.6).
- One official domain, with anti-phishing guidance; Niara **never asks for a
  seed phrase**, and says so on every signing screen.

**Development.**
- 2FA on GitHub, Vercel, Supabase, Railway and the domain registrar.
- Branch protection with required reviews and CI.
- Secret scanning in CI (e.g. gitleaks), on top of the `.gitignore` rules.
- Pinned dependencies with committed lockfiles and a dependency audit
  (`cargo audit`, `npm audit`) in CI.
- Reproducible, verifiable builds of the program, so anyone can check that
  the deployed binary matches the audited source.

**Process.**
- External audit and public bug bounty before mainnet; no mainnet deploy of
  an unaudited build.
- Incident-response runbook with on-call roles: who pauses (guardian), who
  decides to resume, how users and the regulator are informed, how the
  Register evidence is preserved.
- Periodic penetration tests (frontend, API, infrastructure).
- **SOC 2** for the off-chain stack, already planned for Register.

### 9.7 Neobank inside the Exchange

Vision, not v1 scope: banking-style services in the same app as the
Exchange, built on the user's self-custody wallet (§9.8). "Neobank" names
the product idea; it does not claim that Niara is, or is authorized as, a
bank or a payment institution (§9.11). **Securities trading always settles
in USDT**, and no service below changes that (see FX).

**Founder's v1 definitions (2026-11-13).** The card, card receivables and
payroll below are defined by the founder for a first version. They are
still roadmap, not v1 scope, and make no regulatory claim: each stays
behind its assessment in §9.11.

- **Card.** A virtual card that runs on stablecoins and works **only on
  Niara's own virtual card terminal**: a closed-loop arrangement, with no
  card network. Every card transaction is recorded on-chain and in the
  Register.
  - **Debit and credit versions.** Debit pays from the user's wallet at
    purchase. The credit version holds the purchase value **in escrow in the
    user's wallet**; its details will be specified later.
  - **Open questions (credit version).**
    - When is the merchant paid: at purchase, from the escrow, or later? If
      later, the sale creates a card receivable (next item).
    - Is credit fully collateralized by the escrow (the user locks the whole
      purchase value), or can the escrow hold less than the purchase, which
      makes it credit extended by someone?
- **Card terminal.** Niara's own virtual card terminal, the only place the
  card works. It records each transaction on-chain, with a fee of 0.1% to
  0.5% of the transaction.
- **Card receivables.** Recorded in the Register **in the demo**. A
  receivable exists **only where the merchant is paid later than the
  purchase**; a sale paid to the merchant at purchase creates none. The
  demo record is a Register entry, not the registration of receivables
  listed in §9.11.
- **Tokenized receivables anticipation**: a business sells future
  receivables at a discount for immediate payment. Pricing needs the oracle
  (§9.10); card receivables need registration (§9.11). How these tokens map
  to the `Credit` asset class (§1) is to be designed.
- **Payroll.** A multi-payment feature: one company payment to many
  destination wallets, **stablecoin only**, executed by smart contracts.
  On-chain programs do not run on a schedule, so each payroll run must be
  triggered by a transaction (the company signing, or a crank releasing
  funds the company deposited in advance).
  - **Labor-law conflict.** Paying salaries of CLT employees in stablecoins
    conflicts with CLT art. 463, which requires salary to be paid in
    national currency. Counsel must define the allowed uses (§9.11) before
    the feature is offered for any payment to employees.
- **Business solutions** for companies. Scope to be defined.
- **FX** with stablecoins for BRL, EUR, CHF and GBP (below).

**FX.** Stablecoin FX for neobank services, with stablecoins for **BRL,
EUR, CHF and GBP**, is a separate service from securities trading.

- **Securities always settle in USDT**, and this does not change: `settle`
  takes only the fee mint as payment, and `FixedIncome` / `Credit` deals
  require the payment leg to be the fee mint (§3.4).
- v1's `Currency` P2P deals are the closest thing today, but every one needs
  a USDT leg: BRL ↔ USDT works, BRL ↔ EUR is rejected (`NotFeeMint`).
  Exchanging two non-USDT stablecoins (e.g. BRL ↔ EUR, CHF ↔ GBP) needs what
  §3.10 lists for multi-currency payment: a price oracle (§9.10) to charge
  the fee in USDT, or fees and fee vaults in each currency, plus `Currency`
  listings for each stablecoin.
- FX is regulated separately (in Brazil, by the BCB: Lei 14.286/2021 and the
  VASP rules, §3.10), so it gets its own legal review before production
  (§9.11).

### 9.8 Niara Wallet-as-a-Service

Vision, not v1 scope.

- A wallet is created for each user at signup, after KYC.
- Users who prefer can connect their own wallet instead, from the list of
  wallets the Register supports.
- **Custody model — decided: non-custodial.** The Niara wallet is
  non-custodial, and **Niara holds no part of any key**: no key, no key
  share, no recovery share, no backup it can decrypt. Niara cannot sign for
  a user, alone or with anyone it contracts, and a user can move to another
  wallet without Niara's cooperation.
- **Recovery works without Niara.** Since Niara holds nothing, losing the
  device must be recoverable by the user alone or with parties the user
  picks. Acceptable mechanisms include:
  - **synced passkeys** (the platform's passkey sync, under the user's own
    account);
  - an **encrypted backup the user holds** (only the user can decrypt it);
  - **guardian recovery with a timelock**: guardians the user picks approve
    a key change, which takes effect only after a delay during which the
    current key can cancel it. These recovery guardians are unrelated to
    the protocol `GUARDIAN` role (§9.1), and Niara is never one of them.

  Which mechanisms ship, and in what combination, is to be designed.
- **Embedded-wallet providers must match this model.** Any
  wallet-infrastructure provider used to create wallets at signup must
  give Niara no key share and no signing or recovery power, and its own
  recovery must not route through Niara. A provider that cannot meet this
  is not used.
- "Self-custody" is a claim users and regulators will test, and this model
  is what makes it true. Any design change that lets Niara, alone or with a
  provider it contracts, move a user's funds makes the wallet custodial: it
  is then not called self-custody, and holding users' assets becomes part of
  the VASP assessment (§9.11).

### 9.9 Target chains

Target chains: **Ethereum, Solana, Base, Hyperliquid (HyperEVM), Robinhood
Chain and Tempo**. v1 runs on Solana Devnet, Ethereum Sepolia and Base
Sepolia only; the other three have no v1 deployment.

- HyperEVM, Robinhood Chain and Tempo would reuse the EVM contracts (§4),
  after a per-chain check of EVM compatibility, gas model and finality, and
  with their chain ids added to the deploy scripts' chain guards (§4).
- Each new chain extends the `SettlementAdapter` chain list (§2) and the
  Register indexer (§6).
- No mainnet deployment on any chain before the gates of §9.6 (multisig,
  audit).

### 9.10 Price oracle

Price feeds (for example Pyth and Chainlink) for three uses: paying fees in
currencies other than USDT (§3.10, multi-currency payment), FX between
non-USDT stablecoins (§9.7) and pricing tokenized receivables (§9.7).
**Design to be done.** It must at least settle which feed serves each pair
on each chain, the staleness and confidence limits, what an instruction does
when a price is stale or missing, and who may change a feed, with which
delay.

### 9.11 Regulatory dependencies

To assess with counsel **before each service** is built for production or
offered. Until that assessment is done for a service, the service is not
offered, and no screen, doc or pitch says or implies that Niara is licensed
or authorized for it.

| Dependency | Service it gates |
|---|---|
| Payment-arrangement and payment-institution rules for a closed-loop card with no card network | Card, debit and credit, and card terminal (§9.7) |
| Credit rules, if the credit card is not fully collateralized by its escrow | Card, credit version (§9.7) |
| Registration of card receivables | Card receivables beyond the demo; tokenized receivables anticipation (§9.7) |
| Stablecoin payments to employees under CLT art. 463 (salary in national currency): counsel defines the allowed uses | Payroll (§9.7) |
| Authorization as a virtual-asset service provider (VASP) | Which services need it is part of the assessment; FX (§9.7) and the wallet service (§9.8) are the first to check |
