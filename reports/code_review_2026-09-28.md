# GalaxyTrader MK3 — Code Review Report

- **Reviewed revision:** `3df6ca9` ("0.17.5-3"), branch `claude/funny-einstein-9rxh9d`
- **Date:** 2026-09-28
- **Scope:** every code file in the mod:
  - 76 AI scripts (`aiscripts/`)
  - 52 Mission Director scripts (`md/`)
  - 21 UI Lua files (`ui/`)
  - the library diffs, `content.xml` and `ui.xml`
  - about 8.7 MB of code
  - translations were checked mechanically
- **Mode:** read-only. No code was changed; this report is the only file added.

---

## 1. Summary

The review found **about 230 distinct issues**. None is a guaranteed crash or savegame corruption. However, several recent changes (0.17.5 and 0.17.5-3) introduced **regressions in core trading paths**, and a number of long-standing defects affect trading, fleet handling, performance and savegame size.

| Severity | Count | Meaning |
|---|---|---|
| High | 8 | Core feature broken or badly wrong in common scenarios, multi-second freezes, or permanent loss of player state |
| Medium | ~75 | Wrong behaviour in specific scenarios, noticeable hitches, recurring log spam, unbounded state growth |
| Low | ~120 | Edge cases, minor inefficiency, misleading logs/UI text |
| Info | ~25 | Dead code, maintainability, fragile patterns |

**Confidence:**
- **Confirmed** means the issue was traced end to end in the code.
- **Likely** means the code path was traced, but the impact depends on engine behaviour or timing that cannot be run here.
- **Possible** means the finding is plausible but needs in-game confirmation.
- Findings marked **✔** were independently re-checked against the source by the report author, on top of the subsystem reviewer.

### 1.1 Fix first (ranked)

| # | ID | Sev | Conf | Issue | Introduced |
|---|---|---|---|---|---|
| 1 | G02-01 ✔ | High | Confirmed | MK3 "fleet spread" uses `<do_all min= max=>`, which runs a **random** number of times, so the cached trade list is duplicated, truncated or indexed out of range on every cache read | 0.17.5-3 |
| 2 | G03-01 ✔ | High | Confirmed | MK4 sell-only trades (clearance `[CL]` / cargo disposal) are always rejected as `profit_missing`, so a loaded MK4 ship can never dispose of its cargo | 0.17.5 |
| 3 | G09-01 ✔ | High | Likely | Changing the destroy event made `HandleCommanderDestroyed` live: losing a GT fleet commander now **de-registers every GT subordinate** (names, mods, registry, pilot paused), including the ship X4 is promoting | 0.17.5 |
| 4 | G10-01 | High | Likely | Maintenance `$Preparing` never expires, and the queue is wiped on every load, so affected ships **never get repaired or resupplied again** and stall 30 s every loop | 0.17.5-3 (became harmful) |
| 5 | G11-01 | High | Likely | The new pilot-row pruning deletes the only XP record of ejected, SAR-rescued and demoted pilots; the "seed carrier" is never read back, so **pilot XP is lost** | 0.17.5 |
| 6 | G08-01 ✔ | High | Confirmed | Assist promotion/restore recreates GT default orders with **only a subset of the params**, so fleets lose the sector whitelist, blocked stations, illegal-ware and ignore flags; MK3 cached restore is broken | long-standing |
| 7 | G16-01 ✔ | High | Confirmed | Diagnose sorts up to 2,000–10,000 pairs with an O(n²) selection sort in one MD frame, a **multi-second freeze per click** | long-standing |
| 8 | G04-02 / G15-01 | High | Confirmed | Route-cache cleanup spawns one 120 s cue instance **per trade**, and each one sweeps every MK3/MK4 cache in one frame: continuous micro-stutter, plus it deletes rows designed to be re-resolved | long-standing |
| 9 | G06-01 ✔ | Medium | Confirmed | `@$this.ship…` typo (9 sites) disables the "still has a GT order" guard in MK1/MK2 `on_abort`, so every abort fires the orphan/cancel pipeline | long-standing |
| 10 | G14-01 ✔ | Medium | Confirmed | Ships removed from GT are silently re-added to `global.$GT_Ships` as an empty row, and stay "registered" forever | long-standing |
| 11 | G01-01 ✔ | Medium | Confirmed | The 0.17.5 reservation re-check is incomplete in MK4: a peer's claim is detected but the trade still runs, so two ships still deliver to the same slot | 0.17.5 |
| 12 | G05-04 / G05-05 | Medium | Confirmed/Likely | `AllowIllegal=false` is ignored in every ware-basket search path, and the shared MK3 cache has no legality dimension, so **contraband gets traded** | long-standing |
| 13 | G15-05 ✔ | Medium | Likely | `WakeUpShipsStuckInOldCode` fires on **every** load and knocks queued ships out of their scheduler wait: a post-load fleet-wide stall | long-standing |
| 14 | G04-01 | Medium | Likely | After a load, a resumed cache-phase `Done` re-homes the ship to its current sector and loses its params; MK4 ships then leak the only MK3 live slot | long-standing |
| 15 | G13-01 ✔ | Medium | Confirmed | Settings `Init` is an instantiated cue with an instantiated child, so it leaks one cue instance per load, and validation runs N times per load | long-standing |
| 16 | G12-05 ✔ | Medium | Confirmed | `$ThreatReports + 1` without `@` on rows that never had it logs a lookup error on **every hit** to such a ship | long-standing |
| 17 | G03-02 ✔ / G03-04 ✔ | Medium | Confirmed | MK4 ignores the distance-penalty slider, and fill ratios use integer division, so Min Station Storage and the critical bonus are wrong | long-standing |
| 18 | G17-02 ✔ | Medium | Confirmed | Lua blacklist tracking is keyed by `uint64_t` cdata (identity keys), so `RemoveFromShip` never removes the GT blacklist | long-standing |
| 19 | G17-01 ✔ | Medium | Confirmed | Pilot-exchange cancel never clears in-flight swap state: ships stay "busy", the plan never finishes, and a cancelled swap can still execute | long-standing |
| 20 | G17-03 | Medium | Likely | Unanchored `ffi.new` array passed to the engine: rare use-after-free / hard crash on blacklist updates | long-standing |

### 1.2 How reliable the recent changelog is

Several 0.17.5 changelog items do not hold at runtime:

- **"Two ships could claim the same delivery slot" is fixed for MK3 only.** MK4 still executes the trade (G01-01). For MK3 the reservation row lives for a single frame, so peers never see it, and the new `$Amount` stamp has no effect (G02-08).
- **"`GLX_ReleaseTrade` owner parameter", "expiry sweep" and "reservation `$Amount`" changed library functions that nothing calls** (G09-11). All real reservation traffic is inline in MK3 and MK4.
- **"A failed sell leg no longer strands a loaded MK4 ship" is dead code.** The fast path sits after a `this.$tryNextTrade?` existence test that is always true (G01-08). Even when reached, every sell-only candidate is rejected (G03-01).
- **"Clearance ships could never sell contraband" is undercut three ways:**
  - MK4 rejects all sell-only trades (G03-01).
  - Root MK4 ships never refresh `AllowIllegal` after init (G01-05).
  - MK3's `on_abort` deletes the route-legality policy as soon as the trade orders take over (G02-02).
- **"MK1 ignored the military sector blacklist" is fixed at 3 of 5+ call sites** (G05-10 / G06-08).
- **"Auto-promotion could bind every pilot to one hull":** the fix is in unreachable code (G11-14).
- **"Cache-pool statistics no longer accumulate wares quadratically":** the fix is in a library with no callers (G04 Info).
- **"The seed-keyed XP carrier survives for rescue":** it is never read back (G11-01).
- **"Removed the miner's inert chunking machinery … lists are only tens of entries long":** station lists can be hundreds long in the common home-sector mode (G07-05).
- **Changelog statement: "X4 does not short-circuit `and`".** The Egosoft scripting documentation describes `and`/`or` as short-circuit. The fix it motivated is harmless, but a wrong belief like this can send future fixes in the wrong direction. The earlier "locals are lost at `<wait>`" episode (reverted in de47c3c) is the precedent.

---

## 2. Cross-cutting bug patterns

These patterns recur across the codebase. Fixing them as a class (plus a lint rule) prevents many future regressions.

### 2.1 `?` used as a truthiness or null test

`$x?` is an **existence** test. It is true for declared variables holding `null`, `false` or `0`. The sites below all misuse it:

