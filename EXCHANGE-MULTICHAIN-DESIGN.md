# Niara Exchange — Multichain Settlement Design (v1)

Status: DRAFT for design freeze · Target: Solana Foundation interview (4–6 weeks)
Chains in scope: Solana Devnet (priority), Ethereum Sepolia, Base Sepolia
Roadmap only (not in v1): Robinhood Chain Testnet, HyperEVM Testnet, Tempo Testnet

> Everything here runs on testnets with test tokens. No real assets, no real money,
> no regulatory authorization. Every screen and doc must say so.

---

## 1. Product model (what we are actually building)

A peer-to-peer tokenized securities exchange with **self-custody** and **curated listing**:

1. **Direct issuance.** An issuer creates its asset token from its own wallet
   (equity, fixed income or credit). The token *is* the instrument — native
   issuance, not a wrapper of an asset held by a custodian.
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
        └──────────────┴──────── events (Settled, CashbackCredited, ListingApproved)
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
| `Listing` | `["listing", asset_mint]` | `asset_mint`, `issuer`, `asset_class` (`Equity`/`FixedIncome`/`Credit`/`Currency`), `status` (`Pending`/`Approved`/`Suspended`/`Delisted`), `cashback_eligible`, `doc_hash: [u8;32]` (offering document hash — registered in Niara-Register), `approved_at`, `bump` |
| `CashbackLedger` | `["cashback", listing, payment_mint]` | `accrued: u64`, `withdrawn: u64`, `bump` |
| `Deal` | `["deal", proposer, deal_id]` | `proposer`, `counterparty` (or open), `asset_mint`, `payment_mint`, `asset_amount`, `payment_amount`, `proposer_side` (`Sell`/`Buy`), `expires_at: i64`, `status` (`Open`/`Executed`/`Cancelled`/`Expired`), `bump` |
| Deal vault | ATA(Deal PDA, deposited mint) | holds the proposer's deposit until accept/cancel/expiry |
| `Vault authority` | `["vault"]` | PDA signer for fee/cashback vaults and for delegated transfers |
| Fee vault | ATA(vault authority, payment_mint) | holds protocol fees + unclaimed cashback |

### 3.3 Instructions

| Instruction | Signer | Effect |
|---|---|---|
| `initialize_config` | admin | create `Config` |
| `submit_listing(asset_class, doc_hash)` | issuer | create `Listing{Pending}` for `Equity`/`FixedIncome`/`Credit`; require `issuer == asset_mint.mint_authority` |
| `list_currency(asset_mint)` | listing_authority | create an `Approved` `Currency` listing directly (stablecoin issuers such as Circle/Tether do not submit listings; Niara curates which currencies trade); `cashback_eligible = false` |
| `approve_listing` / `suspend_listing` / `delist` | listing_authority | change status, emit event |
| `settle(order_id, asset_amount, payment_amount)` | settlement_operator | order-book mode: atomic swap via delegates (see 3.4) |
| `open_deal(deal_id, terms, expires_at)` | proposer | P2P mode: proposer deposits its side into the deal vault |
| `accept_deal` | counterparty | P2P mode: counterparty delivers its side; same instruction swaps both legs, charges fee, accrues cashback, closes vault (see 3.5) |
| `cancel_deal` | proposer (while `Open`) | refund deposit, close vault |
| `expire_deal` | anyone, after `expires_at` | refund deposit to proposer (permissionless crank) |
| `withdraw_cashback(amount)` | `listing.issuer` | pull cashback from fee vault |
| `withdraw_protocol_fees(amount)` | treasury | pull protocol share |
| `propose_change` / `execute_change` | admin | timelocked fee/cashback/operator/authority changes |
| `pause` / `unpause` | admin | circuit breaker (settle reverts while paused) |

### 3.4 `settle` — the core

Preconditions (all enforced on-chain):
- `!config.paused`; signer is `config.settlement_operator`
- `listing.status == Approved` and `listing.asset_mint == asset_mint`
- token accounts: correct owner, correct mint, correct token program
- seller's asset account `delegate == vault_authority` and `delegated_amount ≥ asset_amount`
- buyer's payment account `delegate == vault_authority` and `delegated_amount ≥ payment_amount`

Math (checked, `u128` intermediates):
```
fee      = ceil(payment_amount * fee_bps / 10_000)      // never zero by truncation when fee_bps > 0
cashback = listing.cashback_eligible ? floor(fee * cashback_bps / 10_000) : 0
seller_receives = payment_amount - fee
```

