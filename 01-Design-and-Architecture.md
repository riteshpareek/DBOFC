# Database-Side Data Obfuscation Framework — Design Document

Target: MariaDB, lower-environment copy of the Appian production schema (target schema —
e.g. `Appian`, `appiandev2`).

---

## A. Proposed Architecture

The framework installs entirely into its own dedicated **admin schema** (`obf_admin` — a
fixed name), separate from every application/target schema it obfuscates. Nothing in
`obf_admin` is ever installed into a target schema; the target is instead named as an
explicit `p_target_schema` parameter to every entry point. One `obf_admin` install can
therefore obfuscate any number of target schemas over time, each fully isolated from the
others — see "Multi-target isolation" in §C.

Everything runs **inside the lower environment**, after the production→lower copy has
finished for the target schema and **before** the environment is opened to general users.
Nothing runs against production.

The framework's moving parts (all in `obf_admin`, each state table scoped by a
`TargetSchema` column unless noted otherwise):

| Component | Purpose |
|---|---|
| `obf_ObfuscationConfig` | Declares which `(TargetSchema, TableName, ColumnName)` triples get obfuscated and how (`ObfuscationType`). Drives everything — no hard-coded column lists in the procedures. |
| `obf_UserReferenceRegistry` | Auto-discovered (+ manually confirmed) list of every column, per target schema, that stores a `dap_User.UserID` value — FK-based and convention-based (`CreatedBy`, `ModifiedBy`, etc.). Each row also carries an `OrphanAction` (`OBFUSCATE` default / `NULLIFY` / `IGNORE`) deciding what happens to a value in that column that matches no real `dap_User`. |
| `obf_UserObfuscationMapping` | The one-to-one original→obfuscated email mapping, per target schema (`PRIMARY KEY (TargetSchema, OriginalUserID)`). Deterministic, salted SHA-256 based. This table holds real PII and is the only place that does — see §C for lifecycle handling. |
| `obf_TableSeedOverride` | Per-target, DBA-registered `(TargetSchema, TableName) → ColumnName` mapping used as a last-resort deterministic seed for a table that has neither a registered user-reference column nor a formal `PRIMARY KEY` (real legacy/staging tables sometimes have an unmistakable `id`/`XxxID` column that was simply never declared as a key constraint) — avoids requiring a target-schema DDL change just to unblock obfuscation. |
| `Synthetic*` reference tables | Small seed tables (`obf_SyntheticFirstName`, `obf_SyntheticLastName`, `obf_SyntheticStreetAddress`) used to build "meaningful-looking" replacement names/addresses, selected deterministically per-user (not per-value). **Global** — shared across every target schema, not scoped by `TargetSchema`, since the seed pool has no reason to be duplicated per target. Extend freely; `SeedID` only has to be unique. |
| `obf_FkConstraintBackup` | Exact definitions of FK constraints while they are dropped mid-run, per target. Transient — the orchestrator discards already-restored rows for a target at the start of every run against it; a non-empty set of un-restored rows for a target means a run against it stopped between FK drop and restore. |
| `obf_ObfuscationRowCountSnapshot` | Per-run, per-target `BEFORE`/`AFTER` `COUNT(*)` for `dap_User` and every table named in that target's config/registry. Drives the row-count reconciliation in `obf_sp_validate_obfuscation`. |
| `obf_ObfuscationRun` | One header row per `obf_sp_obfuscate_database()` call: `RUNNING` → `COMPLETED` / `FAILED` / `SUPERSEDED`, the target schema, the salt used, timestamps, and the captured error on failure. Lets `obf_sp_obfuscation_status(target)` report whether that target is mid-migration — scoped so one target's run history never shadows another's. |
| Stored procedure suite | Orchestration (`obf_sp_obfuscate_database`) + focused sub-procedures, each independently callable/testable, every one taking `p_target_schema` as its first parameter. |

### Why an admin schema, and how cross-schema references work

MariaDB resolves an **unqualified** table/routine reference inside a stored routine's body
against the **caller's current default schema at CALL time** — not the schema the routine
was defined in. Splitting the framework out therefore needs two different qualification
strategies:

- **References to the framework's own `obf_admin` objects** — the admin schema's name is a
  fixed constant chosen once, so every reference (including each object's own `CREATE`
  statement) is simply hard-qualified with `` `obf_admin`. ``, uniformly, everywhere. No
  dynamic SQL is needed for this half.
