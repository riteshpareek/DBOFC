# Implementation Review — `02-Implementation.sql` vs `01-Design-and-Architecture.md`

Reviewed against a live **MariaDB 10.11.19** instance (Docker), running the fixture and
every concrete case in `03-Test-Plan.sql`.

> **Status:** all findings (F1–F10) are **fixed** in `02-Implementation.sql` and
> re-verified — see each finding for the change and its test.

## Test results at a glance

| Test | Subject | Result |
|---|---|---|
| 1 | Deterministic email generation | **PASS** |
| 2 | Full run + FK drop/restore + no orphans | **PASS** |
| 3 | Same original email → same obfuscated value across tables | **PASS** |
| 4 | No original names / phones remain | **PASS** |
| 5 | Users sharing a real name get independent synthetic identities | **PASS** |
| 6 | Idempotency — second run is a no-op | **PASS** (names/phone/address/email/static) |
| 7 | Collision handling (retry with escalating attempt) | ~~FAIL~~ → **PASS** after F2 fix — collides on attempt 0, retry loop lands the attempt-1 value |
| 8 | Bad config rejected before any mutation | **PASS** |
| 9 | Validation catches a deliberately broken state | **PASS** (raises, but see F3) |
| — | `HASH` obfuscation type | ~~FAIL~~ → **PASS** after F1 fix — terminates at `batch_size 2` on 3 rows, idempotent across re-runs |

---

## Findings

### F1 — `HASH` obfuscation type never terminates  *(critical)* — **FIXED**

> **Fix applied.** `WHEN 'HASH'` now hashes `SHA2(CONCAT(p_salt,'|',<row seed>))` — the
> same stable per-row seed the other types use (owning user-reference column, else PK) —
> instead of `SHA2(<live column value>)`, and adds the `AND col <> <target>` guard the
> other types have. `sp_obfuscate_configured_columns` gained an `IN p_salt VARCHAR(64)`
> parameter, passed through by `sp_obfuscate_database`. Verified: full run with
> `p_batch_size = 2` over 3 rows returns (no hang); second orchestrator run leaves the
> column byte-identical (idempotent). Semantics change — equal original values now hash
> alike only when they share a seed; documented inline.


`sp_obfuscate_configured_columns`, `WHEN 'HASH'` branch (lines ~751–759).

The batch driver is `WHILE v_rows_affected > 0`. The `HASH` UPDATE is:

```sql
UPDATE `t` SET `col` = LEFT(SHA2(`col`,256), n)
WHERE `col` IS NOT NULL
LIMIT p_batch_size;
```

There is **no idempotency guard** (`AND col <> <target>`) and the target is a function
of the column's *current* value, so every pass re-hashes every non-NULL row, `ROW_COUNT()`
stays `> 0`, and the `WHILE` loop spins forever. Confirmed empirically: a `HASH`-typed
config row on a 3-row table ran for ~8 minutes until the thread was killed.

The inline comment acknowledges "re-hashing an already-hashed value is … not a no-op" but
doesn't account for the enclosing `WHILE`, which turns "not a no-op" into "never exits".

**Fix options:** hash from a stable seed instead of the live value
(`SHA2(CONCAT(p_salt, <pk>), 256)`), or add a state table / marker so already-hashed rows
are excluded, or process `HASH` as a single un-batched statement with no `WHILE`.
Whichever — it must become genuinely idempotent, since `sp_obfuscate_database` is
advertised as re-runnable.

### F2 — Collision retry path is dead code; first collision aborts the run  *(high)* — **FIXED**

> **Fix applied.** The first insert in `sp_create_user_mapping` is now `INSERT IGNORE`, so
> an attempt-0 `UK_ObfuscatedUserID` collision (against a pre-existing row or another row
> in the same batch) is skipped and left for the escalating-attempt retry loop below.
> Verified with Test 7: `newuser@test.com` collides on attempt 0 and is mapped to its
> attempt-1 value; no error; all rows mapped.


`sp_create_user_mapping` (lines ~364–404). Design §C promises: *"Generation logic retries
with an extra salt component on collision … handled, not assumed away."* Test 7 exercises
exactly this and fails:

