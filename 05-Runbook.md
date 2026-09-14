# Runbook — Running the Obfuscation in a Lower Environment

This is the operational procedure for `02-Implementation.sql`. It runs **inside the
lower-environment database only**, after the production→lower copy has finished and
**before** the environment is opened to users. Nothing here touches production.

### Connecting to your sandbox

Your sandbox MariaDB is the Docker Desktop container on **host port 3308**. Fill in your
own user / password / schema name; the examples below use `<user>`, `<db>`:

```bash
# host client (works regardless of container name/engine)
mariadb -h 127.0.0.1 -P 3308 -u <user> -p <db> < <file>       # run a script
mariadb -h 127.0.0.1 -P 3308 -u <user> -p <db>                # interactive shell

# or exec into the container (container is named "mariadb" on the desktop-linux engine)
docker exec -i  mariadb mariadb -u <user> -p<password> <db> < <file>
docker exec -it mariadb mariadb -u <user> -p<password> <db>
```

Run `.sql` files with the CLI (`< file` or `SOURCE file;`) or your GUI client's
**"Execute SQL Script"** mode — **not** "execute one statement" (the file is a
multi-statement script with `DELIMITER $$` blocks; see the `1064 ... near 'CREATE TABLE'`
symptom).

Below, `mysql <db> < file` is shorthand for whichever of the two forms you use.

---

## 0. Before you start — safety gates

- [ ] Confirm you are connected to the **lower / sandbox** database, not production
      (`SELECT @@hostname, DATABASE();`).