- **References to target-schema tables** (`dap_User`, and every dynamically-named table
  from `obf_ObfuscationConfig` / `obf_UserReferenceRegistry`) — the schema name is only
  known at runtime (`p_target_schema`), and MariaDB only allows a variable to appear as
  part of a table identifier inside dynamic SQL (`PREPARE`/`EXECUTE`). A small helper,
  `obf_fn_quote_qualified(p_schema, p_table)`, builds the backtick-quoted `` `schema`.`table` ``
  text used everywhere a target-table reference is constructed dynamically (most of the
  framework already builds target-table SQL dynamically, since table/column names are
  already runtime data from the config tables — this only added the schema-name half of
  that qualification). A handful of statements that referenced `dap_User` *statically*
  (not build via `PREPARE`/`EXECUTE`) had to be converted to dynamic SQL for the same
  reason.

### Stored procedure suite

Every procedure lives in `obf_admin` and takes the target schema name as its **first**
parameter (omitted below for readability — read each as `obf_admin.obf_sp_x(p_target_schema, ...)`):

```
obf_sp_obfuscate_database(salt, batch, purge)    -- master orchestrator, single entry point
 │
 ├─ obf_sp_validate_config()                 -- checks every configured column exists (fatal if
 │                                           not); flags configured columns under a UNIQUE
 │                                           index (fatal for STATIC on a sole-column unique
 │                                           index with >1 row)
 │
 ├─ obf_sp_discover_user_references()        -- populates obf_UserReferenceRegistry from
 │                                           FK metadata + naming convention + config;
 │                                           flags registered columns whose datatype is
 │                                           incompatible with dap_User.UserID
 │
 ├─ obf_sp_validate_reference_column_lengths()  -- every registered reference column must be
 │                                           wide enough to hold the obfuscated user id (see
 │                                           "Obfuscated-id length ceiling" in §C); hard-stops
 │                                           BEFORE any destructive step if not
 │
 ├─ obf_sp_snapshot_row_counts('BEFORE')     -- records COUNT(*) per dap_User / config /
 │                                           registry table for the reconciliation check
 │
 ├─ obf_sp_create_user_mapping(salt)         -- builds obf_UserObfuscationMapping from
 │                                           dap_User.UserID, deterministic + collision-safe
 │
 ├─ obf_sp_report_orphan_user_references()   -- pre-flight (read-only): lists reference-column
 │                                           values that match no dap_User.UserID, for the
 │                                           DBA to eyeball before anything destructive
 │
 ├─ obf_sp_resolve_orphan_user_references(salt)  -- handles those strays per column's
 │                                           obf_UserReferenceRegistry.OrphanAction
 │                                           (OBFUSCATE | NULLIFY | IGNORE)
 │
 ├─ obf_sp_drop_user_fk_constraints()        -- captures & drops FKs that reference
 │                                           dap_User.UserID (see §C, "FK strategy")
 │
 ├─ obf_sp_obfuscate_user_references(batch)  -- dynamic UPDATE...JOIN for every table/column
 │                                           in obf_UserReferenceRegistry
 │
 ├─ obf_sp_obfuscate_user_table()            -- updates dap_User.UserID itself from the mapping
 │
 ├─ obf_sp_restore_user_fk_constraints()     -- re-creates the FKs captured above; MariaDB
 │                                           validates data integrity as a side-effect
 │
 ├─ obf_sp_obfuscate_configured_columns(batch, salt)  -- dynamic SQL loop over obf_ObfuscationConfig,
 │                                           dispatches to per-type logic (NAME/PHONE/
 │                                           EMAIL/ADDRESS/STATIC/HASH); seed resolution falls
 │                                           back to obf_TableSeedOverride as a last resort
 │
 ├─ obf_sp_validate_obfuscation()            -- orphaned user-reference check; row-count
 │                                           reconciliation vs the BEFORE snapshot;
 │                                           heuristic residual-PII spot checks; SIGNALs
 │                                           45000 on any failure (resumable by re-running)
 │
 └─ obf_sp_purge_sensitive_staging()         -- optional: strips OriginalUserID out of
                                             obf_UserObfuscationMapping once cleared for release

obf_sp_obfuscation_status()                  -- read-only, run separately: last run outcome
                                            FOR THIS TARGET, FK constraints currently dropped,
                                            whether it is mid-migration
obf_sp_obfuscation_prune(keep_runs)          -- optional housekeeping, run separately: keep the
                                            newest N runs of history FOR THIS TARGET, drop the rest
```