```
ERROR 1062 (23000): Duplicate entry '…@example.invalid' for key 'UK_ObfuscatedUserID'
```

The **first** insert (line ~364) is a plain `INSERT … SELECT`. Only the *retry-loop* insert
(line ~387) is `INSERT IGNORE`. So a collision on attempt 0 throws 1062 and the procedure
exits before the retry loop ever runs — the escalating-`p_attempt` logic below it is
unreachable in the collision case it exists for.

**Fix:** make the first insert `INSERT IGNORE` too (one word), so attempt-0 collisions fall
through to the existing retry loop. The loop logic itself looks correct.

### F3 — `sp_validate_obfuscation` runs *after* all mutation and cannot tell "we broke it" from "it was already like this"  *(high)* — **FIXED**

> **Fix applied.** Two new procedures run after the mapping is built and **before** FK
> drop:
> - `sp_report_orphan_user_references` — read-only pre-flight. Emits a diagnostic result
>   set of every `(table, column, value, row count)` in a registered reference column that
>   matches no `dap_User.UserID`, and logs a `WARN` (or `OK` if none actionable). The DBA
>   sees the stray data before anything destructive happens.
> - `sp_resolve_orphan_user_references` — acts per a new
>   `UserReferenceRegistry.OrphanAction` column (`OBFUSCATE` default \| `NULLIFY` \|
>   `IGNORE`). `OBFUSCATE` synthesises a mapping row for each stray so it is rewritten by
>   `sp_obfuscate_user_references` like any other reference — **no original value survives**;
>   `NULLIFY` sets them NULL; `IGNORE` leaves them and marks the column exempt.
>
> `sp_validate_obfuscation` now skips `OrphanAction='IGNORE'` columns and its failure
> message states the run is incomplete and resumable rather than a bare "validation failed".
> Because strays are resolved pre-mutation, a hit in the post-run check now genuinely means
> *this run* broke something.
>
> **Verified:**
> - stray `ghost-user@test.com` in `CreatedBy`, default `OBFUSCATE` → reported pre-flight,
>   replaced with an obfuscated value, run **succeeds**, `0` originals remain;
> - same with `NULLIFY` → value becomes `NULL`, run succeeds;
> - `SYSTEM` sentinel with `IGNORE` → kept intact, run succeeds, validation logs `SKIP` +
>   `Validation passed.`;
> - 3× re-run with a stray present → mapping row count and every obfuscated value stable
>   (idempotent);
> - Test 9 (inject a bad value *after* the run, call `sp_validate_obfuscation` directly) →
>   still raises `SQLSTATE 45000`.
>
> Follow-up still open: FK-discovered columns can't have strays, but a NAMING_CONVENTION
> column whose real datatype isn't the `dap_User.UserID` domain (e.g. a numeric `CreatedBy`)
> would have *every* value treated as a stray and obfuscated into an email — see F4-adjacent
> note. Recommend `sp_validate_config` also check discovered reference columns are
> type-compatible with `dap_User.UserID`.

**Original finding (for context).** Data flow (design §B) and `sp_obfuscate_database` call it last. If any registered
user-reference column holds a value that isn't a known `ObfuscatedUserID`, it raises
`SQLSTATE 45000` — **after** FKs have been dropped and restored and every PII column
rewritten (all committed; `ALTER TABLE` forces implicit commits).

Reproduced (G4 probe): seed one pre-existing junk value into `dap_Actor.CreatedBy`
(a `NAMING_CONVENTION`-discovered column — a value copy with no FK guaranteeing validity),
then run. Every step logs `OK`, the DB is fully obfuscated, FKs are back, and then the run
"fails" with `run aborted`. Meanwhile the junk value (`ghost-user@test.com`, PII-shaped) is
**still there** un-obfuscated, because it had no mapping row, and nothing in the framework
will ever fix it.

So this single check produces, at once:
- a **false failure** — the refresh actually succeeded; a DBA reading "aborted" will not know that;
- a **real, silent leak** — an original-format value in a discovered column that was never mapped and never obfuscated.