| Site | Effect |
|---|---|
| `order.trade.galaxytradermk4.xml:9519` `this.$tryNextTrade?` (G01-08 ✔) | Every failed trade skips the market wait; the 0.17.5 cargo fast path is dead |
| `lib.gt.mk4.validate.amounts.xml:212` (G03-09) | Sell-side clamp reason lost, so rejects are mis-counted |
| `lib.gt.mk4.offer.refresh.xml:46,49`; `lib.gt.mk4.policy.resolve.xml:20-26` (G03-09) | Fallbacks and null-slider seeding are dead |
| `lib.gt.mk4.exec.virtualmoney.xml:84` (G03-09, G01 note) | A failed `create_trade_offer` still calls `create_trade_order` with a null offer and returns `$Ordered=true` |
| `md/gt_tradesearch_scheduler.xml:1290-1295` (G04-05) | MK4-live routing conditions can never fire |
| `md/gt_ship_management.xml:3662` `not $xpVal?` (G10-04) | Name-refresh fallback dead, so op-state tags (`[RP]`, `[RESUPPLY]`) are often not rendered |
| `aiscripts/order.build.equip.xml:50-61,86-91` (G10-10) | Null arithmetic errors |
| `md/gt_xp_training.xml:1375` (G11-08) | "Training completed" notification never shows on some paths |
| `md/gt_libraries_blacklist.xml:134-142` (G12-15) | Group auto-detect dead (latent) |
| `md/gt_context_rename.xml` `$pilot?` (G13-15) | Pilotless ship goes to `Register_Pilot` with `pilot=null` |
| `md/gt_ship_state_utilities.xml:37,127,130` (G14-03) | `.exists` evaluated on null: error per op-state refresh and per commander change |
| `md/gt_home_fleet_profile.xml:183-207` (G15-02 ✔) | Fleet-min cargo floor always null, so the feature never applies |
| `md/gt_context_diagnose.xml:279` (G16-09) | Lookup error for pilotless ships |
| `lib.gt.failed_sector_pairs.xml:41` (G08-15) | Null records copied through |
| `lib.gt.mk4.classify.xml:34` (G03-15) | Fix reverted in de47c3c (library unused) |

**Recommendation:** add a validator lint that flags `$var?` (and `not $var?`) where `$var` is unconditionally `set_value`'d earlier in the same scope, or is a declared `<param>` with a default.

### 2.2 `@$this.` typos (reads an undefined local named `$this`)

This happens at 9 sites, and the `@` hides the lookup error:
- `order.trade.galaxytradermk1.xml:3052, 3057, 3059`
- `order.trade.galaxytradermk2.xml:3884, 3888, 3895, 3899, 3901`
- `order.trade.galaxyminer.xml:2372` (+2476 per G07-10)

Related: `lib.gt.miner_find_target.xml:79` uses a bare `ship` (G07-10). **Recommendation:** lint for `\$this\.`.

### 2.3 Integer division

When both operands are integers, `/` truncates:

- **G03-04 ✔:** `lib.gt.mk4.tradematch.xml:1714, 1739` and `lib.gt.mk4.score.trades.xml:81`. The fill ratio and yard-free ratio are always 0 or 1.
- **G08-08:** `order.trade.perform.xml:542`. The XP value multiplier divides money by money, so it is 0 for sales below the divisor.
- **G06-13:** `order.trade.galaxytradermk2.xml:1866-1872`. The NPC price-cap ratio.

### 2.4 Unit mistakes (credits vs cents vs hull points)

- **G10-02:** repair "cost" is `maxhull - hull` (hull points). It is compared with `player.money`, shown as Cr, and passed as `acceptedcost`. The partial branch passes the **whole balance**.
- **G16-02 ✔:** Diagnose money gate uses `$minPlayerMoney + 100000` (cents) where the runtime uses `(this.$minPlayerMoney + 1000)Cr`, and it displays `/100`.
- **G15-12:** `$GT_TradeStats.$TotalProfit` accumulates `/100` values while every other total stores raw values.

### 2.5 Exit paths that skip cleanup

- **Idle-park hold outlives the handoff** (G08-04 = G01-04 = G02-07). All four GT orders' `on_abort` handlers return early while `GT_IdleParkingHold.{ship}` exists. That skips `GT_Search_Abort`, the reservation release, the policy clear and the name restore. The hold rows are never swept, and `orders.base.xml` keeps suppressing undock.
- **Final-validation dead end → self-signal + `<return/>`** (G02-03 = G01-09). The ship restarts with no backoff, the reservation and `$GT_ActiveTrade` rows are left behind, and the `trade_rules_violation` retry branches are dead.
- **Commander-resync restart via `abort_called_scripts resume="init"`** (G02-05) skips the scheduler release.
- **`this.$pendingSearchParams`** (a captured Go) is never cleared on abort, restart or timeout (G01-10).
- **MK2 ware-exchange request/result keys** are not removed in `on_abort` (G06-12).

### 2.6 Load-time handling

| ID | Problem |
|---|---|
| G13-01 ✔ | `GT_GlobalSettings.Init` (instantiated) with an instantiated child `ValidateSettings` gains +1 permanent instance per load, and validation runs N times per load. Settings migration currently *depends* on this leak. |
| G12-06 ✔ | `BlacklistIdleReconcileWatchdog` gains +1 self-chaining 60 s loop per load. |
| G15-05 ✔ | `WakeUpShipsStuckInOldCode` runs every load and breaks queued waiters. |
| G10-01 / G15-06 | `SystemInitV3` wipes `$GT_MaintenanceQueue.$Requests` / `$GT_RegistrationQueue.$Ships` every load, while `$Preparing` flags persist. |
| G04-01 | Scheduler `InitSearchSemaphore` clears `$CacheActiveShips`; resumed cache searches are mis-routed afterwards. |
| G13-04 | Unversioned "migrations" overwrite the player's slider values (`CacheQueryMaxEntries`, `EarlyExitThreshold`, `MaxOffersPerWare`) on every load. |
| G09-02 | No load-time prune of rows keyed by already-destroyed ships (saves from before 0.17.5 never had any per-ship cleanup). |
| G11-06 | Stable-identity migration is O(n²) on every load and removes rows while iterating. |

### 2.7 Unbounded savegame state (consolidated)

These tables are keyed by ship, station, sector or pilot and are never (or only partially) pruned. Many are also missing from the `UnregisterShip` sweep, and that sweep only runs when a `$GT_Ships` row still exists (G09-03).

| Table | Source |
|---|---|
| `$GT_CommanderGTState` | G09-03, G09-06 |
| `$GT_LiveSearchScratch.{ship}` (full offer lists) | G05-08, G09-03 |
| `$GT_TradeMatchScratch.{ship}` and `this.$tm_*` lists | G03-11, G05-08 |
| `this.$gt_cs_*` cache-scan state | G04-10 |
| `$GT_OfferIndex` (4 profiles/home, expired snapshots) | G05-08 |
| `$GT_NoTradeHistory`, `$GT_Ship_Performance` | G09-03 |
| `$GT_ThreatDetectThrottle`, `$GT_ThreatBroadcastThrottle`, `$GT_ThreatDetectLogThrottle` | G09-03 |
| `$GT_MaintenanceOrders/RepairOrders/ResupplyOrders/CleanAt/LastSignaledAt/FailedResupply` | G10-08, G09-03 |
| `$GT_IsolatedTradeActive.{ship}`, `$GT_IsolationCheckCache.{ship}.{sector}` | G12-08 |
| `$GT_BlacklistPathCache` (per ship idcode, per epoch) | G04-06, G12-07 |
| `$GT_RouteLegalityCache`, `$GT_SpacesScopeCache` | G08-10, G08-05 |
| `$GT_Ship_State` (+ write-only `$StateHistory` up to 50 per ship; also created for NPC Assist ships) | G14-06, G08-06 |
| `$GT_RequestStatus.{destroyed ship}` | G14-06 |
| `$GT_ShipIDCodeMap` (only pruner is a non-instantiated cue that fires once per save) | G15-03 ✔ |
| `$GT_PilotLiveIndex` orphans; `$GT_PilotBySeed` never pruned | G11-13 |
| `$GT_CargoCostTracking`, `$GT_LastTradeScan`, `$GT_LastReconstituteSignal` | G15-11, G15-15 |
| `$GT_IdleParkingHold`, `HoldUntil`, `DockedSince`, `GT_ReturnHomeHold*`, `GT_MK1DockedSince` | G08-04 |
| `$GT_SectorDistanceCache` (caches `-1` forever) | G05-14 |
| `$GT_TradeCacheByWare` / `$GT_TradeCacheMK4ByWare` (rebuilt, never read) | G04-02 |

**Recommendation:**
1. Route every per-ship table through one `GT_PurgeShipRows(ship)` library.
2. Call it from `UnregisterShip` (without the registry gate), from GT-removal paths, and from a one-shot load migration that prunes dead handles.

### 2.8 Heavy single-frame work

| ID | Where | Cost |
|---|---|---|
| G16-01 ✔ | Diagnose pair sort | O(n²), n up to 10,000 |
| G04-02 / G15-01 | Route cache cleanup | full cache sweep per trade |
| G17-04 | PHQ pilot-exchange planner (Lua) | ~88M inner calls at 200 ships |
| G12-02 | `event_object_attacked` threat pipeline | n²/2 library calls per hit, unthrottled |
| G13-08 | Invulnerability cheat reconcile | O(n²) every 60 s |
| G10-03 | Maintenance station scan (`signal_cue_instantly`, no deferral) | uncapped per ship |
| G07-04 / G07-05 | Miner policy fingerprint; de-chunked storage gate | stations × ships per call |
| G09-04 | Ship-update / registration "throttled" queues | throttle is ineffective |
| G05-06 | MK4 demand-led search runs the buyer scan twice | ~2× offer queries |
| G01-03 | MK4 validates every candidate after the window is full | hundreds of yields/pathfinding calls |
| G11-06, G11-10, G09-10, G08-09 | load migration, training station scan, drone-loss scans, `move.generic` enemy-departure handler for every ship | — |