Each sub-procedure is idempotent-aware (checks `Enabled`/existing state before redoing work) so the master procedure can be safely re-run if it fails partway through (see §C, "Idempotency"). "Last run" / resume / supersede-stale-`RUNNING` logic throughout is scoped by `TargetSchema` — one target's genuinely-running job is never touched by a call against a different target.

### Why dynamic SQL, and how it's kept safe

Table/column names live only in `obf_ObfuscationConfig` and `obf_UserReferenceRegistry`, which are themselves populated only from `information_schema` metadata or explicit inserts by a DBA/deployment script — never from end-user input (and the target schema name itself comes only from the `p_target_schema` parameter the DBA supplies at call time). All dynamic SQL:

- Uses `PREPARE` / `EXECUTE` / `DEALLOCATE PREPARE`.
- Quotes every identifier with backticks via `obf_fn_quote_identifier()`, and every
  schema-qualified target-table reference via `obf_fn_quote_qualified(schema, table)`
  (which itself just delegates to `obf_fn_quote_identifier` for each half).
- Validates that every `(TableName, ColumnName)` actually exists in `information_schema.COLUMNS` before building a statement (belt-and-braces on top of the FK/config sourcing).
- Never concatenates *values* into SQL — obfuscated values are always passed as bound data via the mapping join, not string-built into the query text.

---

## B. Data Flow

Every state table written below lives in `obf_admin`, scoped to the `TargetSchema` named
in the call; every table read/written "in place" (`dap_User`, configured PII columns,
reference columns) lives in the target schema itself.