Naming-convention columns routinely contain values that don't resolve to a current
`dap_User` (departed users, system accounts, historical bad data). Recommend:
- pre-flight the orphan check (before mutation) as a **warning**, listing offending
  `(table, column, value)` for the DBA to triage;
- for values with no mapping, either map-and-obfuscate them too (synthetic placeholder) or
  null them per policy — don't leave originals in place;
- keep a post-run check, but have it distinguish "created by this run" from "pre-existing".

### F4 — `sp_validate_config` doesn't check UNIQUE constraints on PII columns  *(medium — design claim not met)* — **FIXED**

> **Fix applied.** `sp_validate_config` now cursors every enabled configured column that
> sits in a UNIQUE index (incl. PK), via `information_schema.STATISTICS` (`NON_UNIQUE = 0`):
> - logs a `WARN` for each ("obfuscated values must remain unique or the run fails") plus a
>   diagnostic result set of all such columns;
> - **hard-stops** (`SIGNAL 45000`, before any mutation) the guaranteed failure —
>   `STATIC` on a single-column unique index when the table has >1 row.
>
> Also added (the F3 follow-up): `sp_discover_user_references` now flags registered
> reference columns whose datatype isn't string-like when `dap_User.UserID` is
> (`WARN` + a `TypeLooksCompatible` column in its diagnostic result set), so a numeric
> `CreatedBy` is surfaced instead of being obfuscated into an email.
>
> **Verified:** `UNIQUE (PhoneNumber)` + `PHONE` → WARN, run proceeds;
> `UNIQUE (ExternalRef)` + `STATIC` on a 3-row table → `sp_validate_config` raises 45000,
> data untouched; a `BIGINT CreatedBy` column → discovery WARN + `TypeLooksCompatible = 0`.
> Not made fatal for the non-STATIC cases: a unique index like `(TenantId, Email)` can still
> be satisfied by per-tenant-unique obfuscation, so those stay warnings.

**Original finding.** Design §C: *"Any other `UNIQUE` constraint on a PII column (e.g. a unique index on `Email`)
is checked in `sp_validate_config()` before that column is processed, and flagged rather
than silently attempted."*

Implementation only LEFT JOINs `information_schema.COLUMNS` to check the column **exists**.
G1 probe: added `UNIQUE (PhoneNumber)`, ran `sp_validate_config` → `OK, All configured
columns exist.` No flag.

This matters because `PHONE`/`EMAIL`/`STATIC` replacement can collapse many rows onto one
value: `STATIC` sets every row identical (instant unique violation if the column is
UNIQUE); `fn_synthetic_phone` has an 8-digit space and is seeded per-row so collisions are
possible at scale. Today that surfaces as a raw `ERROR 1062` mid-mutation, not the promised
pre-flight flag.

### F5 — "row-count reconciliation" and "residual-PII spot checks" are named but not implemented  *(medium — design claim not met)* — **FIXED**

> **Fix applied.**
> - **New table `ObfuscationRowCountSnapshot`** + **`sp_snapshot_row_counts(run_id, phase)`**.
>   `sp_obfuscate_database` takes a `BEFORE` snapshot (of `dap_User` ∪ every config /
>   registry table) right after discovery; `sp_validate_obfuscation` takes the `AFTER`
>   snapshot and fails (`SIGNAL 45000`, per-table `before=/after=` log lines) on any
>   difference. Called standalone with a RunID that has no `BEFORE` row → logs `SKIP`,
>   doesn't fail (so Test 9 style direct calls still work).
> - **Residual-PII spot checks** in `sp_validate_obfuscation` (§10c): `dap_User.UserID` not
>   ending `@example.invalid`; configured `EMAIL` columns likewise; `FIRST_NAME` /
>   `LAST_NAME` / `ADDRESS` values not drawn from the `Synthetic*` pool (address allows the
>   truncation prefix); `PHONE` values not matching `^04[0-9]{1,8}$`. Any hit →
>   `SIGNAL 45000`. Heuristic — documented inline that it can't catch a residual value that
>   already looks synthetic, and says nothing about `STATIC`/`HASH`.
> - §10d overall status now reports all three counters (`orphaned refs / row-count
>   mismatches / residual-PII hits`).
>
> **Verified:** clean run logs `BEFORE`+`AFTER` snapshots, "Row-count reconciliation passed",
> "Residual-PII spot checks passed"; deleting a row before a direct
> `sp_validate_obfuscation` call → caught (`dap_Actor before=2 after=1`), 45000; setting a
> name to `Zoltan` (not in the pool) → caught, 45000; standalone call with no snapshot →
> reconciliation `SKIP`, orphan check still fires.