### 2.9 Dead code volume

About half of `gt_libraries_general.xml` is unreferenced: 56 of ~100 libraries, 2,660 of 5,446 lines (G14-09). Large unreachable areas also exist in:
- `glx_lib_reservations.xml` (G09-11)
- `gt_pilot_promotion.xml` (G11-14)
- `gt_trading_ai.xml`, `gt_market_intelligence.xml` and the reporting cues (G15-16)
- `gt_debug.xml`, `gt_configuration.xml` (G13-15)
- `gt_libraries_pathfinding.xml` (G12-18)
- the cache-waiter machinery in the scheduler (G04 Info)
- the MK4 tradematch modes (G03-14)
- `lib.gt.mk4.classify` (G03-15)
- three Lua files not loaded by `ui.xml` (G17-06)

Dead code has already absorbed several "fixes" (see §1.2). Deleting it would make reviews and grep results meaningful again.

---

## 3. Findings by subsystem

Format: **ID — title** · Severity · Confidence · Location, followed by problem/impact and fix.

### 3.1 MK4 order — `order.trade.galaxytradermk4.xml`, `…mk42.xml` (G01)

- **G01-01 ✔ — Peer reservation re-check detects the claim but still runs the trade** · Medium · Confirmed · `mk4:7080-7165`
  - The trade is made primary at 7084-7085. `$resClaimTaken` only guards the reservation write at 7150; MK3 does `<continue/>` instead.
  - Two ships deliver to the same destination+ware slot, and the loser ends in `[CL]`.
  - **Fix:** undo the selection and `continue`, or claim only right before `create_trade_order`.
- **G01-02 — Aux / Build-Storage gate uses a stale `global.$GT_AIParameters.{ship}` override** · Medium · Confirmed · `mk4:5372-5379, 6914-6954`; `gt_trading_ai.xml:728-738`
  - The first cargo disposal stores `IgnoreCarrierAux=true` (Aux slider default 0) permanently.
  - Raising the slider later has no effect, even after an order restart.
  - **Fix:** derive the gates from live `this.$mk4Priorities`.
- **G01-03 — Validation sweeps every candidate after the maxTrades window is full** · Medium · Confirmed · `mk4:5595-5602, 7055, 7078`
  - Each candidate runs validate.reach, offer.refresh, validate.amounts and two dockchecks, all of which yield, over up to 200 cache rows.
  - This costs seconds of idle time per pass and lets the primary's 10 s reservation expire.
  - **Fix:** break once the window is full.
- **G01-04 — `on_abort` skips all cleanup while an idle-park hold exists** · Medium · Likely · `mk4:10545-10572` (see §2.5).
- **G01-05 — Root ships never refresh AllowIllegal, route legality, jump ranges, wares, home or distance penalty after `<init>`** · Medium · Likely · `mk4:957-966, 1161, 1261, 3032-3138`
  - This undercuts the 0.17.5 contraband fix until the order restarts.
- **G01-06 — `mk4BuildStorageOnlyMode` is not passed to `lib.gt.cache.search`** · Medium · Confirmed · `mk4:4106-4137, 4219-4250`
  - With BS-only plus Serve Home Only, the cache never hits, so every cycle forces a live search.
- **G01-07 — Scheduler `$CacheReadOffset` is not forwarded** · Low · Confirmed · `mk4:4106-4250`. There is no fleet rotation on MK4 cache reads, so ships collide on the same rows.
- **G01-08 ✔ — `this.$tryNextTrade?` is an existence test** · Low · Confirmed · `mk4:9336, 9351, 9519`. Every failure skips the market wait, and the new `$tradeFailedWithCargo` path is unreachable.
- **G01-09 — Final-validation dead end → self-signal + `<return/>`** · Low · Confirmed · `mk4:7453-7456` (see §2.5).
- **G01-10 — Captured `GT_Search_Go` (`this.$pendingSearchParams`) is never cleared** · Low · Likely · `mk4:202-217, 3219`. A stale grant can start a live search without a slot.
- **G01-11 — A buy leg can be queued without its sell leg when an NPC SellOffer dies after validation** · Low · Likely · `mk4:8304, 8447, 8541-8559`. The player pays for undeliverable cargo.
- **G01-12 — Every cache miss wipes this ship's FailedShips flags pool-wide, including permanent reasons, in one frame** · Low · Likely · `mk4:4154-4191`.
- **G01-13 — Dead interrupt plumbing** · Info · `this.$tradeFoundViaInterrupt` is never read; a `GT_Trade_Found` during the market wait is discarded.
- **OK:** v1→v2 patch coverage; owner-checked release; AllowIllegal producers; scheduler Go/Done/Abort contract; MK42 stub param parity.

### 3.2 MK3 order — `order.trade.galaxytrader.xml` (G02)

- **G02-01 ✔ — Fleet spread loops use `do_all min/max` (random iteration count)** · **High** · Confirmed · `galaxytrader.xml:4280, 4293` (added in 3df6ca9; the only `do_all min=` in the repo)
  - The near-best scan reads `1..rand(first,last)`.
  - The tail loop re-appends the head and drops most of the tail.
  - With priority buckets, `$spreadPick` can exceed `.count`, producing index errors and null trades.
  - This runs on every cache-sourced validation pass.
  - **Fix:** `do_all exact="$spreadLast - $spreadFirst + 1" counter="$k"` with `idx = first + k - 1`.
- **G02-02 — `on_abort` removes `$ActiveTradePolicy` when TradePerform pre-empts the default order** · Medium · Likely · `6643-6654, 8584-8586`
  - The route-legality guard in `move.generic` never sees the policy, so contraband is flown through prohibiting sectors.
  - **Fix:** only clear the policy when the GT order is really gone.
- **G02-03 — Final-validation failure signals itself and `<return/>`s** · Medium · Likely · `6480-6491`
  - No backoff; the reservation (6221) and `$GT_ActiveTrade` rows are leaked; `trade_rules_violation` retry is dead; `[CL]` can hot-loop on the single clearance slot.
- **G02-04 — The cache retry after a reject ignores the price band, min profit and ROI** · Medium · Confirmed · `7203-7227`
  - It reads non-existent `$effectiveSellPriceMax` / `$gt_sellpricemax` (zero writers) and hard-codes `minROI=0` and `minAbsoluteProfit=0`.
  - Trades below the player's profit floor get executed.
- **G02-05 — Commander-resync restart (`abort_called_scripts resume="init"`) skips `GT_Search_Abort`** · Medium · Likely · `413-427`. A scheduler slot is held until the 60 s self-heal; an aborted cache write can be left partial.
- **G02-06 — Early exits between reservation claim (6221) and release (6703) leave rows live** · Low · Confirmed. `$GT_ReservationStats.$Active` drifts.
- **G02-07 — Idle-park early return in `on_abort`** · Low · Possible · `8551-8579` (see §2.5).
- **G02-08 — MK3 reservation rows live for one frame only, so peers never observe them** · Info · Confirmed · `5288-5337, 6221, 6703`.
- **G02-09 — `on_abort` sends `GT_Search_Abort` at every trade start (scheduler walk)** · Low · Likely · `8582`.
- **OK:** post-dockcheck re-check with skip; owner-checked releases; AllowIllegal producers; v8 patch; library contracts; 3df6ca9 removals are clean.

### 3.3 MK4 libraries and MK4 scheduler (G03)

- **G03-01 ✔ — Null-price guard rejects every MK4 sell-only trade** · **High** · Confirmed · `lib.gt.mk4.validate.amounts.xml:293-362`; caller `mk4:6806`
  - Sell-only rows have no `$BuyOffer`, so `$buyPriceForRecalc` stays null.
  - 4540bdd changed `$buyPriceForRecalc?` (always true) to `!= null`, which now always returns `profit_missing`.
  - **Fix:** use a buy price of 0 (or `$trade.$BuyPrice`) when `$isSellOnly`.
- **G03-02 ✔ — `lib.gt.mk4.score.trades` ignores the distance-penalty setting** · Medium · Confirmed · `score.trades:13, 75, 90-91`; callers `mk4:4289, 4661, 5335` never pass `distancePenalty`
  - The default 0.5 overwrites `$baseSupplyScore`, so the slider has no effect on MK4.
- **G03-03 — With priorities active, zero-priority buyers still consume the 2,000-pair budget** · Medium · Likely · `mk4.tradematch:940-969`.
- **G03-04 ✔ — Integer-division fill ratios** · Medium · Confirmed · `mk4.tradematch:1714, 1739`; `score.trades:81` (see §2.3)
  - Min Station Storage only rejects stations at 100%; the critical bonus goes to every under-target station; the empty-yard boost only applies to fully empty yards.
