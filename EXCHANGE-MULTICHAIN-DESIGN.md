# Niara Exchange — Multichain Settlement Design (v1)

Status: DRAFT for design freeze · Target: Solana Foundation interview (4–6 weeks)
Chains in scope: Solana Devnet (priority), Ethereum Sepolia, Base Sepolia
Roadmap only (not in v1): Robinhood Chain Testnet, HyperEVM Testnet, Tempo Testnet

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
     (propose → counter → accept). Once terms are fixed, assets are locked in a
     per-deal escrow PDA. The counterparty's acceptance executes the swap
     atomically. No operator is involved and the operator does not need to be trusted.
4. **Fees and issuer cashback.** Each settlement charges a protocol fee in the
   payment token; a share of that fee is credited to the issuer (pull model).

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
| `Config` | `["config"]` | `admin`, `listing_authority`, `settlement_operator`, `treasury`, `fee_bps: u16` (≤ `MAX_FEE_BPS = 100`), `cashback_bps: u16` (share **of the fee**, ≤ 10_000), `paused: bool`, `timelock_secs: i64`, `bump` |
| `PendingChange` | `["pending", kind]` | proposed value, `execute_after: i64` (Clock `unix_timestamp`) |
| `Listing` | `["listing", asset_mint]` | `asset_mint`, `issuer`, `asset_class` (`Equity`/`FixedIncome`/`Credit`/`Currency`), `status` (`Pending`/`Approved`/`Suspended`/`Delisted`), `cashback_eligible`, `doc_hash: [u8;32]` (offering document hash — registered in Niara-Register), `approved_at`, `next_batch_no: u64` (next issuance batch; 1 after `submit_listing`, 0 for `Currency`), `issued: u64` (Σ executed batches), `burned: u64` (Σ `burn_with_reason`), `bump` |
| `IssuanceBatch` | `["batch", listing, batch_no]` (`batch_no` as `u64` LE) | `listing`, `batch_no`, `amount`, `recipient` (wallet), `doc_hash`, `status` (`Requested`/`Executed`/`Rejected`), `requested_at`, `resolved_at`, `bump`. Never closed: the on-chain issuance record (§3.12) |
| Mint authority | `["mint_authority", asset_mint]` | PDA that holds the mint authority of every issuer-listed asset after `submit_listing`; signs `mint_to_checked` in `approve_issuance`. Holds no data |
| `CashbackLedger` | `["cashback", listing, payment_mint]` | `listing`, `payment_mint`, `accrued: u64`, `withdrawn: u64`, `bump`. Created by the permissionless `init_cashback_ledger` (cashback-eligible listing × `Approved` `Currency`), never lazily inside `settle` |
| `FeeLedger` | `["fees", payment_mint]` | `payment_mint`, `fees_collected` (gross fee: protocol share + cashback), `cashback_accrued` (Σ `CashbackLedger.accrued` in this mint), `protocol_withdrawn`, `cashback_withdrawn`, `bump`, `vault_bump`. Created by `list_currency` with the fee vault. Protocol share available = `fees_collected − cashback_accrued − protocol_withdrawn`. Makes invariants 2 and 4 checkable in one account |
| `SettlementRecord` | `["settled", order_id]` | `bump`. Replay guard: `settle` `init`s it, so a match id settles at most once. Never closed (closing would re-enable the id); the operator pays its rent (~0.00095 SOL per settlement: 9 bytes + account overhead; see §3.10 for the bitmap replacement) |
| `Deal` | `["deal", proposer, deal_id]` | `proposer`, `counterparty` (or open), `asset_mint`, `payment_mint`, `asset_amount`, `payment_amount`, `proposer_side` (`Sell`/`Buy`), `expires_at: i64`, `status` (`Open`/`Executed`/`Cancelled`/`Expired`), `bump` |
| Deal vault | ATA(Deal PDA, deposited mint) | holds the proposer's deposit until accept/cancel/expiry |
| `Vault authority` | `["vault"]` | PDA signer for fee/cashback vaults and for delegated transfers |
| Fee vault | `["fee_vault", payment_mint]` token account, authority = vault authority | holds protocol fees + unclaimed cashback (+ unaccounted donations until swept). Created by `list_currency` **after** the mint policy check (the handler creates it with system + `InitializeAccount3` CPIs instead of an Anchor `init`, which would run before the check), so every `Approved` currency has one and a rejected mint never gets one. Lamports sent to the address beforehand do not block it (top up + allocate + assign, as Anchor's `init` does). A PDA rather than an ATA: anyone can create an ATA, so creating one could be front-run to block `list_currency` |

### 3.3 Instructions

| Instruction | Signer | Effect |
|---|---|---|
| `initialize_config` | admin | create `Config` |
| `submit_listing(asset_class, doc_hash)` | issuer | create `Listing{Pending}` for `Equity`/`FixedIncome`/`Credit`; require `issuer == asset_mint.mint_authority` and `supply == 0`; in the same instruction move the mint authority to the `["mint_authority", asset_mint]` PDA (`set_authority` CPI signed by the issuer) (§3.12) |
| `request_issuance(amount, recipient, doc_hash)` | `listing.issuer` | listing `Pending` or `Approved`: create the next `IssuanceBatch{Requested}` (§3.12) |
| `approve_issuance` / `reject_issuance` | listing_authority | approve: listing `Approved`, mint the batch to the recipient via the PDA, emit `IssuanceExecuted`; reject: close the request without minting (§3.12) |
| `burn_with_reason(amount, reason, reference)` | holder | burn own tokens of an issuer-listed asset with reason `Redemption`/`Cancellation`, emit `TokensBurned` (§3.12) |
| `list_currency(asset_mint)` | listing_authority | create an `Approved` `Currency` listing directly (stablecoin issuers such as Circle/Tether do not submit listings; Niara curates which currencies trade); `cashback_eligible = false` |
| `approve_listing` / `suspend_listing` / `delist` | listing_authority | change status, emit event |
| `init_cashback_ledger` | anyone (payer) | create the `CashbackLedger` for (listing, payment mint) before its first settlement |
| `settle(order_id: [u8;16], asset_amount, payment_amount)` | settlement_operator | order-book mode: atomic swap via delegates (see 3.4) |
| `open_deal(deal_id, terms, expires_at)` | proposer | P2P mode: proposer deposits its side into the deal vault |
| `accept_deal` | counterparty | P2P mode: counterparty delivers its side; same instruction swaps both legs, charges fee, accrues cashback, closes vault (see 3.5) |
| `cancel_deal` | proposer (while `Open`) | refund deposit, close vault |
| `expire_deal` | anyone, after `expires_at` | refund deposit to proposer (permissionless crank) |
| `withdraw_cashback(amount)` | `listing.issuer` | pull cashback from fee vault (≤ `accrued − withdrawn` of its `CashbackLedger`), to any account of the payment mint except the vault |
| `withdraw_protocol_fees(amount)` | treasury | pull protocol share (≤ `fees_collected − cashback_accrued − protocol_withdrawn` of the `FeeLedger`); can never touch issuers' cashback |
| `sweep_excess` | treasury | move the fee vault's balance above what the ledger owes (`balance − (fees_collected − protocol_withdrawn − cashback_withdrawn)`, i.e. unaccounted donations) to any account of the payment mint except the vault; fails with `NothingToSweep` when there is none. Ledger untouched; afterwards invariant 4 holds with equality. Emits `ExcessSwept { treasury, payment_mint, destination, amount, vault_balance_after }` |
| `propose_change` / `execute_change` | admin | timelocked fee/cashback/operator/authority changes |
| `pause` / `unpause` | admin | circuit breaker (see below) |

**Pause principle.** A pause stops the protocol from paying out based on its
own accounting, but never stops a user from taking back their own escrowed
deposit. While `paused`:
- **blocked:** `settle`, `open_deal`, `accept_deal`, `withdraw_cashback`,
  `withdraw_protocol_fees`, `sweep_excess`, `approve_issuance`. If the
  incident is an accounting bug (e.g. over-credited cashback), withdrawals are
  exactly the drain path; minting is the highest-impact action there is.
- **always allowed:** `cancel_deal` and `expire_deal` (a user reclaims their own
  deposit, which the protocol's accounting does not decide), `burn_with_reason`
  (a holder destroys its own tokens), listing actions (`submit_listing`,
  `list_currency`, `approve_listing`, `suspend_listing`, `delist`),
  `request_issuance` and `reject_issuance` (neither mints),
  `init_cashback_ledger`, and admin/timelock actions.

Listing status gates trading, not payouts: accrued cashback and protocol fees
stay withdrawable after the asset is delisted or the currency is suspended.

### 3.4 `settle` — the core

`order_id` is the off-chain **match (fill) id**, a 16-byte UUID (the
`matches.id` primary key), not the maker's order id: one order can be filled by
several matches, and each match settles at most once. `payment_amount` is in
raw units of the payment mint; the program does no price conversion.

Preconditions (all enforced on-chain):
- `!config.paused`; signer is `config.settlement_operator`
- `asset_amount > 0`, `payment_amount > 0`
- `buyer != seller`; neither is the vault authority
- `["settled", order_id]` does not exist yet (replay guard: the operator
  cannot settle the same match twice, even within the delegated amounts)
- asset listing: `status == Approved`, `asset_class == Equity`,
  `listing.asset_mint == asset_mint`
- payment mint: has a listing with `asset_class == Currency` and
  `status == Approved`
- mint policy re-run on both mints (extension allowlist; asset mint has no
  freeze authority)
- token accounts: correct owner (buyer/seller wallet), correct mint, correct
  token program; fee vault and cashback ledger are the PDAs for this pair
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
5. `emit_cpi!(Settled { order_id, asset_mint, payment_mint, buyer, seller, asset_amount, payment_amount, fee, cashback })`

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
   buying) into a vault ATA owned by the `Deal` PDA. The deposit is cancelable
   while `Open`, so custody stays non-custodial.
2. `accept_deal`: the counterparty signs. One instruction transfers the
   counterparty's side directly, releases the escrowed side, charges the fee,
   accrues cashback, closes the vault (rent back to the proposer) and emits
   `DealExecuted`.
3. `cancel_deal` / `expire_deal`: refund after cancellation or after `expires_at`.

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
`initialize_config`. Production plan: move the upgrade authority to a **Squads
multisig** (ideally with its own time delay), or **make the program immutable**
(freeze the upgrade authority) after audit. Until then, "timelocked admin" must
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
  `submit_listing` and `list_currency`). Accepted: SPL Token mints, and
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
  for the mint (in `list_currency`, before the fee vault), so every rejected
  mint fails with `UnsupportedMintExtension` on both paths. Token-2022 cannot add the rejected
  extensions to a mint after initialization, so the check holds for the life of
  the listing; `settle` and `open_deal` will still re-run it on both the asset
  and the payment mint as defense in depth.
