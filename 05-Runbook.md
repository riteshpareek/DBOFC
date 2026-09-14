# Runbook — Running the Obfuscation in a Lower Environment

This is the operational procedure for `02-Implementation.sql`. Nothing here touches
production.

**Architecture:** the framework installs entirely into its own dedicated **admin schema**
(`obf_admin` — a fixed name; every `obf_*` object lives only there, never in your
application schema). You install it **once per MariaDB server**, then obfuscate any number
of target schemas by naming them as the first argument to every call — each target's
config, mapping, and run history is fully isolated from every other target using the same
admin install. Nothing under `obf_admin` needs re-installing per target.

### Connecting to your sandbox

Your sandbox MariaDB is the Docker Desktop container on **host port 3308**. Fill in your
own user / password; the examples below use `<user>`, and `<target>` for whichever
application schema you're obfuscating:

```bash
# host client (works regardless of container name/engine)
mariadb -h 127.0.0.1 -P 3308 -u <user> -p < <file>       # run a script (no DB needed — see step 2)
mariadb -h 127.0.0.1 -P 3308 -u <user> -p                # interactive shell

# or exec into the container (container is named "mariadb" on the desktop-linux engine)
docker exec -i  mariadb mariadb -u <user> -p<password> < <file>
docker exec -it mariadb mariadb -u <user> -p<password>
```

Run `.sql` files with the CLI (`< file` or `SOURCE file;`) or your GUI client's
**"Execute SQL Script"** mode — **not** "execute one statement" (the file is a
multi-statement script with `DELIMITER $$` blocks; see the `1064 ... near 'CREATE TABLE'`
symptom).

Below, `mariadb < file` is shorthand for whichever of the two forms you use.

---

## 0. Before you start — safety gates

- [ ] Confirm you are connected to the **lower / sandbox** database, not production
      (`SELECT @@hostname;`).