- **G03-05 — Hard-coded 60 s stale check evicts running MK4 live searches** · Medium · Likely · `gt_tradesearch_scheduler_mk4.xml:79` (also `gt_tradesearch_scheduler.xml:357`). This bypasses `MaxConcurrentMK4Live`; the setting `StaleThresholdSeconds` (120) exists but is not used here.
- **G03-06 — MK4 dispatcher only looks at the head of each home's FIFO** · Medium · Confirmed · `scheduler_mk4:163-180`. Head-of-line blocking across fleets that share a home.
- **G03-07 — An MK4 cache write dequeues and resets every MK3 live-queued ship at the same home** · Medium · Likely · `scheduler_mk4:396-415`. MK3 ships sharing a home with MK4 can starve.
- **G03-08 — Stale `$baseSupplyScore` when urgency drops to 0** · Low · Confirmed · `score.trades:53-92`.
- **G03-09 — More `?`-as-truthiness sites** · Low · Confirmed (see §2.1). The `exec.virtualmoney` case can call `create_trade_order` with a null offer.
- **G03-10 ✔ — `md.GT_TradeSearch_Scheduler_MK4.InitSearchSemaphore` does not exist** · Low · Confirmed · `scheduler_mk4:65, 347`. The cue lives in `GT_TradeSearch_Scheduler` (line 13 uses it correctly).
- **G03-11 — Per-ship match scratch and `this.$tm_*` lists persist in the save** · Low · Confirmed · `mk4.tradematch:728-739`.
- **G03-12 — Gate distance recomputed per pair (`$distBuy` depends only on the outer loop)** · Low · Confirmed · `mk4.tradematch:1316, 1322`.
- **G03-13 — MK4 cache-updated handler does not check `$CachePool`; a stale `this.$gt_mk4FleetKey` on ex-MK4 pilots** · Low · Possible · `scheduler_mk4:340-349`.
- **G03-14 / G03-15 — Unreachable tradematch modes; unused `lib.gt.mk4.classify` still carries the old `?` bug** · Info.
- **OK:** priority-class key tests; inverted-gate fix; dual-axis flag by value; `sinceversion=9` patch; null offer writes in `offer.refresh`; clamp restore; reverse-removal loops.

### 3.4 Trade cache and schedulers (G04)

- **G04-01 — After a load, cache-phase `Done` is re-homed to `$ship.sector` and loses its params** · Medium · Likely · `gt_tradesearch_scheduler.xml:1304, 1669, 1688, 1946`
  - Live search runs around the current sector, not home.
  - MK4 ships go into the MK3 live pool; completion as `mk4live` never frees `LiveActiveShips`, so all MK3 live searches stall 60–120 s.
- **G04-02 — `GLX_CachePool_EventCleanup` runs as an un-debounced whole-pool sweep** · **High** (merged with G15-01) · Confirmed · `glx_lib_cache.xml:116-251`; `gt_trading_execution.xml:536-583`
  - One instantiated 120 s cue per `GT_DirectTrade` / `GT_TradeFailure`.
  - Each sweeps all homes and fleet buckets in one frame, rebuilds `*ByWare` indices that nothing reads, and drops dead-offer rows that `cache.write` / `cache.search` deliberately keep for re-resolve.
  - **Fix:** flag-gated single scheduler, sweep one home per tick, use the same purge rule as the readers, delete the ByWare rebuild.
- **G04-03 — Dead delivery offer on a live station is never re-resolved (zombie rows)** · Low · Likely · `cache.search:746-816, 2043-2054`. An unguarded clamp on a dead offer produces errors in isolated mode.
- **G04-04 — The 0.17.5-3 live-profit rule also applies to MK4's reachability-only `score_for_ship` call** · Low · Confirmed (dormant) · `score_for_ship:201-233`.
- **G04-05 ✔ — Duplicated `mk4live` completion blocks send `GT_Trade_Found` / `GT_No_Trade_Found` twice and run the dispatchers twice** · Low · Confirmed · `scheduler.xml:1800, 1912`. The routing tests at 1290-1295 are dead (`?`).
- **G04-06 — `$GT_BlacklistPathCache` grows per ship × sector² until the epoch changes** · Low · Likely · `score_for_ship:94-168`.
- **G04-07 — New `maxTradesPerWare` param without a version bump or patch (`version="1"`)** · Low · Likely · `score_for_ship:6, 13, 272`.
- **G04-08 — IPP rows exempt from min profit at 1554 but not in the new clamp (2055)** · Low · Confirmed.
- **G04-09 — Rows deleted during forward iteration** · Low · Confirmed · `cache.search:655-664, 796-813, 1078-1094`. Skipped rows; duplicated MK4 rotated candidates.
- **G04-10 — `this.$gt_cs_*` scan state stays on the pilot** · Low · Confirmed.
- **Info:**
  - The cache-waiter machinery is dead: `$preferCacheRequeue` / `$parkAsCacheWaiter` are hard-coded false, and `$cacheRetryPass` is undefined.
  - `GLX_CachePool_AccumulateFleetStats` and `GLX_PurgeCacheOfferPair_AllHomes` have no callers.
  - `$GT_TradeCacheHomes` is stale.
  - `cache.write` `$Written` returns the candidate count, not the rows written.
- **OK:** gate-distance memo + v10 patch; coverage-refresh ranking; reader-side Ignore Player Pricing; nested MK4 cache handling; removed fleet-dispatch code.

### 3.5 Live search, tradematch, scoring, MK1 cache (G05)

- **G05-01 — `cache_refresh` clamps seller offers with the refreshing ship as buyer** · Medium · Likely · `lib.gt.live.search.xml:1069-1095, 1249-1275`. The shared home cache loses routes other ships (other cargo types, more money) could run.
- **G05-02 — Offer-index snapshots are stored after the writer's per-ware cap and ship filters; the profile key omits IgnoreMK1Supply** · Medium · Confirmed · `live.search:225, 1120-1127, 2110-2267`.
- **G05-03 — The shared MK1 pool is filled with one ship's cargo-limited view** · Medium · Likely · `lib.gt.mk1.cache.*`; `mk1:947-955`. Other cargo types get an empty HIT for the full TTL.
- **G05-04 ✔ — `AllowIllegal=false` is ignored in every ware-basket collection path** · Medium · Confirmed · `live.search:1203-1277, 2387-2538, 2857-2905, 1602-1646`. MK3/MK4 manual baskets trade contraband. **Fix:** skip `ware.illegal` unless allowed (exempt sell_only).
- **G05-05 — The shared MK3 cache has no legality dimension and the cache read takes no `allowIllegal`** · Medium · Likely. One AllowIllegal ship poisons the home cache for all ships.
- **G05-06 — MK4 demand-led search falls through the whole buyer scan twice** · Medium · Confirmed · `live.search:2951-2976, 1938, 2638`.
- **G05-07 — The priority-ware seller pass appends duplicate offers (no seen-set)** · Medium · Confirmed · `live.search:3035-3142`. Priority wares get about half as many distinct routes.
- **G05-08 — `$GT_LiveSearchScratch`, `$GT_OfferIndex` and `this.$tm_*` are never pruned** · Medium · Confirmed (see §2.7).
- **G05-09 — Fallback search enforces MaxSell on both legs; MaxBuy is ignored** · Medium · Confirmed · `lib.gt.fallback.search.xml:122-127`.
- **G05-10 — MK1 military-blacklist fix is incomplete: supply/export fills call pathfinding without `blacklistGroup`; the pool key lacks the group** · Medium · Confirmed · `mk1:1042-1046, 1832-1836`; `lib.gt.pathfinding.xml:724` (see also G06-08).
- **G05-11 — Serve Home Only scans the full coverage area when the home has no player buyers** · Low · Confirmed.
- **G05-12 — Selection sort gives unreachable (-1) buy sectors a free boost; per-row blacklist-aware distance without a memo** · Low · Confirmed · `lib.gt.score.selection_sort.xml:54-72`.
- **G05-13 — Per-ware cap uses `<break/>` (not `continue`) in the basket/priority loops, which cuts off the build-storage reserve** · Low · Confirmed.
- **G05-14 — `$GT_SectorDistanceCache` caches `-1` forever** · Low · Possible.
- **G05-15 — Single-frame build-storage scan in MK4 clearance; dead diversify branch** · Low.
- **OK:** 0.17.5-3 offer-index profiles (LRU of 4, stable keys, null-safe resume); MK2 per-pilot ware-exchange mailbox; sell_only blacklisted same-sector handling; tradematch amount and reservation keys.

### 3.6 MK1 / MK2 orders and ware-exchange bridge (G06)

- **G06-01 ✔ — `@$this.ship…` typo in MK1/MK2 `on_abort`** · Medium · Confirmed (typo) / Likely (impact) · `mk2:3884-3901`, `mk1:3052-3059`
  - Every abort, including immediate-order handoffs, runs the detach pipeline (`GT_Order_Cancelled`, IsGTActive=false, orphan check).
  - MK1 also unconditionally removes `$GT_MK1SuppliedStations.{home}` (3041-3043).