- **Freeze authority.** The extension allowlist does not cover the base mint's
  `freeze_authority`. Asset mints (`submit_listing`) must have
  `freeze_authority == None`, otherwise the issuer could freeze escrow vaults,
  fee vaults or holders' accounts mid-settlement (`FreezeAuthorityNotAllowed`).
  Neither token program can add a freeze authority once it is `None`, so the
  check holds for the life of the listing; `settle` re-checks it. Currency mints
  (`list_currency`) **may** have one, because real stablecoins do (USDC, USDT):
  this is an accepted, curated risk. A currency issuer can freeze a fee vault
  or a user's payment account, which makes settlements and withdrawals in that
  currency revert (nothing moves) until it unfreezes.

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
  and two `Currency` listings, plus a delegated buyer/seller pair for every
  asset × payment combination (including invalid ones), then runs random
  sequences of `settle` (valid and invalid markets, zero amounts, replayed
  ids, wrong signer, fills that leave the seller nothing), listing status
  changes, pause/unpause, both withdrawals (incl. overdraws and wrong signers),
  timelocked fee/cashback changes with out-of-range values, re-delegations,
  `init_cashback_ledger`, donations straight into the fee vaults and
  `sweep_excess` (incl. wrong signers and empty sweeps), and issuance on the
  four issuer listings: `request_issuance` (incl. zero amounts, wrong
  signers, suspended/delisted listings), `approve_issuance`/`reject_issuance`
  of the oldest open batch (incl. wrong signers, non-`Approved` listings,
  paused protocol) and `burn_with_reason` (incl. overdraws). Invariants 1, 2,
  3, 4, 5, 8, 9, 10 and 11 are checked after every step (4 as `vault ==
  unwithdrawn + unswept donations`, so strict equality after every sweep; 11
  also checks the mint authority is still the program PDA), the fee ledgers
  are cross-checked against the sum of `Settled` events, and
  `issued`/`burned` against `IssuanceExecuted`/`TokensBurned`. `PROPTEST_CASES`
  sets the number of sequences (default 48). A mutation check (cashback
  under-recorded in the `FeeLedger`) made it fail and shrink to a minimal
  sequence. Invariants 6 and 7 come with the escrow (week 3).
