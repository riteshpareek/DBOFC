# Database-Side Data Obfuscation Framework — Design Document

Target: MariaDB, lower-environment copy of the Appian production schema (`Appian`).

---

## A. Proposed Architecture

Everything runs **inside the lower-environment database**, after the production→lower copy has finished and **before** the environment is opened to general users. Nothing runs against production.

The framework has five moving parts:

| Component | Purpose |
|---|---|
| `ObfuscationConfig` | Declares which `(TableName, ColumnName)` pairs get obfuscated and how (`ObfuscationType`). Drives everything — no hard-coded column lists in the procedures. |
| `UserReferenceRegistry` | Auto-discovered (+ manually confirmed) list of every column that stores a `dap_User.UserID` value — FK-based and convention-based (`CreatedBy`, `ModifiedBy`, etc.). Each row also carries an `OrphanAction` (`OBFUSCATE` default / `NULLIFY` / `IGNORE`) deciding what happens to a value in that column that matches no real `dap_User`. |
| `UserObfuscationMapping` | The one-to-one original→obfuscated email mapping. Deterministic, salted SHA-256 based. This table holds real PII and is the only place that does — see §C for lifecycle handling. |
| `Synthetic*` reference tables | Small seed tables (`SyntheticFirstName`, `SyntheticLastName`, `SyntheticStreet`, `SyntheticSuburb`) used to build "meaningful-looking" replacement names/addresses, selected deterministically per-user (not per-value). |
| `ObfuscationRowCountSnapshot` | Per-run `BEFORE`/`AFTER` `COUNT(*)` for `dap_User` and every table named in the config/registry. Drives the row-count reconciliation in `sp_validate_obfuscation`. |
| `ObfuscationRun` | One header row per `sp_obfuscate_database()` call: `RUNNING` → `COMPLETED` / `FAILED` / `SUPERSEDED`, the salt used, timestamps, and the captured error on failure. Lets `sp_obfuscation_status()` report whether a schema is mid-migration. |
| Stored procedure suite | Orchestration (`sp_obfuscate_database`) + focused sub-procedures, each independently callable/testable. |

### Stored procedure suite

```
sp_obfuscate_database()                  -- master orchestrator, single entry point
 │
 ├─ sp_validate_config()                 -- checks every configured column exists (fatal if
 │                                           not); flags configured columns under a UNIQUE
 │                                           index (fatal for STATIC on a sole-column unique
 │                                           index with >1 row)
 │
 ├─ sp_discover_user_references()        -- populates UserReferenceRegistry from
 │                                           FK metadata + naming convention + config;
 │                                           flags registered columns whose datatype is
 │                                           incompatible with dap_User.UserID
 │
 ├─ sp_snapshot_row_counts('BEFORE')     -- records COUNT(*) per dap_User / config /
 │                                           registry table for the reconciliation check
 │
 ├─ sp_create_user_mapping()             -- builds UserObfuscationMapping from
 │                                           dap_User.UserID, deterministic + collision-safe
 │
 ├─ sp_report_orphan_user_references()   -- pre-flight (read-only): lists reference-column
 │                                           values that match no dap_User.UserID, for the
 │                                           DBA to eyeball before anything destructive
 │
 ├─ sp_resolve_orphan_user_references()  -- handles those strays per column's
 │                                           UserReferenceRegistry.OrphanAction
 │                                           (OBFUSCATE | NULLIFY | IGNORE)
 │
 ├─ sp_drop_user_fk_constraints()        -- captures & drops FKs that reference
 │                                           dap_User.UserID (see §C, "FK strategy")
 │
 ├─ sp_obfuscate_user_references()       -- dynamic UPDATE...JOIN for every table/column
 │                                           in UserReferenceRegistry
 │
 ├─ sp_obfuscate_user_table()            -- updates dap_User.UserID itself from the mapping
 │
 ├─ sp_restore_user_fk_constraints()     -- re-creates the FKs captured above; MariaDB
 │                                           validates data integrity as a side-effect
 │
 ├─ sp_obfuscate_configured_columns()    -- dynamic SQL loop over ObfuscationConfig,
 │                                           dispatches to per-type logic (NAME/PHONE/
 │                                           EMAIL/ADDRESS/STATIC/HASH)
 │
 ├─ sp_validate_obfuscation()            -- orphaned user-reference check; row-count
 │                                           reconciliation vs the BEFORE snapshot;
 │                                           heuristic residual-PII spot checks; SIGNALs
 │                                           45000 on any failure (resumable by re-running)
 │
 └─ sp_purge_sensitive_staging()         -- optional: strips OriginalUserID out of
                                             UserObfuscationMapping once cleared for release

sp_obfuscation_status()                  -- read-only, run separately: last run outcome,
                                            FK constraints currently dropped, whether a
                                            schema is mid-migration
sp_obfuscation_prune(keep_runs)          -- optional housekeeping, run separately: keep the
                                            newest N runs of history, drop the rest
```