**Original finding.** `sp_validate_obfuscation` header comment lists *"row-count reconciliation"* and
*"residual-PII spot checks"* (also in design §A/§B).

- **Row count:** the code only does `sp_log_step(..., CONCAT('dap_User row count: ', (SELECT COUNT(*) …)))`
  — it logs the current count. Nothing is captured before the run, nothing is compared, so
  a lost/gained row would not be detected. Capture `COUNT(*)` per relevant table at
  `START` and assert equality here.
- **Residual PII:** no code at all. Even a cheap heuristic pass would add value — e.g. flag
  `dap_User.UserID` values not ending `@example.invalid`, phone columns still matching
  `^04\d{8}$` outside the synthetic generator's shape, or configured name columns whose
  value isn't in the `Synthetic*` seed set.

### F6 — Partial-failure leaves the schema mutated and committed, despite "bail out … rather than leaving the schema half-migrated"  *(medium)* — **FIXED**

> **Fix applied.** Atomicity is impossible here (DDL implicit-commits; batched UPDATEs
> commit on purpose), so the fix makes the half-migrated state *visible and resumable*
> instead of pretending it's atomic:
> - **New `ObfuscationRun` header table** — one row per `sp_obfuscate_database()` call:
>   `RUNNING` → `COMPLETED` / `FAILED` / `SUPERSEDED`, with the salt, timestamps, and (on
>   failure) `ErrorSqlState` + `ErrorText`. The orchestrator's `EXIT HANDLER` now
>   `GET DIAGNOSTICS`-captures the real error, records it, logs a precise line
>   (`Run FAILED (23000): …`) and re-raises — this also retires the misleading
>   *"Unhandled exception — run aborted"* wording (**F10**).
> - **New `sp_obfuscation_status()`** — read-only. Shows the last runs, any FK constraints
>   currently dropped (`FkConstraintBackup.RestoredDate IS NULL`), whether the mapping still
>   holds PII, and a plain-English `Assessment` (`HALF-MIGRATED: … re-run with the SAME
>   salt` / `Last run COMPLETED cleanly` / …).
> - **Resume detection** at run start: a prior `RUNNING` row (killed connection) is marked
>   `SUPERSEDED`; if FKs are dropped or the last run `FAILED`/`SUPERSEDED`, a `WARN` is
>   logged (*"Resuming after an interrupted/failed run … the salt MUST match"*).
> - The `sp_obfuscate_database` header comment now states plainly that the run is **not
>   atomic, by design**, and that recovery = re-run with the same salt.
>
> **Verified:** clean run → `ObfuscationRun` `COMPLETED`, status proc says "Safe to open".
> Forced FK-restore failure → run `FAILED` with SQLSTATE `23000` + the real FK message,
> `FK_Actor_User` absent from the schema, status proc says `HALF-MIGRATED`. Fix the data +
> re-run same salt → resume `WARN`, run `COMPLETED`, dangling FK back to 0, FK restored.
> Bad-config run → `ObfuscationRun` `FAILED` recorded. Virgin DB → "No obfuscation run
> recorded yet."
>
> Not addressed (still F8): `FkConstraintBackup` / `ObfuscationRun` rows accumulate across
> runs.

**Original finding.** `sp_obfuscate_database` comment: *"Bail out fast and loudly on any unhandled error rather
than leaving the schema half-migrated."* The `EXIT HANDLER` does log + `RESIGNAL`, but there
is **no transaction wrapper**, and `sp_drop_user_fk_constraints` / `restore` issue DDL,
which implicitly commits in MariaDB. A failure between "drop FKs" and "restore FKs" (e.g.
the F1 `HASH` hang gets killed, or F3 raises) leaves FKs dropped and data partly rewritten,
all committed.