- Build: `scripts/build.sh` wraps `anchor build`, deletes the `.so`/IDL first and
  fails unless fresh artifacts exist, so tests never run against a stale binary.
- Invariants (must hold under fuzzing):
  1. `payment_amount == seller_receives + fee` for every settlement
  2. `Σ cashback accrued ≤ Σ fees collected` per payment mint
     (`FeeLedger.cashback_accrued ≤ FeeLedger.fees_collected`, and
     `FeeLedger.cashback_accrued == Σ CashbackLedger.accrued` for that mint)
  3. no settlement on a listing whose status ≠ `Approved`
  4. vault balance == unwithdrawn protocol fees + unwithdrawn cashback
     (`fees_collected − protocol_withdrawn − cashback_withdrawn`). Anyone can
     transfer into a fee vault, so between sweeps this is `≥`; donations are
     not accounted and cannot be withdrawn as fees or cashback.
     `sweep_excess` moves them to the treasury, and **after a sweep it is
     strict equality**. Fuzzing tracks donations and checks
     `vault == unwithdrawn + unswept donations`
  5. `fee_bps ≤ MAX_FEE_BPS` always, even after timelocked changes
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

### 3.10 Out of v1 scope (state it, don't fake it)

Security and token-lifecycle work (guardian role, issuer compromise and
recovery, Niara-created mints with a recovery delegate, cashback protection,
the production cybersecurity program) is in §9.