```
Production Copy (already done, out of scope)
        │
        ▼
Validate obf_ObfuscationConfig against live schema
   (columns exist; UNIQUE-constraint safety; STATIC-on-unique-index is fatal here)
        │
        ▼
Discover User References  ──►  obf_UserReferenceRegistry
   (FK metadata + naming convention: CreatedBy, ModifiedBy, CreatedUserID, ...;
    datatype-compatibility flagged)
        │
        ▼
Validate reference-column lengths
   (every registered reference column must be wide enough for the obfuscated user id —
    hard-stops here, before any destructive step, if not)
        │
        ▼
Snapshot row counts (BEFORE)  ──►  obf_ObfuscationRowCountSnapshot
        │
        ▼
Build User Mapping  ──►  obf_UserObfuscationMapping
   (deterministic SHA-256(salt || email) → synthetic email, collision-checked)
        │
        ▼
Report orphan references   (read-only diagnostic: reference-column values with no
   dap_User match — surfaced BEFORE any mutation for DBA review)
        │
        ▼
Resolve orphan references  (per obf_UserReferenceRegistry.OrphanAction:
   OBFUSCATE → synthesise a mapping row so it is replaced like any other;
   NULLIFY → set NULL;  IGNORE → leave, and exempt from post-run validation)
        │
        ▼
Drop FK constraints referencing dap_User.UserID   (captured for exact restore)
        │
        ▼
Update User References
   (every table/column in obf_UserReferenceRegistry, UPDATE ... JOIN obf_UserObfuscationMapping)
        │
        ▼
Update dap_User.UserID itself
        │
        ▼
Re-create FK constraints   (MariaDB validates referential integrity here — free check)
        │
        ▼
Obfuscate configured PII columns
   (FirstName/LastName/Phone/Address/other emails, per obf_ObfuscationConfig)
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

**Multi-target isolation.** One `obf_admin` install can obfuscate many target schemas, so
every admin-side state table that isn't a genuinely shared seed pool carries a
`TargetSchema` column and is keyed/queried by it: `obf_ObfuscationConfig` and
`obf_UserReferenceRegistry` are unique per `(TargetSchema, TableName, ColumnName)`;
`obf_UserObfuscationMapping`'s primary key is `(TargetSchema, OriginalUserID)` (so the same
real email maps independently, and typically to a *different* obfuscated value, per target
— each target normally uses its own salt); `obf_TableSeedOverride` is keyed by
`(TargetSchema, TableName)`. Crucially, every "what's the last/currently-running run"
query in `obf_sp_obfuscate_database` (superseding a stale `RUNNING` row, detecting a resume,
picking up the previous salt) and in `obf_sp_obfuscation_status()` filters by
`TargetSchema` — without that, a run against one target could supersede or misreport
another target's genuinely in-progress job. `obf_Synthetic*` name/address pools are the
one deliberate exception: they're global, shared by every target, since there's no reason
to duplicate the seed data per target and one shared pool is easier to extend.

**Obfuscated-id length ceiling.** `obf_sp_obfuscate_user_references` writes the *same*
obfuscated value into every registered reference column that it writes into
`dap_User.UserID` (no per-column truncation — truncating differently per column would let
two different users' emails collide on a narrow column). `obf_fn_generate_obfuscated_email`
therefore caps its output at **49 characters total** (a 33-character hash local-part + the
16-character `@example.invalid` domain), **regardless of how wide `dap_User.UserID` itself
is** — so any reference column 50 characters or wider is always safe, with no schema
change required. `obf_sp_validate_reference_column_lengths` (run right after discovery,
before any destructive step) computes the same ceiling and hard-stops if any registered
reference column is narrower than it, naming the offending `table.column` and its current
vs. required width — this is deliberately a pre-flight check rather than letting the
narrow column surface as a raw `Data too long for column` error mid-run, after FKs have
already been dropped.

**Tables with no formal PRIMARY KEY.** `obf_sp_obfuscate_configured_columns` needs a
stable per-row seed to generate deterministic synthetic values: it prefers a registered
user-reference column on the same table, else the table's own `PRIMARY KEY`. Some real
schemas have a table with an obvious unique row-id column (`id`, `RefereeID`, …) that was
simply never declared as an actual `PRIMARY KEY` constraint. Rather than require a
target-schema DDL change just to unblock obfuscation, a DBA can register that column
explicitly in `obf_TableSeedOverride` — checked only as the last resort, after both other
lookups come up empty. A table matching none of the three is `SKIP`ped (its configured
columns are logged as untouched, not silently left as-is without a trace).

**Foreign-key update ordering.** MariaDB/InnoDB enforces FK checks per-statement with no deferred-constraint mode, so a primary key that's referenced by other tables generally *cannot* be updated in place while children still point at the old value — unless the FK has `ON UPDATE CASCADE`. Rather than `SET FOREIGN_KEY_CHECKS=0` (which silently permits orphans and gives no feedback), the framework:
1. Reads exact FK definitions from `information_schema.KEY_COLUMN_USAGE` / `information_schema.REFERENTIAL_CONSTRAINTS` for every constraint referencing `dap_User.UserID`.
2. Drops them.
3. Performs all updates freely (order no longer matters).
4. Re-adds each constraint from the captured definition. MariaDB will **refuse to add a constraint if any row violates it** — so this step doubles as an integrity check with an explicit, actionable error instead of silent corruption.

This is safer than disabling checks because a broken mapping surfaces as a hard failure at restore time, not as silently orphaned data discovered later.

**Unique constraints.** `obf_UserObfuscationMapping.ObfuscatedUserID` has a `UNIQUE` key. Generation logic retries with an extra salt component on collision (astronomically unlikely with SHA-256, but handled, not assumed away — the first mapping insert is `INSERT IGNORE` so an attempt-0 collision falls through to the retry loop rather than aborting). Any other `UNIQUE` constraint on a configured PII column (e.g. a unique index on `Email`) is detected by `obf_sp_validate_config()` from `information_schema.STATISTICS` before that column is processed: every case is logged as a `WARN` (obfuscated values must stay unique or the run fails with a duplicate-key error), and the one guaranteed failure — `STATIC` (one literal for all rows) on a single-column unique index with more than one row — is a hard `SIGNAL 45000` before any mutation. Multi-column unique indexes stay warnings, since per-component-unique obfuscation can still satisfy them.

**Reference-column datatype.** `dap_User.UserID` is assumed string-typed (it holds the email). `obf_sp_discover_user_references()` flags any registered reference column whose datatype is not string-like (e.g. a numeric `CreatedBy` that is not actually a UserID copy) — a `WARN` plus a `TypeLooksCompatible` column in its diagnostic result set — so the DBA can `Enabled = FALSE` it before it is obfuscated into an email. (`obf_sp_validate_config()` extension to make this fatal is a noted follow-up.)

**Row-count reconciliation.** `obf_sp_obfuscate_database()` snapshots `COUNT(*)` for `dap_User` and every config/registry table into `obf_ObfuscationRowCountSnapshot` (phase `BEFORE`) right after discovery; `obf_sp_validate_obfuscation()` re-snapshots (`AFTER`) and `SIGNAL`s if any table's count changed — nothing in the framework should add or remove rows, so a delta means a trigger or a bug. A standalone `obf_sp_validate_obfuscation()` call with a `RunID` that has no `BEFORE` snapshot logs `SKIP` for this check rather than failing.

**Residual-PII spot checks.** `obf_sp_validate_obfuscation()` also runs a heuristic sweep: `dap_User.UserID` (and configured `EMAIL` columns) must end `@example.invalid`; configured `FIRST_NAME`/`LAST_NAME`/`ADDRESS` values must come from the `Synthetic*` pool; configured `PHONE` values must match the generator's `04########` shape. Any violation `SIGNAL`s. This is a backstop for "a step silently didn't run", not a guarantee — it cannot detect a residual value that already resembles the synthetic domain, and it makes no assertion about `STATIC`/`HASH` columns.