- **G06-02 — MK2 ware-exchange destinations use the raw storage gap; inbound reservations are not subtracted; `MaxShipsForWare` is never tested** · Medium · Likely · `mk2:2004-2007, 2365, 3352-3361`; `lib.gt.tradematch.xml:401-406`. Several ships over-fill the same destination.
- **G06-03 — A secondary leg that lost its source claim still queues a deliver/sell with amount 0** · Medium · Confirmed · `mk2:3309-3389`. Lua rejects the whole request, so the valid primary is denied as well.
- **G06-04 — Queue-time logbook entries are written before the cycle can still be denied** · Low · Confirmed. Phantom "supply queued" entries every 10–60 s.
- **G06-05 — MK1 opportunistic (below-target) supply can never run** · Medium · Confirmed · `mk1:893-897, 957`.
- **G06-06 — MK1 supply affordability divides by the home buy price instead of the supplier price** · Low · Confirmed · `mk1:1289-1290, 1328`.
- **G06-07 — The 3df6ca9 auto-source walk re-runs validate_lane + tradematch per supplier (up to 20) and loses skip diagnostics** · Low · Confirmed.
- **G06-08 — MK1/MK2 blacklist group missing on search-space and tradematch calls** · Low · Confirmed (see G05-10).
- **G06-09 — Null-basket guard only partial** · Low · Confirmed · `mk2:2462-2468`; `mk1:1577-1591`.
- **G06-10 — MK1 supply-side `$Offers` not coalesced to `[]`** · Low · Possible · `mk1:1008, 1103`.
- **G06-11 — MK1 supply `cantradewith` legs swapped** · Low · Possible · `mk1:1195-1209`.
- **G06-12 — Ware-exchange Lua invalid-ship branch never signals (5 s timeout); request/result keys not cleared in `on_abort`** · Low · Confirmed · `ui/gt_mk2_ware_exchange.lua:339-344`.
- **G06-13 — MK2 NPC price cap compares a money ratio with the relative-price scale** · Low · Possible · `mk2:1866-1872`.
- **G06-14 — `global.$GT_TradeReservations` never initialised, so the MK1 reservation block is dead** · Info.
- **OK:** MD↔Lua ware-exchange contract after 3df6ca9; deferred-sell ordering and deny cleanup; MK1 live-slot ticket released on every exit; patches MK1 4→5 / MK2 7→8; loop-extent fix.

### 3.7 GalaxyMiner (G07)

- **G07-01 — A sell-claim waiter reports `Hit` whenever the pool is fresh, even if it lacks the waiter's wares** · Medium · Confirmed · `lib.gt.miner.sell.claim.xml:70-76`; `order.mining.routine.gt.xml:1449, 1499-1511`
  - Mixed-cargo fleets get "No buyers found" and `set_order_failed`, then idle for minutes.
  - The routine's fill basket is only its own cargo.
- **G07-02 — New `$Deferred` claim result has no branch; it is treated as "no buyers"** · Low · Confirmed · `routine:1499-1545`; `galaxyminer:2465-2499`.
- **G07-03 ✔ — Sector-cache key uses `.` separators** · Medium · Likely · `lib.gt.miner_sectors_inrange.xml:96, 218` (since 0.17.2)
  - Per the repo's own documented engine behaviour (`gt_libraries_general.xml:25-27`), dots split the key into a path, so the cache likely never stores or hits and the full BFS runs every call.
  - **Fix:** use `|`.
- **G07-04 — The 0.17.5-3 blacklist-policy fingerprint scans every in-range cluster/sector on every call, before the cache check** · Medium · Likely · `miner_sectors_inrange:72-96`.
- **G07-05 — De-chunked physical storage gate: station lists can be hundreds long (home-sector mode, level ≥ 6)** · Medium · Likely · `lib.gt.miner_physical_storage_gate.xml:141-249`.
- **G07-06 — Demand and overflow-sell pool keys ignore the ship's blacklist policy** · Low · Confirmed.
- **G07-07 — Claim liveness has no timeout backstop after the age prune was removed** · Low · Possible.
- **G07-08 — Cached demand stations used without `.exists`; stale snapshots of unlimited age** · Low · Likely.
- **G07-09 — `this.$minerDeliveryOnlySlice` is not reset at `main_loop`, so a capital ship without collectors loops in prep** · Low · Confirmed · `galaxyminer:2139, 2224, 2598`.
- **G07-10 ✔ — Typos `@$this.$homeStation.sector` (2372, 2476) and bare `ship.commander.sector` (`miner_find_target:79`)** · Low · Confirmed.
- **G07-11 — Stale claim/pool comments; `this.$gtMsc*` names shared by two libraries** · Info.
- **OK:** owner claims are atomic, released on every exit, and never released by a non-owner; contracts; patch 10→11; bounded pool sizes.

### 3.8 Assist, movement, vanilla diffs, small AI libs (G08)

- **G08-01 ✔ — Create/restore/inherit paths pass partial param sets** · **High** · Confirmed · `order.assist.xml:10-26, 36-53, 58-73, 149-173, 1234-1273`
  - MK3 drops `sectorwhitelist`, `blockedstations`, `ignoretraderules`, `ignoreplayerpricing`, `ignore*`, `logbookentries` and more.
  - MK4 drops `allowillegal`, `enforceRouteIllegalLegality`, `sectorwhitelist`, `minstorage`, `maxTrades`, `distancepenalty` and more.
  - The MK3 inherit table has no `$OrderId`, so 1237 reads `$gtParams.$OrderId` without `@` and the cached restore fails.
  - After a commander loss and promotion, the fleet silently loses its restrictions (e.g. flies into excluded sectors).
  - **Fix:** one full per-order param table used at every site; add `$OrderId='GalaxyTraderMK3'`.
- **G08-02 — `order.trade.perform` escape flag is always true on arrival and includes `objectactivity`** · Medium · Confirmed · `order.trade.perform.xml:79-179`. The post-arrival blacklist check never blocks GT ships.
- **G08-03 ✔ — `move.generic` picks the blacklist group by hull size (M/L/XL → military), not by primary purpose** · Medium · Confirmed · `move.generic.xml:78-82, 103, 795-799`
  - The route cache never matches.
  - `$ActiveRoute` is rewritten (sell leg dropped, military group), causing false reroute aborts and missed legality-cache invalidations.
- **G08-04 — Idle-park hold outlives the handoff; every GT `on_abort` early-returns; hold rows are never swept** · Medium · Confirmed (see §2.5).
- **G08-05 — `GT_SpacesScopeCache` is keyed without the ship's blacklist but filtered by the writer's per-ship blacklist** · Medium · Likely · `lib.gt.pathfinding.xml:724-808`.
- **G08-06 — Assist "Phase 7" creates `$GT_Ship_State` rows for any Assist ship, NPCs included** · Medium · Likely · `order.assist.xml:1435-1475`. Unbounded growth; `order.wait`'s GT gate passes for non-GT ships.
- **G08-07 — `validate_lane` path check ignores the whitelist** · Low-Medium · Likely · `lib.gt.blacklist.validate_lane.xml:173-230`.
- **G08-08 — XP value multiplier integer-divides; distance bonus always 1.0** · Low · Likely · `order.trade.perform.xml:542-552`.
- **G08-09 — Enemy-departure handler in `move.generic` runs for every ship in the galaxy on every sector change and writes locals into vanilla scope** · Low · Confirmed · `move.generic.xml:362-496`.
- **G08-10 — `GT_RouteLegalityCache` unbounded** · Low · Confirmed.
- **G08-11 — Restock completion signal only from `on_abort`, without `$Cycle`** · Low · Likely.
- **G08-12 — Rescue/dock `create_npc_template` replaced for all ships, not just GT pilots** · Low · Possible.
- **G08-13 — `this.$gtCargoPreClamp*` stale across trades** · Low · Confirmed.
- **G08-14 — Fragile diffs** · Info
  - `interrupt.changedsector.xml` is a full vanilla replacement, made only to drop a debug `chance`.
  - `lib.request.orders.xml` uses positional `do_elseif[1]`.
  - One selector matches on a `debug_text` string.
  - Whole-block `<replace>`s in `order.trade.perform`, `order.assist` and `move.generic`.
- **G08-15 — `lib.gt.failed_sector_pairs` version lowered 2→1 (dev saves); `$record?` always true** · Info.
- **OK:** route-registry sector index symmetry; route-legality cache never serves cargo-dependent verdicts; idle-park v4 patch; pay.account hop limit; completion hooks gated on GT.

### 3.9 Core system and reservations library (G09)

- **G09-01 ✔ — `HandleCommanderDestroyed` became live in 0.17.5 and aborts every GT subordinate** · **High** · Likely · `gt_core_system.xml:3841, 3960-4006, 4348`
  - 4540bdd changed `<event_object_destroyed object="player.entity"/>` (fires only when the player dies) to `<event_player_owned_destroyed/>`.
  - At event time the promoted subordinate is still on Assist, so every subordinate gets `GT_Ship_Order_Aborted`.
  - The reason string is not in the commander-cleanup whitelist, so the full removal runs: vanilla name restored, mods dismantled, registry row deleted (including `$InheritedGTDefaultOrderParams` needed by the promotion restore), pilot paused plus a "holiday" logbook entry.
  - Also fires for station commanders.
  - **Fix:** queue `QueueOrphanVerifyIfNotPending` (the 3 s promotion window) instead of emitting an abort, and skip stations.
- **G09-02 — Saves from before 0.17.5 keep every destroyed GT ship's rows; there is no migration** · Medium · Confirmed. Handle reuse can inherit them.
- **G09-03 — `UnregisterShip` sweep is gated on `$GT_Ships.{ship}?` and misses many tables** · Medium · Confirmed · `gt_core_system.xml:3689, 3760-3777` (see §2.7).
- **G09-04 — Ship-update and registration "throttled" queues do not throttle** · Medium · Confirmed · `gt_core_system.xml:5610, 5627-5658, 4061, 4211-4245`
  - `$Processing` is set true and false in the same action block, and every enqueue kicks a processor.
  - `PostRegistrationDelay` clears the flag 300 ms early.