Each sub-procedure is idempotent-aware (checks `Enabled`/existing state before redoing work) so the master procedure can be safely re-run if it fails partway through (see §C, "Idempotency").

### Why dynamic SQL, and how it's kept safe

Table/column names live only in `ObfuscationConfig` and `UserReferenceRegistry`, which are themselves populated only from `information_schema` metadata or explicit inserts by a DBA/deployment script — never from end-user input. All dynamic SQL:

- Uses `PREPARE` / `EXECUTE` / `DEALLOCATE PREPARE`.
- Quotes every identifier with backticks via a small `fn_quote_identifier()` helper.
- Validates that every `(TableName, ColumnName)` actually exists in `information_schema.COLUMNS` before building a statement (belt-and-braces on top of the FK/config sourcing).
- Never concatenates *values* into SQL — obfuscated values are always passed as bound data via the mapping join, not string-built into the query text.

---

## B. Data Flow

```
Production Copy (already done, out of scope)
        │
        ▼
Validate ObfuscationConfig against live schema
   (columns exist; UNIQUE-constraint safety; STATIC-on-unique-index is fatal here)
        │
        ▼
Discover User References  ──►  UserReferenceRegistry
   (FK metadata + naming convention: CreatedBy, ModifiedBy, CreatedUserID, ...;
    datatype-compatibility flagged)
        │
        ▼
Snapshot row counts (BEFORE)  ──►  ObfuscationRowCountSnapshot
        │
        ▼
Build User Mapping  ──►  UserObfuscationMapping
   (deterministic SHA-256(salt || email) → synthetic email, collision-checked)
        │
        ▼
Report orphan references   (read-only diagnostic: reference-column values with no
   dap_User match — surfaced BEFORE any mutation for DBA review)
        │
        ▼
Resolve orphan references  (per UserReferenceRegistry.OrphanAction:
   OBFUSCATE → synthesise a mapping row so it is replaced like any other;
   NULLIFY → set NULL;  IGNORE → leave, and exempt from post-run validation)
        │
        ▼
Drop FK constraints referencing dap_User.UserID   (captured for exact restore)
        │
        ▼
Update User References
   (every table/column in UserReferenceRegistry, UPDATE ... JOIN UserObfuscationMapping)
        │
        ▼
Update dap_User.UserID itself
        │
        ▼
Re-create FK constraints   (MariaDB validates referential integrity here — free check)
        │
        ▼
Obfuscate configured PII columns
   (FirstName/LastName/Phone/Address/other emails, per ObfuscationConfig)
        │
        ▼
Snapshot row counts (AFTER) + Validate
   (orphaned user-reference check; BEFORE-vs-AFTER row-count reconciliation;
    heuristic residual-PII spot checks; SIGNAL 45000 on any failure)
        │
        ▼
Cleanup
   (optionally strip OriginalUserID from mapping table once validated)
        │
        ▼
Lower Environment Ready
```

---

## C. Risks and Edge Cases

**Foreign-key update ordering.** MariaDB/InnoDB enforces FK checks per-statement with no deferred-constraint mode, so a primary key that's referenced by other tables generally *cannot* be updated in place while children still point at the old value — unless the FK has `ON UPDATE CASCADE`. Rather than `SET FOREIGN_KEY_CHECKS=0` (which silently permits orphans and gives no feedback), the framework:
1. Reads exact FK definitions from `information_schema.KEY_COLUMN_USAGE` / `information_schema.REFERENTIAL_CONSTRAINTS` for every constraint referencing `dap_User.UserID`.
2. Drops them.
3. Performs all updates freely (order no longer matters).
4. Re-adds each constraint from the captured definition. MariaDB will **refuse to add a constraint if any row violates it** — so this step doubles as an integrity check with an explicit, actionable error instead of silent corruption.

This is safer than disabling checks because a broken mapping surfaces as a hard failure at restore time, not as silently orphaned data discovered later.

**Unique constraints.** `UserObfuscationMapping.ObfuscatedUserID` has a `UNIQUE` key. Generation logic retries with an extra salt component on collision (astronomically unlikely with SHA-256, but handled, not assumed away — the first mapping insert is `INSERT IGNORE` so an attempt-0 collision falls through to the retry loop rather than aborting). Any other `UNIQUE` constraint on a configured PII column (e.g. a unique index on `Email`) is detected by `sp_validate_config()` from `information_schema.STATISTICS` before that column is processed: every case is logged as a `WARN` (obfuscated values must stay unique or the run fails with a duplicate-key error), and the one guaranteed failure — `STATIC` (one literal for all rows) on a single-column unique index with more than one row — is a hard `SIGNAL 45000` before any mutation. Multi-column unique indexes stay warnings, since per-component-unique obfuscation can still satisfy them.