- [ ] The production→lower data copy is **complete**.
- [ ] Take a **snapshot / backup** of the lower environment (so a bad run is recoverable
      beyond the framework's own resume path).
- [ ] **Disable any triggers or scheduled jobs** in the lower env that send email / call
      external systems / assume production-shaped data. The framework does **not** disable
      triggers; they will fire on the obfuscating `UPDATE`s.
- [ ] Make sure no application traffic is hitting the schema during the run.

---

## 1. Adapt the framework to your schema (only if names differ)

The script assumes:

| Assumed | Meaning |
|---|---|
| `dap_User` | the user table |
| `dap_User.UserID` | primary key **and** the email address |
| `dap_User` columns like `FirstName`, `LastName`, `PhoneNumber`, `Address` | PII to replace |
| columns named `CreatedBy`, `CreatedUser`, `CreatedUserID`, `ModifiedBy`, `ModifiedUserID` | value-copies of a `UserID` |

If your schema differs:

- Global search/replace `dap_User` / `UserID` in `02-Implementation.sql` for your real
  user table / key column.
- Edit the naming-convention list in `obf_sp_discover_user_references` (section 4b) to match
  your audit-column names.
- Everything else (which PII columns, which types) is **data**, set in `obf_ObfuscationConfig`
  in step 3 — no code change.

If `dap_User.UserID` is **not** the email (e.g. it's a numeric id and the email is in
`dap_User.Email`), that is a larger change — tell the author; the mapping generator and the
reference-rewrite logic are built around "the key is the email".

---

## 2. Load the framework

```bash
mariadb -h 127.0.0.1 -P 3308 -u <user> -p <db> < 02-Implementation.sql
```

Creates: config/registry/mapping/run tables, the `Synthetic*` seed tables (with a small
starter set), 6 functions, and the `sp_*` procedures. Re-runnable — loading it again is a
no-op on existing objects.

**Optional but recommended:** extend the synthetic seed tables so replacement names/
addresses have enough variety for your row counts (a 20-name pool over 100k users means
~5k users share each name):

```sql
INSERT INTO obf_SyntheticFirstName (SeedID, NameValue) VALUES (20,'Ava'),(21,'Leo'), ... ;
INSERT INTO obf_SyntheticLastName  (SeedID, NameValue) VALUES (20,'Reyes'), ... ;
INSERT INTO obf_SyntheticStreetAddress (SeedID, AddressValue) VALUES (10,'7 Cedar Way'), ... ;
-- SeedID only has to be unique; gaps / non-zero start are fine.
```

---

## 3. Declare what to obfuscate — `obf_ObfuscationConfig`

One row per PII column. `ObfuscationType` is one of
`FIRST_NAME | LAST_NAME | PHONE | ADDRESS | EMAIL | STATIC | HASH`.

```sql
INSERT INTO obf_ObfuscationConfig (TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('dap_User',  'FirstName',   'FIRST_NAME', NULL),
  ('dap_User',  'LastName',    'LAST_NAME',  NULL),
  ('dap_User',  'PhoneNumber', 'PHONE',      NULL),
  ('dap_User',  'Address',     'ADDRESS',    NULL),
  ('dap_User',  'SecondaryEmail','EMAIL',    NULL),
  ('dap_User',  'PasswordHash','STATIC',     '!obfuscated!'),
  ('dap_User',  'ApiToken',    'HASH',       NULL),
  ('dap_Actor', 'FirstName',   'FIRST_NAME', NULL),
  ('dap_Actor', 'LastName',    'LAST_NAME',  NULL);
```

Notes:
- `dap_User.UserID` (the primary email) is handled automatically — **do not** add it here.
- `STATIC` writes one literal to every row; don't use it on a column that has a
  single-column `UNIQUE` index (step 4 will hard-stop you).
- `HASH` is keyed off the row's stable seed + salt (deterministic, one-way).
- `Enabled = FALSE` on a row skips it without deleting it.

Free-text / JSON columns are **not** scanned. Add them explicitly here (usually `STATIC`)
if you know they hold PII.

---

## 4. Pre-flight — read-only, no data changes

Run these individually and read the result sets before the real run.

**4a. Discover user references + check column types:**

```sql
CALL obf_sp_discover_user_references(UUID());
```

Look at the diagnostic result set:
- Every `FOREIGN_KEY` / `NAMING_CONVENTION` column that points at a user.
- `TypeLooksCompatible = 0` → a `WARN`; that column is probably **not** a UserID copy
  (e.g. a numeric `CreatedBy`). Set `Enabled = FALSE` for it:
  ```sql
  UPDATE obf_UserReferenceRegistry SET Enabled = FALSE
   WHERE TableName = '...' AND ColumnName = '...';
  ```

**4b. Validate the config against the live schema:**

```sql
CALL obf_sp_validate_config(UUID());
```

- Missing column → **hard error**, fix the `obf_ObfuscationConfig` row.
- `WARN` about a `UNIQUE` index on a configured column → make sure the replacement value
  space is big enough (extend the seed tables, or switch `STATIC`→`HASH`).
- `STATIC` on a single-column unique index with >1 row → **hard error**; change the type.

**4c. Check reference-column widths:**

```sql
CALL obf_sp_validate_reference_column_lengths(UUID());
```

Every column in `obf_UserReferenceRegistry` gets overwritten with the **same** obfuscated
email that's written to `dap_User.UserID`, so it must be at least as wide as that value gets
(driven by `dap_User.UserID`'s own column width). A narrower column → **hard error**
(`Data too long for column '<col>'` is exactly this, if you hit it without running this
check first). Fix by widening the column, or by disabling that reference column:
```sql
UPDATE obf_UserReferenceRegistry SET Enabled = FALSE
 WHERE TableName = '...' AND ColumnName = '...';
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
UPDATE obf_UserReferenceRegistry SET OrphanAction = 'IGNORE'
 WHERE TableName = 'dap_Actor' AND ColumnName = 'CreatedBy';
```

---

## 6. Rehearsal (strongly recommended for a first run)

The `test/run-all.sh` harness is a rehearsal tool: it **drops and recreates** its database
and loads the tiny sample fixture, then asserts all 15 test-plan cases (49 checks). Point
it at a **throwaway schema only**:

```bash
DBOBF_CTX=desktop-linux DBOBF_CONTAINER=mariadb \
  DBOBF_USER=<user> DBOBF_PW=<password> DBOBF_DB=dbobf_rehearsal \
  bash test/run-all.sh
```

For a real schema copy, don't use the harness — restore a copy, then run
`CALL obf_sp_obfuscate_database(...)` (step 7) against the copy and walk the checks in
steps 8–9.

---

## 7. Run it

```sql
CALL obf_sp_obfuscate_database(
    'CHANGE-ME-secret-salt-for-this-refresh',  -- p_salt: secret, rotate per refresh cycle
    50000,                                     -- p_batch_size for large-table UPDATEs
    FALSE                                      -- p_purge_after: strip original emails now?
);
```

- **`p_salt`** — a secret string. Same input + same salt → same obfuscated output. Keep it
  somewhere safe: **a resume run (step 11) must use the exact same salt.** Rotate it
  between independent refresh cycles.
- **`p_batch_size`** — rows per `UPDATE` on large tables; 50 000 is a sane default.
- **`p_purge_after`** — `TRUE` overwrites the original emails in `obf_UserObfuscationMapping`
  after validation passes (see step 9). Leave `FALSE` on the first run so you can inspect,
  then purge separately.

The call returns the `RunID` on success and prints diagnostic result sets along the way
(discovered references, orphan report, unique-index report).

---

## 8. Check the result

```sql
CALL obf_sp_obfuscation_status();
```

Expect: `Assessment = 'Last run COMPLETED cleanly. Safe to open the environment.'` and
**0** FK constraints currently dropped.

```sql
SELECT StepName, StepStatus, Message
FROM obf_ObfuscationRunLog
WHERE RunID = '<the RunID>'
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
reconciliation. Add your own eyeball checks, e.g.:

```sql
-- every user email is now a synthetic one
SELECT COUNT(*) FROM dap_User WHERE UserID NOT LIKE '%@example.invalid';   -- expect 0

-- no obviously-real names survived
SELECT UserID, FirstName, LastName, PhoneNumber, Address FROM dap_User LIMIT 50;

-- reference columns all resolve to a known obfuscated user
SELECT 'dap_Actor.CreatedBy' col, COUNT(*) bad
FROM dap_Actor a LEFT JOIN obf_UserObfuscationMapping m ON m.ObfuscatedUserID = a.CreatedBy
WHERE a.CreatedBy IS NOT NULL AND m.ObfuscatedUserID IS NULL;                -- expect 0
```

Check any free-text / JSON columns you flagged manually.

---

## 10. Lock down the mapping table, then open the environment

`obf_UserObfuscationMapping.OriginalUserID` still holds real email addresses. Choose one:

- **Purge** — no further delta sync planned for this cycle:
  ```sql
  CALL obf_sp_purge_sensitive_staging(UUID());
  -- or pass p_purge_after = TRUE to obf_sp_obfuscate_database next time
  ```
  This overwrites `OriginalUserID` with a non-reversible placeholder, keeping
  `ObfuscatedUserID`.

- **Retain** — you need it for future delta syncs: **move `obf_UserObfuscationMapping` to a
  schema/database with tighter access controls** than the general lower-env schema, and
  restrict `SELECT` on it.

Then:

- [ ] Re-enable the triggers / jobs you disabled in step 0.
- [ ] Open the environment to users.

---

## 11. If the run fails partway (resume)

The run is **not atomic** by design (the FK drop/restore steps issue DDL, which commits;
large `UPDATE`s commit in batches). A failure leaves the schema **partly migrated but
recoverable**.

```sql
CALL obf_sp_obfuscation_status();
```

- `Assessment` starting `HALF-MIGRATED` → some FK constraints are currently dropped.
- `LastRunStatus = FAILED` with `ErrorText` / `ErrorSqlState` → the actual cause.

**Fix the cause** the error points at (e.g. a data problem an FK won't accept, a bad
config row, or — a sample first-run failure — `Data too long for column '<col>'`, meaning
that `<col>` is a registered reference column too narrow to hold the obfuscated email; widen
it or `Enabled = FALSE` it per step 4c, then resume), then **re-run
`obf_sp_obfuscate_database` with the exact same salt**:

```sql
CALL obf_sp_obfuscate_database('CHANGE-ME-secret-salt-for-this-refresh', 50000, FALSE);
```

Every step is idempotent — the resume finishes the remaining work and restores the FKs.
It logs a `WARN` ("Resuming after an interrupted/failed run …") so you can see it happened.

---

## 12. Repeat refreshes & housekeeping

- Re-running on an already-obfuscated environment (next month's refresh) is safe — the
  idempotency guards mean it re-validates rather than re-scrambling.
- Run-history tables (`obf_ObfuscationRun`, `obf_ObfuscationRunLog`, `obf_ObfuscationRowCountSnapshot`)
  are kept for audit. Trim them when you want:
  ```sql
  CALL obf_sp_obfuscation_prune(20);   -- keep the newest 20 runs
  ```
- `obf_FkConstraintBackup` is transient — the orchestrator clears spent rows at the start of
  every run; a non-empty table between runs means a run stopped mid-way (step 11).

---

## Quick reference

| Call | When |
|---|---|
| `obf_sp_obfuscate_database(salt, batch, purge)` | the run (and any resume) |
| `obf_sp_obfuscation_status()` | before/after a run; after a failure |
| `obf_sp_validate_config(UUID())` | pre-flight, read-only |
| `obf_sp_discover_user_references(UUID())` | pre-flight, read-only |
| `obf_sp_validate_reference_column_lengths(UUID())` | pre-flight, read-only — after discovery |
| `obf_sp_validate_obfuscation(UUID())` | re-check an already-run environment |
| `obf_sp_purge_sensitive_staging(UUID())` | strip original emails from the mapping |
| `obf_sp_obfuscation_prune(keep_runs)` | trim run history |