- **G09-05 — Registration queue entries are not re-validated at dequeue** · Low · Confirmed. Dead-ship rows; re-registration of removed ships.
- **G09-06 — `$GT_CommanderGTState` unbounded; `$ReactivationPending` can stick** · Low · Confirmed · `714-766`.
- **G09-07 — `CheckShipOrphaned` TRANSIENT re-check can poll every 3 s forever (no attempt cap)** · Low · Possible.
- **G09-08 — Ship-update coalescing overwrites different update types per ship (`pilot_change` `$oldPilot` lost)** · Low · Likely · `5597`.
- **G09-09 — "Holiday" logbook entry not idempotent** · Low · Confirmed.
- **G09-10 — Every destroyed player object (drones included) triggers full registry scans** · Low · Confirmed · `3639-3643, 2243-2264`.
- **G09-11 — Most of `glx_lib_reservations.xml` is dead** · Info · Confirmed
  - `GLX_ReserveTrade`, `GLX_IsTradeReserved`, `GLX_CleanupExpiredReservations` and the TradeIndex are never called.
  - The 0.17.5 library fixes therefore have no runtime effect, and `$GT_ReservationStats.$Active` only grows.
- **G09-12 — `GLX_ShipIsInGTService` (direct commander only) disagrees with `GT_CheckCommanderStatus` (walks 6 levels)** · Low · Confirmed.
- **G09-13 — Dead catch-up loop over a just-reset table; `$GT_ActiveTraderCount` decrement is dead** · Info.
- **OK:** `SystemInit` cannot wipe live tables on load (`$GT_Initialized` persists); `GLX_ReleaseTrade` owner logic; event queues are bounded; reservation key format consistent; retry chains bounded.

### 3.10 Maintenance, ship modifications, ship management (G10)

- **G10-01 — `$Preparing` never expires; queued requests are dropped on load** · **High** · Likely · `gt_maintenance.xml:56, 104, 380-398`; `lib.gt.maintenance.execute.xml:40-56`; `gt_trading_ai.xml:172-176`
  - `DoMaintenance` aborts on `$Preparing`, and the executor never re-signals while it is set, so the ship never gets maintenance again and every loop waits 30 s.
  - **Fix:** time out `$Preparing` (e.g. 60 s, or not present in `$Requests`) and re-queue or clear at load.
- **G10-02 — Repair cost measured in hull points** · Medium · Confirmed (units) · `gt_maintenance.xml:631-707`; `lib.gt.maintenance.execute.xml:120` (see §2.4).
  - Wrong funds gate, wrong displayed cost, and `acceptedcost` set to the whole wallet or a meaningless value.
- **G10-03 — `ExecuteMaintenance` runs synchronously, so `MaxConcurrent` never bounds per-frame work; repair-station scan is uncapped** · Medium · Confirmed · `406, 2621-2796, 955-1048`.
- **G10-04 — `GT_RefreshShipName` registry fallback is dead (`not $xpVal?`), so most refresh requests rename nothing** · Medium · Likely · `gt_ship_management.xml:3657-3675`.
- **G10-05 — Shared equipment-station cache is sorted and truncated (30) by the builder ship's distance** · Low · Confirmed · `765-857`.
- **G10-06 — Failed-resupply cooldown written but never read** · Low · Confirmed · `2335-2339`.
- **G10-07 — Logbook messages built as raw strings (`'{77000,3205}.[' + …`), which shows literal text; repair entry overwritten when both legs run** · Low · Confirmed · `655-664, 1893-1902`.
- **G10-08 — Six per-ship maintenance globals survive ship destruction** · Low · Confirmed (see §2.7).
- **G10-09 — `$EquipmentBuild.exists` dead (build id is not a component); MK1/MK2/Miner never clean `$GT_ResupplyOrders`, so cancelled equips are re-issued** · Low · Likely.
- **G10-10 — `?`-as-truthiness in `order.build.equip` finish logging** · Low · Confirmed.
- **Related:** G13-02 (the "Restock Countermeasures" toggle is ignored by maintenance).
- **OK:** queue slots released exactly once; cycle filter; independent repair/equip legs; up-front repair-check values; UI-map publish swap.

### 3.11 XP, training, pilots, redistribution (G11)

- **G11-01 — The 0.17.5 prune deletes XP of ejected, SAR-rescued and demoted pilots** · **High** · Likely · `gt_pilot_ecosystem.xml:844-853`
  - Rows are removed after 2 loads regardless of `$Status`.
  - No path restores XP from `$GT_PilotBySeed`; SAR gives the pilot a new seed; re-promotion creates a fresh XP-0 row and overwrites the seed row.
  - **Fix:** skip rows with status `ejected` / `paused` / `crew` (or with demotion/SAR markers), or restore from the seed row in `Initialize_Pilot_Data`.
- **G11-02 — Enrolling in the academy during a running course grants the new level for free** · Medium · Confirmed · `gt_context_academy.xml:228-248`; `order.dock.train.xml:289-292`; `gt_xp_training.xml:1126-1141, 1729-1735`
  - The abort is signalled to `player.galaxy` but `DockAndTrain` listens on `this.ship`.
  - The old timer completes with the academy target level, and the fee is never charged.
- **G11-03 — The 8c48fc5 `HandleUpdatePilotXP` fix makes MK1/MK2 earn XP twice per cycle** · Medium · Likely · `gt_xp_training.xml:2445-2480`; `mk1:1487-1492, 2845-2850`; `mk2:3734-3739`. The bare legacy signal plus `order.trade.perform`'s per-sale XP.
- **G11-04 — A stale `this.$peDockHandoff` hides a real cancel, so the exchange partner stays docked up to 2 h** · Medium · Likely · `order.dock.pilotexchange.xml:68-183`.
- **G11-05 — Releasing blocked XP (and Cancel Training) skips mandatory training levels** · Low · Confirmed · `gt_xp_training.xml:1241-1268`.
- **G11-06 — Stable-identity migration O(n²) every load; removes rows while iterating** · Low · Confirmed · `gt_pilot_field_migration.xml:132-147`.
- **G11-07 — Resumed training subtracts elapsed time twice; load recovery restarts the course** · Low · Confirmed.
- **G11-08 — `not $shownLevelUpNotification?` is always false** · Low · Confirmed · `gt_xp_training.xml:1375`.
- **G11-09 — Natural training is never charged for AI ships, yet the logbook quotes a licence fee** · Low · Confirmed.
- **G11-10 — `HandleTrainingNeeded` scans all trading stations in one frame with duplicate `gatedistance`** · Low · Likely.
- **G11-11 — Redistribution Lua payloads pass raw 64-bit ids where MD expects components** · Low · Likely (= G17-08).
- **G11-12 — Ungated `debug_text chance="100"` and development `raise_lua_event` probes in pilot-exchange paths** · Low · Confirmed.
- **G11-13 — `$GT_PilotLiveIndex` orphans; `$GT_PilotBySeed` never pruned; full UI-map republish per event** · Low · Confirmed.
- **G11-14 — The auto-promotion script (including the 0.17.5 claim fix) is unreachable** · Info · Confirmed.
- **OK:** sweep snapshots keys before removal; `@$xpData.$Ware` syntax; promotion claim table is pass-local; UI-map publish coalescing; academy fee idempotency; station-slot reserve/release symmetry.

### 3.12 Threat intelligence, blacklists, pathfinding MD (G12)

- **G12-01 — Repeat detections reset the sector's threat row to `table[]`, wiping the tracked hostiles** · Medium · Likely · `gt_threat_intelligence.xml:2824, 2978, 3140, 3893`. Premature "sector cleared", blacklist flip-flop, voice/logbook spam; `$GT_TrackedEnemyShipsGroup` grows.
- **G12-02 — Heavy per-hit processing on `event_object_attacked` with no throttle** · Medium · Likely · `2706-2868, 3487-3614`
  - Sector-wide `find_ship` calls, then about n²/2 `GT_ShipMatchesTracked` calls, then `NotifyShipsOfThreat` is re-signalled.
  - `$LastThreatTime` is written but never read.