- Fixed income / credit **lifecycle**: coupon payments, amortization, maturity
  redemption, default handling. In v1 these tokens trade but do not pay out;
  the lifecycle (snapshot of holders + on-chain distribution) is roadmap.
- FX pricing feeds: P2P deals in `Currency` use the rate the two parties agree;
  no oracle in v1. In Brazil, FX is regulated by the BCB (Lei 14.286/2021 and the
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
- The hand-over is permanent. A listing rejected while `Pending` (delisted)
  leaves an empty mint nobody can use; the issuer creates a new mint. A
  delisted asset keeps its supply (holders can still burn) but never grows.
- Freeze authority is already `None` for asset mints (§3.8), so the mint
  authority is the only authority left on the mint.

**Batches.** Every increase of supply is a numbered `IssuanceBatch`
(`["batch", listing, batch_no]`, `batch_no` as `u64` little-endian):

| Instruction | Signer | Effect |
|---|---|---|
| `request_issuance(amount, recipient, doc_hash)` | `listing.issuer` | listing `Pending` or `Approved`; `amount > 0`, non-empty `doc_hash`, `recipient` not the default key. Creates batch `listing.next_batch_no` (`Requested`) and increments the counter. Mints nothing. Emits `IssuanceRequested` |
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
- Batches may be requested while the listing is `Pending` (the initial
  offering can be prepared before approval) but execute only once it is
  `Approved`. A `Suspended` listing keeps its requests; they execute after
  reinstatement or are rejected.
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
- Deploy scripts with chainid guards: Sepolia `11155111`, Base Sepolia `84532`.
- Same invariant fuzzing suite extended with the listing invariant.
- **`P2PEscrow`** (EVM mirror of 3.5): `openDeal` (deposit), `acceptDeal` (atomic
  swap + fee + cashback via `CashbackDistributor`), `cancelDeal`, `expireDeal`.
  Accepts only `FixedIncome`/`Credit`/`Currency` listings.
  Priority: after the Solana escrow is done. Cut it first on EVM if late.

Note: verify whether the July 2026 Sepolia deployment of niara-contracts is still
live and documented; v1 needs a **new deployment anyway** (new registry + factory).

### 4.1 Listing events for the Register indexer

A listing becomes tradable at exactly one event on every chain: **`ListingApproved`**.
Both paths emit it, on Solana and on EVM; there is **no separate currency event**
(no `CurrencyListed`). The indexer tells currencies apart by `asset_class` /
`assetClass == Currency`, which always comes with `cashback_eligible == false`, a
zero `doc_hash` and no issuer (`Pubkey::default()` / `address(0)`).

| Listing path | Solana instruction → event | EVM (`ListingRegistry`) function → event |
|---|---|---|
| Issuer submits (`Pending`) | `submit_listing` → `ListingSubmitted { listing, asset_mint, issuer, asset_class, doc_hash }` | `submitListing` → `ListingSubmitted(token, issuer, assetClass, docHash)` |
| Niara approves an issuer listing (`Pending` → `Approved`) | `approve_listing` → `ListingApproved` | `approveListing` → `ListingApproved` |
| Niara lists a currency (created `Approved`) | `list_currency` → `ListingApproved` | `listCurrency` → `ListingApproved` |
| Reinstatement (`Suspended` → `Approved`, any class) | `approve_listing` → `ListingApproved` (new `approved_at`) | `approveListing` → `ListingApproved` (new `approvedAt`) |
| Suspension (`Approved` → `Suspended`) | `suspend_listing` → `ListingSuspended { listing, asset_mint }` | `suspendListing` → `ListingSuspended(token)` |
| Delisting (final) | `delist` → `ListingDelisted { listing, asset_mint }` | `delist` → `ListingDelisted(token, previousStatus)` |

`ListingApproved` carries the same fields on both chains: Solana
`{ listing, asset_mint, issuer, asset_class, cashback_eligible, doc_hash, approved_at }`,
EVM `ListingApproved(address indexed token, address indexed issuer, AssetClass assetClass,
bool cashbackEligible, bytes32 docHash, uint64 approvedAt)` (EVM has no separate listing
account, so `token` plays the role of both `listing` and `asset_mint`).

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
  `order_id` and creates `["settled", order_id]`).