**Reference-column datatype.** `dap_User.UserID` is assumed string-typed (it holds the email). `sp_discover_user_references()` flags any registered reference column whose datatype is not string-like (e.g. a numeric `CreatedBy` that is not actually a UserID copy) — a `WARN` plus a `TypeLooksCompatible` column in its diagnostic result set — so the DBA can `Enabled = FALSE` it before it is obfuscated into an email. (`sp_validate_config()` extension to make this fatal is a noted follow-up.)

**Row-count reconciliation.** `sp_obfuscate_database()` snapshots `COUNT(*)` for `dap_User` and every config/registry table into `ObfuscationRowCountSnapshot` (phase `BEFORE`) right after discovery; `sp_validate_obfuscation()` re-snapshots (`AFTER`) and `SIGNAL`s if any table's count changed — nothing in the framework should add or remove rows, so a delta means a trigger or a bug. A standalone `sp_validate_obfuscation()` call with a `RunID` that has no `BEFORE` snapshot logs `SKIP` for this check rather than failing.

**Residual-PII spot checks.** `sp_validate_obfuscation()` also runs a heuristic sweep: `dap_User.UserID` (and configured `EMAIL` columns) must end `@example.invalid`; configured `FIRST_NAME`/`LAST_NAME`/`ADDRESS` values must come from the `Synthetic*` pool; configured `PHONE` values must match the generator's `04########` shape. Any violation `SIGNAL`s. This is a backstop for "a step silently didn't run", not a guarantee — it cannot detect a residual value that already resembles the synthetic domain, and it makes no assertion about `STATIC`/`HASH` columns.

**NULLs.** Every obfuscation routine explicitly skips `NULL` source values (`WHERE source_column IS NOT NULL`) rather than obfuscating `NULL` into a placeholder string — a `NULL` email/phone/name stays `NULL`.

**Duplicate names across users.** Per the spec, "John Smith / John Brown / John Taylor" must not collapse into the same synthetic identity just because they share a first name. Synthetic name selection is therefore keyed off **the user's obfuscated identity**, not off the literal `FirstName`/`LastName` value — `CRC32(SHA2(CONCAT(salt, UserID_or_row_key), 256))` picks the synthetic name index. Same user always gets the same synthetic name across a re-run (determinism); different users with the same real first name get independently chosen synthetic names.

**Case sensitivity / collation.** Email comparisons/joins are done against `LOWER()`-normalized values internally where the mapping is built, but the *stored* obfuscated value preserves standard lower-case email convention. The framework does not assume a case-insensitive collation on production copy — it normalizes explicitly rather than relying on the schema's default collation.

**Large tables / long-running transactions.** Config-driven column updates are batched (configurable batch size, default 50,000 rows) via a `LIMIT`-based loop keyed on primary key, rather than one massive single-statement `UPDATE`, to avoid long lock waits and huge rollback segments on multi-million-row Appian process/audit tables.

**Composite foreign keys.** FK discovery groups by `CONSTRAINT_NAME` (not just column) so multi-column FKs are captured and dropped/restored as a whole, never partially.

**Self-referencing tables.** A table like `dap_User` referencing itself (e.g. a `ManagerUserID` column pointing back to `dap_User.UserID`) is handled the same way as any other reference — discovered via FK metadata, updated via the mapping join, no special-casing needed once the "drop FK / update / restore FK" strategy is used.

**Audit columns.** `CreatedBy`/`ModifiedBy`-style columns are explicitly included in the naming-convention discovery pass — they're value copies, not FKs, so they wouldn't be caught by FK metadata alone.

**Orphan user-reference values.** A value in a naming-convention or manually-registered reference column need not correspond to a live `dap_User` row — departed users, `'SYSTEM'`/`'batch'` sentinels, legacy bad data. FK-discovered columns can't have these (the constraint forbids it), but audit columns routinely do. Such a value would get no mapping row, so a plain `UPDATE ... JOIN mapping` would silently leave the **original** in place. The framework therefore: (1) runs `sp_report_orphan_user_references()` *before* any destructive step, emitting every offending `(table, column, value, row count)` as a diagnostic result set plus a `WARN` in `ObfuscationRunLog`; and (2) runs `sp_resolve_orphan_user_references()` which, per each column's `UserReferenceRegistry.OrphanAction`, either **OBFUSCATE**s the stray (synthesise a mapping row → it is replaced like any other reference; default, so no original survives even if the DBA does nothing), **NULLIFY**s it, or **IGNORE**s it (left in place and exempted from the post-run check — only choose this after seeing the report and confirming the value is non-sensitive). Because strays are handled up front, `sp_validate_obfuscation()` failing now means *this run* left something inconsistent, not that the source data was already imperfect; its error message says the run is incomplete and can be resumed by re-running `sp_obfuscate_database()`.