It *is* recoverable — `FkConstraintBackup` (rows with `RestoredDate IS NULL`) plus the
idempotency guards mean a re-run finishes the job — but that recovery path isn't stated
anywhere. At minimum document it ("on failure, fix the cause and re-run
`sp_obfuscate_database`; it resumes"). The claim of atomicity should be softened to
"resumable".

### F7 — `MOD`-based synthetic index assumes a gap-free `SeedID` starting at 0  *(low)* — **FIXED**

> **Fix applied.** All three `fn_synthetic_*` pickers now select positionally —
> `... ORDER BY SeedID LIMIT v_idx, 1` (with `v_idx = CRC32(...) MOD v_count`) — instead of
> `WHERE SeedID = v_idx`, so any unique `SeedID` values work. The seed-table comment no
> longer requires a contiguous `0..N-1` range.
> **Verified:** reseeded `SyntheticFirstName` with `{10, 25, 500, 9999}` and
> `SyntheticLastName` with `{3, 77, 1201}` → all rows get a valid pool value, zero NULLs,
> deterministic across re-runs.

**Original finding.** `fn_synthetic_first_name` / `_last_name` / `_street_address`:
`v_idx = CRC32(...) MOD v_count; SELECT … WHERE SeedID = v_idx`. If seed rows are ever
edited to be non-contiguous or 1-based, `v_idx` can hit a missing `SeedID`, the `SELECT …
INTO` matches nothing, the variable stays `NULL`, and a `NOT NULL` target column update
fails. The design does note "SeedID must be a contiguous 0..N-1 range", so this is
documented brittleness rather than a bug — but `ROW_NUMBER()`/`LIMIT v_idx,1` ordering
would remove the footgun.

### F8 — `FkConstraintBackup` grows one row per constraint per run  *(low / housekeeping)* — **FIXED**

> **Fix applied.**
> - `FkConstraintBackup` gains a `RunID` column (stamped by `sp_drop_user_fk_constraints`).
> - The orchestrator `DELETE`s already-restored backup rows at the start of every run
>   (a restored row is redundant with `information_schema`). The table now holds at most
>   the last run's restored row, plus any un-restored rows that are the resume signal —
>   verified `COUNT(*) = 1` after two runs (was 2, would have been N).
> - **New `sp_obfuscation_prune(p_keep_runs)`** (DBA-invoked) trims
>   `ObfuscationRun` / `ObfuscationRunLog` / `ObfuscationRowCountSnapshot` /
>   spent `FkConstraintBackup` to the newest `p_keep_runs` runs, pruning by RunID set (not
>   timestamp — several runs can share a second) and also clearing headerless log rows from
>   standalone sub-procedure calls. `p_keep_runs < 1` → `SIGNAL`. Verified: 3 runs + 1
>   standalone call → `prune(1)` leaves exactly one run's worth everywhere; `prune(50)` on
>   1 run is a no-op.

**Original finding.** Each run inserts fresh backup rows … Over repeated environment refreshes the table accumulates.

### F9 — `EMAIL` type can emit a doubly-suffixed address  *(low / cosmetic)* — **FIXED**

> **Fix applied.** `WHEN 'EMAIL'` now writes
> `LEFT(CONCAT('user_', LEFT(SHA2(CONCAT(salt,'|',CAST(seed AS CHAR)),256),16), '@example.invalid'), col_len)`
> — a hash of the seed, never the raw seed — with a `<> target` idempotency guard (not
> `NOT LIKE`, so a too-narrow column can't loop). Result is always
> `user_<16-hex>@example.invalid`. **Verified:** an `AltEmail VARCHAR(254)` column seeded
> off the (obfuscated-email) PK → all rows `user_…@example.invalid`, zero
> `@example.invalid@example.invalid`, idempotent across re-runs.

### F10 — orchestrator's final error line says "Unhandled exception" for deliberate `SIGNAL`s  *(nit)* — **FIXED (with F6)**

> **Fix applied.** The `EXIT HANDLER` now `GET DIAGNOSTICS`-captures the actual
> `RETURNED_SQLSTATE` + `MESSAGE_TEXT` and logs `Run FAILED (<sqlstate>): <real message> —
> schema may be partly migrated; fix the cause and re-run with the SAME salt to resume.`,
> and records the same on the `ObfuscationRun` row. A validation `SIGNAL` now shows its own
> text (e.g. `Run FAILED (45000): Post-run validation failed — …`) instead of the generic
> "Unhandled exception".

**Original finding.** Tests 8 and 9 both end with `ObfuscationRunLog` … `sp_obfuscate_database | ERROR |
Unhandled exception — run aborted.` even though the stop was a designed `SIGNAL` from a
validation step.

---

## What holds up well

- **FK drop / capture / restore** (`information_schema.REFERENTIAL_CONSTRAINTS` +
  `KEY_COLUMN_USAGE`, grouped by `CONSTRAINT_NAME`) works, survives re-runs, and the
  restore genuinely re-validates referential integrity (Test 2, `fk_restored = 1`,
  `orphaned_actor_rows = 0`).
- **Determinism & cross-table consistency** — `fn_generate_obfuscated_email` is stable, and
  because PII columns are seeded off the (already-obfuscated) owning `UserID`, the same
  person resolves to the same synthetic name/phone/address in every table (Tests 1, 3, 5).
- **"Shared first name" independence** (Test 5) — three users all originally `Smith` come
  out as `Morris` / `Price` / `Mitchell`; seeding off identity, not off the literal value,
  does what the spec asks.
- **Idempotency for the non-HASH types** (Test 6) — `state_before == state_after`, mapping
  row count unchanged. The `<> <target>` guards and the
  `NOT IN (SELECT ObfuscatedUserID …)` re-hash guard both do their job.
- **Config pre-flight** (Test 8) — a bad `(table, column)` is rejected by
  `sp_validate_config` with `SQLSTATE 45000` and **zero** data mutation
  (`state_after == state_before`, no later `OK` log rows).
- **Identifier quoting / dynamic SQL discipline** — `fn_quote_identifier`, `PREPARE` /
  `EXECUTE` / `DEALLOCATE`, sourcing names only from `information_schema` and the config
  tables: all as described in the design.

---

## Portability note (not a bug on the stated target)

`sp_obfuscate_user_references` uses `UPDATE … JOIN … LIMIT` for batching. MariaDB 10.3+
accepts `LIMIT` on a multi-table `UPDATE` (verified honoured on 10.11 — a 5-row/`LIMIT 2`
update changed exactly 2). **MySQL rejects this syntax.** The framework is MariaDB-only as
written; fine given the target, worth a one-line comment so nobody ports it to MySQL and
gets a parse error.

---

## Status — all fixed

All ten findings are fixed in `02-Implementation.sql` and re-verified against MariaDB
10.11:

- **F1** HASH infinite loop → seed+salt keyed, idempotent, terminates
- **F2** collision retry path → first insert is `INSERT IGNORE`
- **F3** post-run-only validation + silent leak → pre-flight `sp_report_orphan_user_references`
  + `sp_resolve_orphan_user_references` per `OrphanAction`
- **F4** no UNIQUE / type checks in `sp_validate_config` → both added (STATIC-on-unique-index
  is fatal; type mismatch is a WARN in discovery)
- **F5** fake reconciliation, no residual check → `ObfuscationRowCountSnapshot` +
  `sp_snapshot_row_counts`, real BEFORE/AFTER assert, heuristic residual-PII sweep
- **F6** silent half-migrated state → `ObfuscationRun` header + `sp_obfuscation_status()`,
  resume detection, "not atomic, resumable" framing
- **F7** brittle `MOD` seed indexing → positional `ORDER BY SeedID LIMIT v_idx,1`
- **F8** unbounded `FkConstraintBackup` → `RunID` column, spent rows discarded each run,
  `sp_obfuscation_prune(p_keep_runs)`
- **F9** `EMAIL` double `@example.invalid` → hash-of-seed, `user_<hex>@example.invalid`
- **F10** "Unhandled exception" for deliberate SIGNALs → `GET DIAGNOSTICS` captures the real
  SQLSTATE + message

Remaining non-blocking note: the `UPDATE … JOIN … LIMIT` batching is MariaDB-only (see
Portability note) — a comment now flags it in the source.