---

## 6. Frontend (`niara-site`) and Register

- Wallets: wagmi v3 (EVM) + Solana Wallet Standard (Phantom, Solflare, Backpack).
- New real flow (separate from the simulated `/trade`):
  create mint → submit listing (mint authority moves to the program) → (admin)
  approve listing → issuer requests an issuance batch → (admin) approve batch →
  place order → match → settle → issuer withdraws cashback. Chain selector: Solana / Sepolia / Base Sepolia.
- Deploy on **Vercel**.
- **Niara-Register:** extend the indexer to capture `ListingApproved`
  (both listing paths, §4.1), `Settled`, `IssuanceExecuted` and `TokensBurned`
  on all three chains into the "Global registry" area (today empty
  because the Exchange has not operated for real). On EVM, `TokensBurned` is
  emitted by each `NativeAssetToken` (not by the registry), so the indexer
  watches every token deployed by the `AssetTokenFactory` (`AssetTokenCreated`).
  On Solana there is **no separate `CashbackCredited` event**: `Settled` carries
  `fee` and `cashback`, so the indexer credits the issuer's cashback from
  `Settled` (one event per settlement, nothing to correlate). On EVM, `Settled`
  has no `cashback` field and the `CashbackDistributor` emits `CashbackCredited`
  in the same transaction (§4.2). Listing `doc_hash` can be
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

Cut order if behind schedule (last to first): UI polish → EVM `P2PEscrow` →
signed intents (document as trust assumption) → Base deploy (trivial to add
later). **Never cut:** Solana settle, Solana P2P escrow, issuer cashback, honest
labeling.

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

## 9. Roadmap — security and token lifecycle

Not in v1 unless marked done. Ordered by what an incident would need first:
contain it, recover from it, prove what happened.

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
   (listing status gates trading, not payouts), which is why §9.5 adds a
   per-listing cashback freeze.
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
- **Per-listing freeze.** The guardian can freeze cashback withdrawals for one
  listing (a flag on the listing, checked by `withdraw_cashback`), without
  pausing the whole protocol. Unfreezing follows "resume slow" (§9.1): the
  listing authority behind the multisig, not the guardian. Accrual continues
  while frozen; nothing is lost.
- **Issuer key hygiene, checked at onboarding.** Issuers must sign from a
  multisig (Squads on Solana, Safe on EVM) or a hardware wallet. A multisig is
  verifiable on-chain (the issuer address is a Squads vault / Safe contract);
  a hardware wallet can only be attested by process, so the onboarding record
  says which one was checked and how.

### 9.6 Cybersecurity program (production)

**Keys.**
- Program upgrade authority and `admin` in a **Squads multisig** (ideally
  with its own time delay), or the program made immutable after audit (§3.6).
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