- **G12-03 — "Blacklist Threat Level" setting never gates blacklisting** · Medium · Confirmed · `2832, 2986, 3148, 3905, 4148-4195`.
- **G12-04 — Turning off the dynamic blacklist leaves GT-auto sectors blocked (pending removals not flushed; `ShouldBlacklist` downgraded)** · Medium · Confirmed · `4125-4248, 4662`. See also G17-02.
- **G12-05 ✔ — `$ThreatReports + 1` without `@`** · Medium · Confirmed · `2839`. Most registry rows (all miners) lack the field, so every hit logs an error and may abort the rest of the block.
- **G12-06 ✔ — `BlacklistIdleReconcileWatchdog` gains an extra 60 s chain per load** · Medium · Likely · `4464-4481`.
- **G12-07 — Blacklist path-cache epoch ignores relation changes and player edits; per-ship cache unbounded** · Low-Medium · Likely.
- **G12-08 — `$GT_IsolatedTradeActive.{ship}` not swept; `$GT_IsolationCheckCache` grows ships × sectors** · Low-Medium · Confirmed.
- **G12-09 — Pending removals cleared before Lua acknowledges them (Lua drops `Update` while uninitialised)** · Low · Likely.
- **G12-10 — GT removals and Clear All delete the player's manual entries on the GT fleet blacklist; pins missing after Clear All** · Low · Likely.
- **G12-11 — Clear All passes key strings as `Sector`** · Low · Likely · `799-806`.
- **G12-12 — Clear All resets the voice Busy flag while speech is running, so lines overlap** · Low · Likely.
- **G12-13 — 1-based counters compared to 0 produce a leading comma in logbook ship lists** · Low · Confirmed · `662-714, 2391`.
- **G12-14 — `GT_FindSectorsInRange` reachability check on the wrong branch** · Low · Likely (diagnose only).
- **G12-15 — `GT_IsStationBlacklisted` `not $blacklistgroup?` with default null** · Low · Confirmed (latent).
- **G12-16 — MK3 faction blacklist toggles by list index against a stale list** · Low · Likely.
- **G12-17 — `remove_from_list` by value desynchronises the parallel tracked lists** · Low · Likely.
- **G12-18 — Dead code (`FleetThreatReporter`, incremental radius search, several libraries)** · Info.
- **OK:** MD↔Lua blacklist bridge payloads and events; consistent `'$'+macro.id` sector keys; pin/whitelist mutual exclusion; the speech queue cannot deadlock in normal flow.

### 3.13 Settings, configuration, naming, cheats, debug (G13)

- **G13-01 ✔ — Settings `Init` / `ValidateSettings` instance leak per load** · Medium · Confirmed · `gt_global_settings.xml:9-14, 218-226, 1016` (see §2.6). **Fix:** move validation into a library called from `Init`, and rename the cue so leaked instances are dropped.
- **G13-02 ✔ — The "Restock Countermeasures" toggle is never read; ships keep buying countermeasures** · Medium · Confirmed · `glx_lib_settings_menu.xml:1131-1149`; `gt_maintenance.xml:271` (+1068, 1384, 2209).
- **G13-03 ✔ — `$GT_Config.$Notifications.$TrainingStarted` is never seeded, so the reads without `@` fail** · Medium · Confirmed · `gt_configuration.xml:217-223`; `gt_xp_training.xml:881, 1441`. The training-start notification and logbook entry never appear.
- **G13-04 — Load-time migrations overwrite the player's slider values every load** · Low · Confirmed · `gt_global_settings.xml:758-804`.
- **G13-05 — Sliders with no effect: `HostileRelationThreshold` (threat code hard-codes -0.2), `LiveOfferSliceInterval`, `MaxOffersPerSearch`** · Low · Confirmed.
- **G13-06 — A slider set to 0 is ignored for Min Profit, Ship Proximity Weight and Hostile Relation (`!= null`)** · Low · Likely.
- **G13-07 — Ship name decorations stay frozen when ship naming is turned off** · Low · Confirmed.
- **G13-08 — Invulnerability cheat reconcile is O(n²) every 60 s** · Medium (while active) · Confirmed · `gt_cheats.xml:119-136`.
- **G13-09 — "Reveal universe" cheat also sets relation 0.32 with every faction, hostiles included, one click, no confirmation** · Low · Confirmed.
- **G13-10 — Max-XP cheat can lower piloting skill to 9** · Low · Confirmed.
- **G13-11 — Clear Pilot Renaming can keep "(T:n)" tags and save them as the original name** · Low · Confirmed.
- **G13-12 — `ConfigValidation` and `GT_WareFilter.Init` listen for `event_cue_signalled cue=ConfigInitV3`, which nothing signals, so they never run** · Low · Likely. This resolves the conflicting G15-13 claim; either way the ware-filter lists feed nothing.
- **G13-13 — Default naming pattern yields a leading space** · Low · Likely.
- **G13-14 — "Reset All Settings" is incomplete and inconsistent with the defaults** · Low · Confirmed.
- **G13-15 — Dead or broken code** · Info. `gt_debug.xml`, including the non-existent `md.GT_TradingAI.FindTrades` ✔; `ManualCleanup`; the `Create_Ship_Config` chain; `SendPilotData` flags; the rename `$pilot?`.
- **OK:** `$GT_LastTradeScan` fix holds; settings persist across loads; `{DORDER}` / `{FLEET}` walks are bounded; renaming limited to GT player ships; debug gating in these files; cheats opt-in.

### 3.14 Shared libraries and ship state (G14)

- **G14-01 ✔ — `GT_ShipOpState` recreates `$GT_Ships.{ship}` when clearing a flag, which re-registers removed ships** · Medium · Confirmed · `gt_libraries_general.xml:2114-2116`; `gt_core_system.xml:4429→4441`. **Fix:** never create the row in `GT_ShipOpState` when `active=false`, or clear pending data before removal.
- **G14-02 — Former GT ships are cleaned up and renamed again on every later commander change** · Medium · Likely · `gt_ship_state_manager.xml:803-818`; `gt_ship_state_utilities.xml:293-305`. The stale `$ShipID` pilot link overwrites the player's custom names.
- **G14-03 — `.exists` on declared-null variables after a `?` test** · Medium · Likely · `gt_ship_state_utilities.xml:37, 127, 130` (see §2.1).
- **G14-04 ✔ — Prune writes the literal key `'$currentSector'`** · Low · Confirmed · `gt_libraries_general.xml:152`. On overflow all failed-pair memory is wiped and the new record goes under a junk key. **Fix:** `table[{$currentSector} = …]`.
- **G14-05 — The full "ship destroyed" teardown runs on every successful sell** · Low · Likely · `gt_libraries_general.xml:2271-2415`, called from `gt_trading_signals.xml:153`. Breaks MK4 multi-leg batches; can abort the next queued search.
- **G14-06 — `$GT_Ship_State` rows with a 50-entry write-only history; unreachable `UpdateState` branches; `$GT_RequestStatus` left for destroyed ships** · Low · Confirmed.
- **G14-07 — Ungated `LOCK ACQUIRE` / `RELEASED` `debug_text` on every search** · Low · Confirmed · `515, 524, 662`.
- **G14-08 — MK2 has no `logbookentries` param, and subordinates treat it as off** · Low · Likely.
- **G14-09 — 56 of ~100 libraries unreferenced (2,660 lines); `GT_CalculateTradeEfficiency` has an extra ×100** · Info.
- **OK:** all 44 referenced library contracts (params, required params, result fields) verified by script; fallback-counter `$` fix; `GLX_ReleaseTrade` owner; pilot-exchange scan dedupe; route registry.

### 3.15 Trading MD subsystems (G15)

- **G15-01 — Route cache cleanup per trade** · High · Confirmed (merged into G04-02).
- **G15-02 ✔ — Fleet-min cargo profile always null (`?` on null)** · Medium · Confirmed · `gt_home_fleet_profile.xml:154-207`. The Cargo Fill Target floor for cache refresh never applies.
- **G15-03 ✔ — `UpdateShipList` is a non-instantiated root cue, so it fires once per savegame** · Medium · Confirmed · `gt_order_monitor_bridge.xml:661-693`. `$GT_ShipIDCodeMap` is never pruned, and stale handles are returned without `.exists`.
- **G15-04 — Order-monitor Lua↔MD contract mismatches (MK4/Explorer not known; `$payload.$OldOrder` read without `@`)** · Info (dormant). `ui/gt_order_monitor.lua` is not loaded by `ui.xml`, so nothing runs today. Fix it before re-enabling that file. See G17-06.
- **G15-05 ✔ — `WakeUpShipsStuckInOldCode` fires on every load** · Medium · Likely · `gt_trading_ai.xml:185-209`. Queued waiters jump to a non-interruptible 5–25 s wait, and grants are lost. **Fix:** delete it or gate it with a one-time flag.
- **G15-06 — `SystemInitV3` wipes the maintenance and registration queues on every load** · Low · Possible (see G10-01).
- **G15-07 — Lua "MissingPilot" goes straight to abort plus order cancellation** · Info (dormant; same unloaded Lua file).
- **G15-08 — Failed-sector-pair bookkeeping records the wrong pair; any sale wipes the whole sector's memory** · Low · Confirmed.
- **G15-09 — `UpdateShipStats` creates a partial registry row that pre-empts `Register_Ship`** · Low · Confirmed. Recovered ships never get `$Config` / `$Status`.
- **G15-10 — Training-started logbook uses the skill level as the title index** · Low · Confirmed · `gt_trade_logging.xml:912-915`.
- **G15-11 — Ware-exchange pickups tracked at zero cost overstate profit; rows leak** · Low · Likely · `gt_buy_tracking.xml`.
- **G15-12 — Lifetime profit and trade stats depend on the logbook toggle and mix units** · Low · Confirmed.
- **G15-13 — Ware filter** · Low. Dead per G13-12; the lists feed nothing.
- **G15-14 — Ship performance system: ungated English toasts per order-ready or commander change; dead monitors** · Low · Confirmed.
- **G15-15 — `$GT_LastTradeScan.{station}` / `$GT_LastReconstituteSignal.{commander}` never pruned** · Low · Confirmed.
- **G15-16 — Dead code** · Info. `ProcessDelayedTradeRequest`, market-intel handlers, the distribution / station-trader libraries, reporting cues, `HandlePriceChange` ✔ (signalled at `gt_market_intelligence.xml:58`, does not exist, and nothing produces `price_change_detected`).
- **OK:** nested MK4 purge/flag handlers (0.17.2); the AllowIllegal disposal contract across all four producers and the consumer; the 3df6ca9 fleet-replacement event fix; reporting reads training state from `GT_Pilots`; profit accounting units; migration idempotency.