**NULLs.** Every obfuscation routine explicitly skips `NULL` source values (`WHERE source_column IS NOT NULL`) rather than obfuscating `NULL` into a placeholder string — a `NULL` email/phone/name stays `NULL`.

**Duplicate names across users.** Per the spec, "John Smith / John Brown / John Taylor" must not collapse into the same synthetic identity just because they share a first name. Synthetic name selection is therefore keyed off **the user's obfuscated identity**, not off the literal `FirstName`/`LastName` value — `CRC32(SHA2(CONCAT(salt, UserID_or_row_key), 256))` picks the synthetic name index. Same user always gets the same synthetic name across a re-run (determinism); different users with the same real first name get independently chosen synthetic names.

**Case sensitivity / collation.** The framework does not rely on the schema's default collation to match email values across case. `obf_UserObfuscationMapping.OriginalUserID` is stored `LOWER()`-cased (and `obf_fn_generate_obfuscated_email()` lowercases its hash input), so `John@x.com` and `john@x.com` always resolve to the same obfuscated value. Every join from a user-reference column back to the mapping is written `m.OriginalUserID = LOWER(t.<col>)` — the function sits only on the (already-scanned) reference-column side, so the mapping-table primary key stays usable for the lookup. `obf_sp_create_user_mapping()` first refuses (`SIGNAL 45000`) if `dap_User` holds rows that differ only by `UserID` letter case — impossible under a case-insensitive PK, but a `*_bin` / `*_cs` collation would allow it, and silently merging two real users is worse than a hard stop.

**Large tables / long-running transactions.** Config-driven column updates are batched (configurable batch size, default 50,000 rows) via a `LIMIT`-based loop keyed on primary key, rather than one massive single-statement `UPDATE`, to avoid long lock waits and huge rollback segments on multi-million-row Appian process/audit tables.

**Composite foreign keys.** FK discovery groups by `CONSTRAINT_NAME` (not just column) so multi-column FKs are captured and dropped/restored as a whole, never partially.

**Self-referencing tables.** A table like `dap_User` referencing itself (e.g. a `ManagerUserID` column pointing back to `dap_User.UserID`) is handled the same way as any other reference — discovered via FK metadata, updated via the mapping join, no special-casing needed once the "drop FK / update / restore FK" strategy is used.

**Audit columns.** `CreatedBy`/`ModifiedBy`-style columns are explicitly included in the naming-convention discovery pass — they're value copies, not FKs, so they wouldn't be caught by FK metadata alone.

**Orphan user-reference values.** A value in a naming-convention or manually-registered reference column need not correspond to a live `dap_User` row — departed users, `'SYSTEM'`/`'batch'` sentinels, legacy bad data. FK-discovered columns can't have these (the constraint forbids it), but audit columns routinely do. Such a value would get no mapping row, so a plain `UPDATE ... JOIN mapping` would silently leave the **original** in place. The framework therefore: (1) runs `obf_sp_report_orphan_user_references()` *before* any destructive step, emitting every offending `(table, column, value, row count)` as a diagnostic result set plus a `WARN` in `obf_ObfuscationRunLog`; and (2) runs `obf_sp_resolve_orphan_user_references()` which, per each column's `obf_UserReferenceRegistry.OrphanAction`, either **OBFUSCATE**s the stray (synthesise a mapping row → it is replaced like any other reference; default, so no original survives even if the DBA does nothing), **NULLIFY**s it, or **IGNORE**s it (left in place and exempted from the post-run check — only choose this after seeing the report and confirming the value is non-sensitive). Because strays are handled up front, `obf_sp_validate_obfuscation()` failing now means *this run* left something inconsistent, not that the source data was already imperfect; its error message says the run is incomplete and can be resumed by re-running `obf_sp_obfuscate_database()`.

Known gap: if a naming-convention column's real datatype isn't the `dap_User.UserID` domain (e.g. a numeric `CreatedBy`), *every* value looks like a stray and OBFUSCATE would rewrite it into a synthetic email. `obf_sp_validate_config()` should be extended to reject discovered reference columns that aren't type-compatible with `dap_User.UserID`.