Known gap: if a naming-convention column's real datatype isn't the `dap_User.UserID` domain (e.g. a numeric `CreatedBy`), *every* value looks like a stray and OBFUSCATE would rewrite it into a synthetic email. `sp_validate_config()` should be extended to reject discovered reference columns that aren't type-compatible with `dap_User.UserID`.

**Unexpected user references.** Because discovery is metadata-driven and re-run every execution (not a one-off manual list), a newly added column that follows convention or has an FK to `dap_User` is picked up automatically. `sp_discover_user_references()` also emits a diagnostic result set the DBA can eyeball before the destructive steps run.

**Data embedded in JSON/free-text columns.** Out of scope for pattern-matched free-text scanning (deliberately — regex-scrubbing free text is unreliable and easy to get wrong). These columns should be added explicitly to `ObfuscationConfig` with an appropriate type (or a custom `STATIC` replacement) if known to contain PII; the design flags this as a manual-review item rather than pretending to solve it generically.

**Triggers / dependent routines.** Any trigger or stored routine that reads `dap_User.UserID` or PII columns during the `UPDATE` statements in this framework will fire normally against the new obfuscated values — the framework doesn't disable triggers. If a trigger has side effects that assume production-shaped data (e.g. sends an email), that should be disabled independently in the lower environment before running this framework; that's flagged as a pre-requisite, not handled here.

**Not atomic — resumable.** The run is deliberately **not** wrapped in one transaction: `sp_drop_user_fk_constraints()` / `sp_restore_user_fk_constraints()` issue DDL (implicit `COMMIT` in MariaDB), and the large-table UPDATEs commit in batches on purpose (see "Large tables / long-running transactions"). A failure part-way therefore leaves the schema **partly migrated**. Recovery is by **re-running `sp_obfuscate_database()` with the same salt** — every step is idempotent (see below) and dropped FKs are recorded in `FkConstraintBackup`, so a re-run picks up where it stopped and restores the FKs. `sp_obfuscate_database()` writes an `ObfuscationRun` header row (`RUNNING` → `COMPLETED` / `FAILED` / `SUPERSEDED`, with the captured SQLSTATE + message on failure), detects a resume at start (logging a `WARN` if FKs are currently dropped or the last run didn't complete), and its `EXIT HANDLER` records the real error rather than a generic "aborted". Before (re-)running, a DBA runs **`sp_obfuscation_status()`** — it reports the last run's outcome, lists any FK constraints currently dropped, and gives a plain-English assessment (`HALF-MIGRATED … re-run with the SAME salt` / `Last run COMPLETED cleanly` / …). `FkConstraintBackup` rows are transient — the orchestrator discards already-restored ones at the start of each run, so the table normally holds nothing. Run-history tables (`ObfuscationRun`, `ObfuscationRunLog`, `ObfuscationRowCountSnapshot`) are kept for audit; **`sp_obfuscation_prune(keep_runs)`** trims them to the most recent N runs when desired.

**Idempotency of individual steps.** `sp_create_user_mapping()` only inserts rows for `OriginalUserID`s not already mapped (`INSERT IGNORE ... NOT EXISTS`, plus a guard that an existing `ObfuscatedUserID` is never re-treated as an original). Column-level obfuscation procedures are guarded by checking whether the value already matches the obfuscated domain/pattern, so a second run doesn't double-obfuscate. FK drop/restore procedures check `information_schema` before acting so a re-run after a mid-restore failure won't error trying to drop a constraint that's already gone.

**Existing obfuscated data.** Same idempotency guards above mean re-running the framework on an already-obfuscated lower environment (e.g. a repeat refresh cycle) is safe and just re-validates rather than re-scrambling already-synthetic values.

**Sensitive mapping table lifecycle.** `UserObfuscationMapping.OriginalUserID` is real PII and must not sit indefinitely in the lower environment. Two supported modes, chosen by the DBA at run time via a parameter to `sp_obfuscate_database()`:
- **Retain** (for future delta syncs) — keep the mapping table, but move it to a schema/database with tighter access controls than the general lower-environment schema.
- **Purge** — after validation passes, `sp_purge_sensitive_staging()` truncates `OriginalUserID` values (replacing with `NULL` or dropping the column's data) while preserving `ObfuscatedUserID`, so future re-runs would generate fresh mappings rather than reuse history.

---