### 3.16 Diagnose (G16)

- **G16-01 ✔ — O(n²) selection sort in one frame** · **High** · Confirmed · `gt_context_diagnose.xml:7976-8034`
  - About 4M inner iterations at the default cap of 2,000, and about 100M at 10,000.
  - The same file already uses `<sort_list>` (6768).
  - Other single-frame costs: uncached `GT_CanDock` per pair, an uncapped clearance loop, quadratic string building, and about 1,500 ungated `debug_text` calls.
- **G16-02 ✔ — Money-gate verdict uses the wrong units and applies to orders without a gate (MK1/MK2/Miner)** · Medium · Confirmed · `1227-1289, 9514-9528` (see §2.4).
- **G16-03 — Profit and ROI thresholds differ from the MK3 runtime** · Medium · Confirmed · `3911-3940, 7422-7438, 10018-10025`. They read the never-written `GT_AIParameters`, and the tips point at a non-existent ROI setting.
- **G16-04 — Overflow-threshold advice says "Lower"; the runtime needs "raise"** · Medium · Confirmed · `9751, 9765, 9811` (contradicts the Overview tip at 9756).
- **G16-05 — Lua alias gives the miner "Search Summary (Buyer Side)" the 6-column Sell/Buy/Total headers** · Low · Confirmed · `ui/gt_context_diagnose.lua:109`. An 8c48fc5 regression.
- **G16-06 — Technical VERDICT is FAIL for a healthy MK2 ship** · Low · Confirmed · `10169-10174`.
- **G16-07 — Dock rejections bucketed by side, not reason; `no_transport_units` reported as a size problem** · Low · Confirmed.
- **G16-08 — "Reservation Stats" always WARN (`$Created` never incremented); Ware column always "Unknown"** · Low · Confirmed.
- **G16-09 — `$ship.pilot?` then `.name` on a pilotless ship** · Low · Likely · `279-280`.
- **G16-10 — No `.exists` guard at the start of `GT_DiagnoseAction`** · Low · Possible.
- **OK:** diagnose is side-effect free; MD↔Lua keys and events match; Lua popup handles nil, empty and paging cases; several verdicts match the runtime.

### 3.17 UI Lua, manifests, library diffs (G17)

- **G17-01 ✔ — Cancel / ship-loss cleanup never clears `pendingSwapShipsByPair`** · Medium · Confirmed · `ui/gt_context_redistribute.lua:372-376` vs `1031`
  - The comparison uses ship handles (`left`/`right`) against an idcode.
  - Ships stay "busy", the plan never finishes, and the 5 s probe may still perform a cancelled swap.
  - **Fix:** compare `leftCode` / `rightCode`.
- **G17-02 ✔ — `dynamic_blacklists` keyed by `uint64_t` cdata (identity keys), so `RemoveFromShip` never removes; the map is also session-only** · Medium · Confirmed · `ui/gt_blacklist_manager.lua:350-362, 525, 537`. **Fix:** check `GetControllableBlacklistID` and reset, or key by `tostring(id)`.
- **G17-03 — Unanchored `ffi.new("const char*[?]")` stored only in a struct field** · Medium · Likely · `ui/gt_blacklist_manager.lua:238-258`. It can be garbage-collected while the engine writes into it, causing heap corruption or a crash. **Fix:** keep a local reference.
- **G17-04 — PHQ pilot-exchange planner is O(n³–n⁴) in one frame** · Medium · Likely · `ui/gt_context_redistribute.lua:1506-1606`.
- **G17-05 — Crew highlight requests a full MD pilot republish every 2 s even when the feature is disabled; dead `ffi.new("uint64_t", string)` path** · Low · Likely.
- **G17-06 — MD raises Lua events with no handler** · Low · Confirmed
  - `GT_StringUtils.StripShipName` has no handler, so `Strip_GT_Name_Formatting` is a no-op and GT tags can compound into `$OriginalShipName`.
  - The order-monitor, pilot-control and promotion events target Lua files not loaded by `ui.xml`.
  - The order-monitor bridge still rebuilds full payloads on 49 signal sites.
- **G17-07 — "Recreate blacklist" does not recreate; `BlacklistCreated` is sent twice** · Low · Confirmed.
- **G17-08 — Settlement-watch payload sends raw 64-bit ids** · Low · Possible (= G11-11).
- **G17-09 — Two files define the global `onUpdate`; about 15 helper globals leak from redistribute** · Low · Possible.
- **G17-10 — Deferred commander attach issues a new AssignCommander order every 4 frames (up to ~100 duplicates)** · Low · Possible · `ui/gt_context_promote.lua:741-790`.
- **G17-11 — `sound_library.xml` hard-codes `extensions\galaxy_trader\…`** · Low · Possible. Breaks when the folder name differs (Workshop / renamed installs).
- **G17-12 — Ungated `DebugError` spam (promote logs every fleet ship at about 10 phases)** · Low · Confirmed.
- **G17-13 — Vanilla hook wrappers drop return values/varargs and are not exception-safe; credits hook indexes `Helper.playerInfoConfig` unguarded** · Low · Possible.
- **G17-14 — Per-frame selection polling duplicates the event path** · Low · Confirmed.
- **G17-15 — `ffi.cdef` declarations are global and shadow vanilla; unused declarations should go** · Info.
- **G17-16 — `content.xml`: `<libraries>` is ignored, `save="0"`, version `01705` displays as 17.05** · Info.
- **OK:** `BlacklistInfo2` layout; `GetEntityCombinedSkill` / `EnableOrder` / `AdjustOrder` signatures; 64-bit seed parser (only >20-digit input wraps); thruster dismantle path; duplicate `MapMenu.update` wrapper removal.

---

## 4. Mechanical checks (repo-wide, scripted)

| Check | Result |
|---|---|
| XML well-formedness (all `*.xml`) | ✔ all parse |
| Lua syntax (`ui/*.lua`, luaparser) | ✔ all 21 parse |
| `run_script` params vs callee `<param>` declarations (AI + MD) | ✔ no undeclared params |
| `run_actions` / `include_actions` params vs `<library>` params | ✔ no undeclared params |
| Cue references (`signal_cue*`, `run_actions`, `cancel_cue`, `reset_cue`) | ✘ 4 unresolved (below) |
| Translation ids `{77000,N}` / `ReadText(77000,N)` referenced vs defined | ✔ 694 referenced, all present |
| Locale parity (16 locale files) | ✔ identical id sets (987 each) |
| Script `version` vs `<patch sinceversion>` | ✔ no patch above its script version |

Unresolved cue references:
- `md/gt_tradesearch_scheduler_mk4.xml:65, 347` → `md.GT_TradeSearch_Scheduler_MK4.InitSearchSemaphore` (the cue lives in `GT_TradeSearch_Scheduler`)
- `md/gt_market_intelligence.xml:58` → `HandlePriceChange` (missing; nothing produces the event)
- `md/gt_debug.xml:258` → `md.GT_TradingAI.FindTrades` (missing)

Recommended additions to the existing validator (`tools/`, not in the repo):
- the unresolved-cue check above
- `\$this\.`
- `?` on always-declared variables
- `do_all min=`
- integer division on `count` / `capacity` / `money`
- table literals with a `$var =` key where `{$var}` was probably meant
- dotted dynamic keys

---

## 5. Method, coverage and limitations

- **Method:**
  - The codebase was split into 17 subsystem groups (every code file assigned exactly once).
  - Each group was reviewed in depth, with emphasis on the 0.17.5 / 0.17.5-3 changes (`git log -p`), cross-file contracts, exit paths, savegame compatibility, state growth and single-frame cost.
  - Each reviewer had to re-read and cross-check every finding before reporting it.
  - The report author then re-verified the highest-impact findings directly against the source (marked ✔) and resolved conflicts between groups (G13-12 vs G15-13; G15-04/07 downgraded because their Lua side is not loaded).
- **X4 semantics assumed** (per Egosoft scripting documentation and vanilla usage):
  - `$x?` is an existence test.
  - `and` / `or` short-circuit.
  - Integer `/` truncates.
  - AI-script locals survive `<wait>` and save/load.
  - `this.$` is the entity blackboard.
  - `<do_all min max>` picks a random iteration count.
  - Dotted dynamic table keys are split into paths. This one comes from the mod's own documentation; G07-03 depends on it.
- **Not available:** vanilla 9.00 script sources and engine headers, so `<diff>` selectors and `ffi.cdef` signatures were checked for internal consistency and plausibility only. No in-game run was possible.
- **Partially covered:**
  - `gt_context_redistribute.lua` (~50%), `gt_context_promote.lua` (~75%)
  - `gt_ship_management.xml` (~30% in depth; the pilot-identity libraries at lines 1800-2930 were only cross-checked from callers)
  - `order.assist.xml` per-MK base-order tables (skimmed)
  - the miner routine's vanilla-derived gather logic (skimmed)
  - the diagnose MK1/MK2 pair internals (skimmed)