**Unexpected user references.** Because discovery is metadata-driven and re-run every execution (not a one-off manual list), a newly added column that follows convention or has an FK to `dap_User` is picked up automatically. `obf_sp_discover_user_references()` also emits a diagnostic result set the DBA can eyeball before the destructive steps run.

**Data embedded in JSON/free-text columns.** Out of scope for pattern-matched free-text scanning (deliberately — regex-scrubbing free text is unreliable and easy to get wrong). These columns should be added explicitly to `obf_ObfuscationConfig` with an appropriate type (or a custom `STATIC` replacement) if known to contain PII; the design flags this as a manual-review item rather than pretending to solve it generically.

**Triggers / dependent routines.** Any trigger or stored routine that reads `dap_User.UserID` or PII columns during the `UPDATE` statements in this framework will fire normally against the new obfuscated values — the framework doesn't disable triggers. If a trigger has side effects that assume production-shaped data (e.g. sends an email), that should be disabled independently in the lower environment before running this framework; that's flagged as a pre-requisite, not handled here.

**Not atomic — resumable.** The run is deliberately **not** wrapped in one transaction: `obf_sp_drop_user_fk_constraints()` / `obf_sp_restore_user_fk_constraints()` issue DDL (implicit `COMMIT` in MariaDB), and the large-table UPDATEs commit in batches on purpose (see "Large tables / long-running transactions"). A failure part-way therefore leaves the schema **partly migrated**. Recovery is by **re-running `obf_sp_obfuscate_database()` with the same salt** — every step is idempotent (see below) and dropped FKs are recorded in `obf_FkConstraintBackup`, so a re-run picks up where it stopped and restores the FKs. `obf_sp_obfuscate_database()` writes an `obf_ObfuscationRun` header row (`RUNNING` → `COMPLETED` / `FAILED` / `SUPERSEDED`, with the captured SQLSTATE + message on failure), detects a resume at start (logging a `WARN` if FKs are currently dropped or the last run didn't complete), and its `EXIT HANDLER` records the real error rather than a generic "aborted". Before (re-)running, a DBA runs **`obf_sp_obfuscation_status()`** — it reports the last run's outcome, lists any FK constraints currently dropped, and gives a plain-English assessment (`HALF-MIGRATED … re-run with the SAME salt` / `Last run COMPLETED cleanly` / …). `obf_FkConstraintBackup` rows are transient — the orchestrator discards already-restored ones at the start of each run, so the table normally holds nothing. Run-history tables (`obf_ObfuscationRun`, `obf_ObfuscationRunLog`, `obf_ObfuscationRowCountSnapshot`) are kept for audit; **`obf_sp_obfuscation_prune(keep_runs)`** trims them to the most recent N runs when desired.

**Idempotency of individual steps.** `obf_sp_create_user_mapping()` only inserts rows for `OriginalUserID`s not already mapped (`INSERT IGNORE ... NOT EXISTS`, plus a guard that an existing `ObfuscatedUserID` is never re-treated as an original). Column-level obfuscation procedures are guarded by checking whether the value already matches the obfuscated domain/pattern, so a second run doesn't double-obfuscate. FK drop/restore procedures check `information_schema` before acting so a re-run after a mid-restore failure won't error trying to drop a constraint that's already gone.

**Existing obfuscated data.** Same idempotency guards above mean re-running the framework on an already-obfuscated lower environment (e.g. a repeat refresh cycle) is safe and just re-validates rather than re-scrambling already-synthetic values.

**Sensitive mapping table lifecycle.** `obf_UserObfuscationMapping.OriginalUserID` is real PII and must not sit indefinitely accessible in the lower environment. Being in `obf_admin` rather than the target schema already narrows its exposure to whoever has access to the admin schema (now shared across every target obfuscated from this install, so its own access needs to be tighter than any individual target's — see below), and two supported modes, chosen by the DBA at run time via a parameter to `obf_sp_obfuscate_database()`, further reduce it:
- **Retain** (for future delta syncs) — keep the mapping table, but restrict `SELECT` access on `obf_UserObfuscationMapping` (and ideally the whole `obf_admin` schema) more tightly than the general lower-environment schemas.
- **Purge** — after validation passes, `obf_sp_purge_sensitive_staging()` overwrites `OriginalUserID` with a non-reversible placeholder (it can't be set `NULL` — it's part of the primary key) while preserving `ObfuscatedUserID`, so future re-runs would generate fresh mappings rather than reuse history.

---