- [ ] The production→lower data copy is **complete** for the target schema you're obfuscating.
- [ ] Take a **snapshot / backup** of the target schema (so a bad run is recoverable
      beyond the framework's own resume path).
- [ ] **Disable any triggers or scheduled jobs** in the target schema that send email / call
      external systems / assume production-shaped data — or call a stored procedure that
      doesn't exist in this lower-environment copy. The framework does **not** disable
      triggers; they will fire on the obfuscating `UPDATE`s exactly as any normal `UPDATE`
      would.
- [ ] Make sure no application traffic is hitting the target schema during the run.

---

## 1. Adapt the framework to your schema (only if names differ)

The script assumes:

| Assumed | Meaning |
|---|---|
| `dap_User` | the user table, in the target schema |
| `dap_User.UserID` | primary key **and** the email address |
| `dap_User` columns like `FirstName`, `LastName`, `PhoneNumber`, `Address` | PII to replace |
| columns named `CreatedBy`, `CreatedUser`, `CreatedUserID`, `ModifiedBy`, `ModifiedUserID` | value-copies of a `UserID` |

If your schema differs:

- Global search/replace `dap_User` / `UserID` in `02-Implementation.sql` for your real
  user table / key column.
- Edit the naming-convention list in `obf_sp_discover_user_references` (section 4) to match
  your audit-column names.
- Everything else (which PII columns, which types, and which target schema) is **data**, set
  in `obf_ObfuscationConfig` in step 3 — no code change.

If `dap_User.UserID` is **not** the email (e.g. it's a numeric id and the email is in
`dap_User.Email`), that is a larger change — tell the author; the mapping generator and the
reference-rewrite logic are built around "the key is the email".

The admin schema name itself (`obf_admin`) is also a fixed constant baked in throughout the
file — rename it only via a careful global find/replace, since it's hardcoded as a
schema-qualifier on every `obf_*` reference.

---

## 2. Load the framework (once per server)

```bash
mariadb -h 127.0.0.1 -P 3308 -u <user> -p < 02-Implementation.sql
```

No target database needs to be selected first — the script creates `obf_admin` itself and
every object is schema-qualified in its own `CREATE` statement. Creates: config/registry/
mapping/run tables (each scoped by `TargetSchema`), the `Synthetic*` seed tables (global,
shared across every target, with a small starter set), 8 functions, and 18 `obf_sp_*`
procedures. Re-runnable — loading it again is a no-op on existing table data (`CREATE OR
REPLACE` refreshes routine definitions; table `DDL` uses `IF NOT EXISTS`).

**Optional but recommended:** extend the synthetic seed tables so replacement names/
addresses have enough variety for your row counts (a 20-name pool over 100k users means
~5k users share each name). These are global — extend once, shared by every target:

```sql
INSERT INTO obf_admin.obf_SyntheticFirstName (SeedID, NameValue) VALUES (20,'Ava'),(21,'Leo'), ... ;
INSERT INTO obf_admin.obf_SyntheticLastName  (SeedID, NameValue) VALUES (20,'Reyes'), ... ;
INSERT INTO obf_admin.obf_SyntheticStreetAddress (SeedID, AddressValue) VALUES (10,'7 Cedar Way'), ... ;
-- SeedID only has to be unique; gaps / non-zero start are fine.
```

---

## 3. Declare what to obfuscate — `obf_ObfuscationConfig`

One row per PII column **per target schema**. `ObfuscationType` is one of
`FIRST_NAME | LAST_NAME | PHONE | ADDRESS | EMAIL | STATIC | HASH`.

```sql
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('appiandev2', 'dap_User',  'FirstName',   'FIRST_NAME', NULL),
  ('appiandev2', 'dap_User',  'LastName',    'LAST_NAME',  NULL),
  ('appiandev2', 'dap_User',  'PhoneNumber', 'PHONE',      NULL),
  ('appiandev2', 'dap_User',  'Address',     'ADDRESS',    NULL),
  ('appiandev2', 'dap_User',  'SecondaryEmail','EMAIL',    NULL),
  ('appiandev2', 'dap_User',  'PasswordHash','STATIC',     '!obfuscated!'),
  ('appiandev2', 'dap_User',  'ApiToken',    'HASH',       NULL),
  ('appiandev2', 'dap_Actor', 'FirstName',   'FIRST_NAME', NULL),
  ('appiandev2', 'dap_Actor', 'LastName',    'LAST_NAME',  NULL);
```

Notes:
- `dap_User.UserID` (the primary email) is handled automatically — **do not** add it here.
- `STATIC` writes one literal to every row; don't use it on a column that has a
  single-column `UNIQUE` index (step 4 will hard-stop you).
- `HASH` is keyed off the row's stable seed + salt (deterministic, one-way).
- `Enabled = FALSE` on a row skips it without deleting it.
- A different target schema (`TargetSchema = 'other_db'`) is a **completely separate** set
  of config rows — nothing here is shared across targets except the `Synthetic*` pools.

Free-text / JSON columns are **not** scanned. Add them explicitly here (usually `STATIC`)
if you know they hold PII.

**Tables with no PRIMARY KEY:** a configured column can only be obfuscated deterministically
if the framework can find a stable per-row seed — a registered user-reference column, else
the table's own `PRIMARY KEY`. Some real schemas have a table with an obvious unique row-id
column (`id`, `RefereeID`, …) that was never declared as an actual `PRIMARY KEY` constraint.
Rather than requiring a schema change, register it manually:
```sql
INSERT INTO obf_admin.obf_TableSeedOverride (TargetSchema, TableName, ColumnName) VALUES ('appiandev2', 'SomeTable', 'id');
```
Without either a PK or an override row, the run logs a `SKIP` for that table's configured
columns and leaves them untouched — check `obf_admin.obf_ObfuscationRunLog` for `SKIP` rows
naming a table if PII you configured doesn't appear to have changed after a run.

---

## 4. Pre-flight — read-only, no data changes

Run these individually and read the result sets before the real run. Every call takes the
target schema name as its **first** argument.

**4a. Discover user references + check column types:**

```sql
CALL obf_admin.obf_sp_discover_user_references('appiandev2', UUID());
```

Look at the diagnostic result set:
- Every `FOREIGN_KEY` / `NAMING_CONVENTION` column that points at a user.
- `TypeLooksCompatible = 0` → a `WARN`; that column is probably **not** a UserID copy
  (e.g. a numeric `CreatedBy`). Set `Enabled = FALSE` for it:
  ```sql
  UPDATE obf_admin.obf_UserReferenceRegistry SET Enabled = FALSE
   WHERE TargetSchema = 'appiandev2' AND TableName = '...' AND ColumnName = '...';
  ```

**4b. Validate the config against the live schema:**

```sql
CALL obf_admin.obf_sp_validate_config('appiandev2', UUID());
```

- Missing column → **hard error**, fix the `obf_ObfuscationConfig` row.
- `WARN` about a `UNIQUE` index on a configured column → make sure the replacement value
  space is big enough (extend the seed tables, or switch `STATIC`→`HASH`).
- `STATIC` on a single-column unique index with >1 row → **hard error**; change the type.

**4c. Check reference-column widths:**

```sql
CALL obf_admin.obf_sp_validate_reference_column_lengths('appiandev2', UUID());
```

Every column in `obf_UserReferenceRegistry` gets overwritten with the **same** obfuscated
email that's written to `dap_User.UserID`. `obf_fn_generate_obfuscated_email` caps that value
at **49 characters, no matter how wide `dap_User.UserID` itself is** (33-char local part +
16-char `@example.invalid` domain), so any reference column **50 characters or wider** is
always safe with **no schema change**. Only a column narrower than 50 chars → **hard error**
(`Data too long for column '<col>'` is exactly this, if you hit it without running this check
first). Fix by widening the column to 50+, or by disabling that reference column (only if you
don't actually need it obfuscated — this leaves its original value untouched):
```sql
UPDATE obf_admin.obf_UserReferenceRegistry SET Enabled = FALSE
 WHERE TargetSchema = 'appiandev2' AND TableName = '...' AND ColumnName = '...';
```

---

## 5. Decide orphan handling (values that match no real user)

Naming-convention columns often hold values with no matching `dap_User` row — departed
users, `'SYSTEM'` / `'batch'` sentinels, legacy bad data. Each
`obf_UserReferenceRegistry` row has an `OrphanAction`:

| `OrphanAction` | effect |
|---|---|
| `OBFUSCATE` *(default)* | synthesise a mapping row → replaced like any other reference; no original survives |
| `NULLIFY` | set those values to `NULL` |
| `IGNORE` | leave them, and exempt the column from the post-run check — only after you've confirmed the values are non-sensitive |

The real run prints an **orphan report** (from `obf_sp_report_orphan_user_references`) listing
every `(table, column, value, row count)` before it mutates anything. If you want to see it
first without committing to a run, you can call the pre-flight pieces manually, or just do
a rehearsal (step 6) and read the report, then set `OrphanAction` as needed:

```sql
UPDATE obf_admin.obf_UserReferenceRegistry SET OrphanAction = 'IGNORE'
 WHERE TargetSchema = 'appiandev2' AND TableName = 'dap_Actor' AND ColumnName = 'CreatedBy';
```

---

## 6. Rehearsal (strongly recommended for a first run)

The `test/run-all.sh` harness is a rehearsal tool: it **drops and recreates** both the admin
schema and a target database, loads the tiny sample fixture, then asserts all 19 test-plan
cases (60+ checks — including one that spins up a *second* target schema to prove
multi-target isolation). Point it at throwaway schemas only:

```bash
DBOBF_CTX=desktop-linux DBOBF_CONTAINER=mariadb \
  DBOBF_USER=<user> DBOBF_PW=<password> DBOBF_DB=dbobf_rehearsal \
  bash test/run-all.sh
```

For a real schema copy, don't use the harness — restore a copy, then run
`CALL obf_admin.obf_sp_obfuscate_database(...)` (step 7) against it and walk the checks in
steps 8–9.

---

## 7. Run it

```sql
CALL obf_admin.obf_sp_obfuscate_database(
    'appiandev2',                               -- p_target_schema: the application schema to obfuscate
    'CHANGE-ME-secret-salt-for-this-refresh',   -- p_salt: secret, rotate per refresh cycle
    50000,                                      -- p_batch_size for large-table UPDATEs
    FALSE                                       -- p_purge_after: strip original emails now?
);
```

- **`p_target_schema`** — the application schema being obfuscated. Everything else this run
  touches (config, mapping, run history) is scoped to this value; a different target schema
  is entirely independent, even from the same `obf_admin` install.
- **`p_salt`** — a secret string. Same input + same salt → same obfuscated output. Keep it
  somewhere safe: **a resume run (step 11) must use the exact same salt.** Rotate it
  between independent refresh cycles (per target).
- **`p_batch_size`** — rows per `UPDATE` on large tables; 50 000 is a sane default.
- **`p_purge_after`** — `TRUE` overwrites the original emails in `obf_UserObfuscationMapping`
  after validation passes (see step 9). Leave `FALSE` on the first run so you can inspect,
  then purge separately.

The call returns the `RunID` on success and prints diagnostic result sets along the way
(discovered references, orphan report, unique-index report).

---

## 8. Check the result

```sql
CALL obf_admin.obf_sp_obfuscation_status('appiandev2');
```

Expect: `Assessment = 'Last run COMPLETED cleanly. Safe to open the environment.'` and
**0** FK constraints currently dropped.

```sql
SELECT StepName, StepStatus, Message
FROM obf_admin.obf_ObfuscationRunLog
WHERE TargetSchema = 'appiandev2' AND RunID = '<the RunID>'
ORDER BY LogID;
```

- All `OK`, ending with `obf_sp_obfuscate_database | OK | Run completed successfully.`
- `WARN` rows are informational (e.g. orphan report, unique-index notes) — read them.
- Any `ERROR` → go to step 11.

Referential integrity is re-checked for free when the FKs are restored; a broken mapping
would have failed the run there.

---

## 9. Spot-check for residual PII

The run already does a heuristic residual sweep and a BEFORE/AFTER row-count
reconciliation. Add your own eyeball checks against the **target** schema, e.g.:

```sql
-- every user email is now a synthetic one
SELECT COUNT(*) FROM dap_User WHERE UserID NOT LIKE '%@example.invalid';   -- expect 0

-- no obviously-real names survived
SELECT UserID, FirstName, LastName, PhoneNumber, Address FROM dap_User LIMIT 50;
```

And against the **admin** schema, to confirm reference columns all resolve to a known
obfuscated user:

```sql
SELECT 'dap_Actor.CreatedBy' col, COUNT(*) bad
FROM appiandev2.dap_Actor a
LEFT JOIN obf_admin.obf_UserObfuscationMapping m
  ON m.TargetSchema = 'appiandev2' AND m.ObfuscatedUserID = a.CreatedBy
WHERE a.CreatedBy IS NOT NULL AND m.ObfuscatedUserID IS NULL;                -- expect 0
```

Check any free-text / JSON columns you flagged manually.

---

## 10. Lock down the mapping table, then open the environment

`obf_UserObfuscationMapping.OriginalUserID` still holds real email addresses. Choose one:

- **Purge** — no further delta sync planned for this cycle:
  ```sql
  CALL obf_admin.obf_sp_purge_sensitive_staging('appiandev2', UUID());
  -- or pass p_purge_after = TRUE to obf_sp_obfuscate_database next time
  ```
  This overwrites `OriginalUserID` with a non-reversible placeholder, keeping
  `ObfuscatedUserID`.

- **Retain** — you need it for future delta syncs: **restrict access to the `obf_admin`
  schema** (tighter grants than the general lower-env schemas — it now holds every target's
  mapping data), and restrict `SELECT` on `obf_UserObfuscationMapping` specifically.

Then:

- [ ] Re-enable the triggers / jobs you disabled in step 0.
- [ ] Open the environment to users.

---

## 11. If the run fails partway (resume)

The run is **not atomic** by design (the FK drop/restore steps issue DDL, which commits;
large `UPDATE`s commit in batches). A failure leaves the target schema **partly migrated but
recoverable**.

```sql
CALL obf_admin.obf_sp_obfuscation_status('appiandev2');
```

- `Assessment` starting `HALF-MIGRATED` → some FK constraints are currently dropped.
- `LastRunStatus = FAILED` with `ErrorText` / `ErrorSqlState` → the actual cause.

**Fix the cause** the error points at (e.g. a data problem an FK won't accept, a bad
config row, a trigger calling a stored procedure that doesn't exist in this lower-env
copy — check `information_schema.TRIGGERS`/`ROUTINES` and either fix or temporarily drop
the trigger for the run, or — a sample first-run failure — `Data too long for column
'<col>'`, meaning `<col>` is a registered reference column narrower than the 50-character
floor per step 4c; widen it to 50+ or `Enabled = FALSE` it, then resume), then **re-run
`obf_sp_obfuscate_database` with the exact same salt**:

```sql
CALL obf_admin.obf_sp_obfuscate_database('appiandev2', 'CHANGE-ME-secret-salt-for-this-refresh', 50000, FALSE);
```

Every step is idempotent — the resume finishes the remaining work and restores the FKs.
It logs a `WARN` ("Resuming after an interrupted/failed run …") so you can see it happened.

---

## 12. Repeat refreshes & housekeeping

- Re-running on an already-obfuscated environment (next month's refresh) is safe — the
  idempotency guards mean it re-validates rather than re-scrambling.
- Run-history tables (`obf_ObfuscationRun`, `obf_ObfuscationRunLog`, `obf_ObfuscationRowCountSnapshot`)
  are kept for audit, per target. Trim them when you want:
  ```sql
  CALL obf_admin.obf_sp_obfuscation_prune('appiandev2', 20);   -- keep the newest 20 runs for this target
  ```
- `obf_FkConstraintBackup` is transient — the orchestrator clears spent rows for this target
  at the start of every run against it; a non-empty set of un-restored rows for a target
  between runs means a run against that target stopped mid-way (step 11).
- Obfuscating a **new** target schema for the first time needs no re-install — just steps
  3–7 again with the new schema name. `obf_admin`'s own objects are already there.

---

## Quick reference

Every call's **first argument is the target schema name.**

| Call | When |
|---|---|
| `obf_admin.obf_sp_obfuscate_database(target, salt, batch, purge)` | the run (and any resume) |
| `obf_admin.obf_sp_obfuscation_status(target)` | before/after a run; after a failure |
| `obf_admin.obf_sp_validate_config(target, UUID())` | pre-flight, read-only |
| `obf_admin.obf_sp_discover_user_references(target, UUID())` | pre-flight, read-only |
| `obf_admin.obf_sp_validate_reference_column_lengths(target, UUID())` | pre-flight, read-only — after discovery |
| `obf_admin.obf_sp_validate_obfuscation(target, UUID())` | re-check an already-run environment |
| `obf_admin.obf_sp_purge_sensitive_staging(target, UUID())` | strip original emails from the mapping |
| `obf_admin.obf_sp_obfuscation_prune(target, keep_runs)` | trim run history for this target |