CPIs, all in one transaction (atomic — any failure reverts everything):
1. `transfer_checked` asset: seller → buyer (authority = vault PDA as delegate)
2. `transfer_checked` payment: buyer → seller, `seller_receives`
3. `transfer_checked` payment: buyer → fee vault, `fee`
4. `CashbackLedger.accrued += cashback`
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

  Extensions are checked at listing time. Token-2022 cannot add the rejected
  extensions to a mint after initialization, so the check holds for the life of
  the listing; `settle` and `open_deal` will still re-run it on both the asset
  and the payment mint as defense in depth.

### 3.9 Testing

- Unit/integration: LiteSVM (Rust, `cargo test` after `anchor build`; fast, deterministic)
- Invariant/property testing: **`proptest` over LiteSVM** — random sequences of
  instructions (valid and invalid) against the real `.so`, with the invariants
  below checked after every step; same role Foundry invariant fuzzing plays in
  niara-contracts. Trident is not used: as of 2026-11 its latest stable release
  (0.12.0) targets Solana 2.3 crates and documents no Anchor 1.x support.
  Re-evaluate if that changes.
- Build: `scripts/build.sh` wraps `anchor build`, deletes the `.so`/IDL first and
  fails unless fresh artifacts exist, so tests never run against a stale binary.
- Invariants (must hold under fuzzing):
  1. `payment_amount == seller_receives + fee` for every settlement
  2. `Σ cashback accrued ≤ Σ fees collected` per payment mint
  3. no settlement on a listing whose status ≠ `Approved`
  4. vault balance == unwithdrawn protocol fees + unwithdrawn cashback
  5. `fee_bps ≤ MAX_FEE_BPS` always, even after timelocked changes
  6. an escrowed deposit always ends in exactly one place: counterparty (executed)
     or proposer (cancelled/expired). It is never stranded and never paid twice
  7. no `accept_deal` after `expires_at`; no `expire_deal` before it
  8. mode/class coupling: `settle` never succeeds on a non-`Equity` listing;
     `open_deal`/`accept_deal` never succeed on an `Equity` listing
  9. a `Currency` listing never accrues cashback
  10. `settle` and the escrow instructions only accept a payment mint that has an
      `Approved` `Currency` listing

### 3.10 Out of v1 scope (state it, don't fake it)

- Fixed income / credit **lifecycle**: coupon payments, amortization, maturity
  redemption, default handling. In v1 these tokens trade but do not pay out;
  the lifecycle (snapshot of holders + on-chain distribution) is roadmap.
- FX pricing feeds: P2P deals in `Currency` use the rate the two parties agree;
  no oracle in v1. In Brazil, FX is regulated by the BCB (Lei 14.286/2021 and the
  VASP rules), which matters for production but not for testnet.
- **Evaluate `solana-v4`.** v1 builds against the Solana 3.x crates (Anchor's
  default `solana-v3` feature). Moving to the `solana-v4` (Agave 4.3) crates is a
  roadmap item, to be evaluated once the program is feature-complete.

### 3.11 Toolchain (pinned)

| Component | Version | Notes |
|---|---|---|
| Anchor (CLI + `anchor-lang`/`anchor-spl`) | **1.2.2** | pinned per project in `Anchor.toml` `[toolchain] anchor_version`; installed with `avm` (includes the `close`-into-self and `init_if_needed` Token-2022 fixes) |
| Solana crates | **3.x** (`solana-v3`, Anchor default) | `solana-v4` not enabled; see roadmap |
| Solana CLI | **4.3.0** (Agave) | not pinned in `[toolchain]` (pinning `solana_version` switches the machine-wide active release) |
| Rust | **1.99.1** | `anchor-lang` MSRV is 1.89 |
| Tests | **LiteSVM** (Rust) | Anchor 1.x default template |
| TypeScript client | **`@anchor-lang/core`** 1.2.x | replaces `@coral-xyz/anchor` |

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
- Idempotent: a match is settled at most once (unique constraint on `match_id`).

---

## 6. Frontend (`niara-site`) and Register

- Wallets: wagmi v3 (EVM) + Solana Wallet Standard (Phantom, Solflare, Backpack).
- New real flow (separate from the simulated `/trade`):
  issue token → submit listing → (admin) approve → place order → match → settle →
  issuer withdraws cashback. Chain selector: Solana / Sepolia / Base Sepolia.
- Deploy on **Vercel**.
- **Niara-Register:** extend the indexer to capture `ListingApproved`, `Settled`,
  `CashbackCredited` on all three chains into the "Global registry" area (today
  empty because the Exchange has not operated for real). Listing `doc_hash` can be
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
