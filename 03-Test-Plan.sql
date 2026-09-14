-- =====================================================================
-- Test Plan — Database-Side Data Obfuscation Framework
-- Run these against a disposable copy of the lower environment (or a
-- small synthetic sample schema) BEFORE running against the real refresh.
--
-- ARCHITECTURE: the framework lives entirely in the obf_admin schema (see
-- 02-Implementation.sql). Every CALL below targets a schema named by
-- @target -- set it once to whatever throwaway schema you're testing
-- against (it need not be "current"; the CALLs work from any connection).
-- =====================================================================

SET @target = 'Appian';   -- <-- change to your disposable target schema name

-- ---------------------------------------------------------------------
-- TEST 0: Minimal fixture (skip if testing against a real lower-env copy)
-- ---------------------------------------------------------------------
-- Run against the TARGET schema (USE Appian; or similar):
-- CREATE TABLE dap_User (
--     UserID      VARCHAR(255) PRIMARY KEY,
--     FirstName   VARCHAR(50),
--     LastName    VARCHAR(50),
--     PhoneNumber VARCHAR(20),
--     Address     VARCHAR(255)
-- );
-- CREATE TABLE dap_Actor (
--     ActorID     BIGINT PRIMARY KEY AUTO_INCREMENT,
--     UserID      VARCHAR(255),
--     CreatedBy   VARCHAR(255),
--     FirstName   VARCHAR(50),
--     LastName    VARCHAR(50),
--     CONSTRAINT FK_Actor_User FOREIGN KEY (UserID) REFERENCES dap_User(UserID)
-- );
-- INSERT INTO dap_User (UserID, FirstName, LastName, PhoneNumber, Address) VALUES
--   ('john@test.com',  'John',  'Smith',  '0412345678', '1 Real Street'),
--   ('jane@test.com',  'Jane',  'Smith',  '0498765432', '2 Real Street'),
--   ('mark@test.com',  'Mark',  'Smith',  '0411112222', '3 Real Street');
-- INSERT INTO dap_Actor (UserID, CreatedBy, FirstName, LastName) VALUES
--   ('john@test.com', 'john@test.com', 'John', 'Smith'),
--   ('jane@test.com', 'john@test.com', 'Jane', 'Smith');
--
-- Run against the ADMIN schema (obf_admin), tagging every config row with
-- the target schema name:
-- INSERT INTO obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType) VALUES
--   (@target, 'dap_User',  'FirstName', 'FIRST_NAME'), (@target, 'dap_User',  'LastName', 'LAST_NAME'),
--   (@target, 'dap_User',  'PhoneNumber','PHONE'),     (@target, 'dap_User',  'Address',  'ADDRESS'),
--   (@target, 'dap_Actor', 'FirstName', 'FIRST_NAME'), (@target, 'dap_Actor', 'LastName', 'LAST_NAME');

-- ---------------------------------------------------------------------
-- TEST 1: Deterministic UserID mapping
--   Same input -> same output, every time. (Run against obf_admin.)
-- ---------------------------------------------------------------------
SELECT
    obf_fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) AS run_1,
    obf_fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) AS run_2,
    obf_fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) =
    obf_fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) AS is_deterministic;
-- EXPECT: run_1 = run_2, is_deterministic = 1

-- Different input -> (near-certainly) different output.
SELECT
    obf_fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) <>
    obf_fn_generate_obfuscated_email('jane@test.com', 'test-salt', 0, 40) AS differs_by_input;
-- EXPECT: differs_by_input = 1

-- ---------------------------------------------------------------------
-- TEST 2: Full run + referential integrity (run against obf_admin)
-- ---------------------------------------------------------------------
CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);

-- The rest of this section runs against the TARGET schema.
-- No dap_Actor.UserID should be left pointing at a non-existent dap_User.UserID
SELECT COUNT(*) AS orphaned_actor_rows
FROM dap_Actor a
LEFT JOIN dap_User u ON u.UserID = a.UserID
WHERE a.UserID IS NOT NULL AND u.UserID IS NULL;
-- EXPECT: 0

-- The FK constraint itself must exist again post-run (proves restore succeeded)
SELECT COUNT(*) AS fk_restored
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = DATABASE()
  AND TABLE_NAME = 'dap_Actor'
  AND CONSTRAINT_NAME = 'FK_Actor_User'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY';
-- EXPECT: 1

-- ---------------------------------------------------------------------
-- TEST 3: Consistent mapping across tables (target schema)
--   dap_User.UserID and dap_Actor.CreatedBy that originally held the
--   same email must hold the same obfuscated email afterward.
-- ---------------------------------------------------------------------
SELECT
    u.UserID AS user_table_value,
    a.CreatedBy AS actor_created_by_value,
    (u.UserID = a.CreatedBy) AS values_match
FROM dap_User u
JOIN dap_Actor a ON a.CreatedBy = u.UserID;
-- EXPECT: values_match = 1 for every row (both now hold the SAME obfuscated email)

-- ---------------------------------------------------------------------
-- TEST 4: PII replacement — no original values remain (target schema)
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS remaining_real_names
FROM dap_User
WHERE FirstName IN ('John','Jane','Mark') OR LastName = 'Smith';
-- EXPECT: 0

SELECT COUNT(*) AS remaining_real_phones
FROM dap_User
WHERE PhoneNumber IN ('0412345678','0498765432','0411112222');
-- EXPECT: 0

-- ---------------------------------------------------------------------
-- TEST 5: Same real first name -> independent synthetic identities
--   John Smith / Jane Smith / Mark Smith share LastName 'Smith' but are
--   different users; their synthetic LastName need not be identical,
--   and critically, two DIFFERENT users sharing a first name should not
--   be forced into the same synthetic (name, phone, address) bundle.
-- ---------------------------------------------------------------------
SELECT UserID, FirstName, LastName FROM dap_User ORDER BY UserID;
-- EXPECT: manually confirm the three rows do not all show identical
-- synthetic FirstName/LastName pairs purely because they started as "Smith".

-- ---------------------------------------------------------------------
-- TEST 6: Idempotency — running twice produces no further change
-- ---------------------------------------------------------------------
SELECT SHA2(GROUP_CONCAT(UserID, FirstName, LastName, PhoneNumber, Address ORDER BY UserID), 256) AS state_before
FROM dap_User;
-- (capture this value)

-- (run against obf_admin)
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);

SELECT SHA2(GROUP_CONCAT(UserID, FirstName, LastName, PhoneNumber, Address ORDER BY UserID), 256) AS state_after
FROM dap_User;
-- EXPECT: state_after = state_before (second run is a no-op on already-obfuscated data)

-- ---------------------------------------------------------------------
-- TEST 7: Collision handling (synthetic scenario, run against obf_admin)
--   Force a collision by pre-inserting a mapping row whose
--   ObfuscatedUserID equals what attempt 0 would generate for a new
--   user, then confirm the retry logic (attempt 1+) produces a
--   different, still-deterministic value instead of failing.
-- ---------------------------------------------------------------------
-- SET @collide_target = obf_fn_generate_obfuscated_email('newuser@test.com', 'test-salt-001', 0, 40);
-- INSERT INTO obf_UserObfuscationMapping (TargetSchema, OriginalUserID, ObfuscatedUserID, CreatedDate)
--   VALUES (@target, 'someone-else@test.com', @collide_target, NOW());
-- INSERT INTO <target schema>.dap_User (UserID, FirstName, LastName) VALUES ('newuser@test.com', 'New', 'User');
-- CALL obf_admin.obf_sp_create_user_mapping(@target, UUID(), 'test-salt-001');
-- SELECT * FROM obf_UserObfuscationMapping WHERE TargetSchema = @target AND OriginalUserID = 'newuser@test.com';
-- EXPECT: a row exists, with ObfuscatedUserID <> @collide_target (attempt 1 value used)

-- ---------------------------------------------------------------------
-- TEST 8: Failure handling — bad config is rejected before any data changes
--   (config INSERT against obf_admin; CALL against obf_admin)
-- ---------------------------------------------------------------------
-- INSERT INTO obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType)
--   VALUES (@target, 'dap_User', 'NoSuchColumn', 'STATIC');
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-002', 10000, FALSE);
-- EXPECT: procedure raises SQLSTATE 45000 from obf_sp_validate_config, and
-- obf_ObfuscationRunLog shows an ERROR row for obf_sp_validate_config with no
-- subsequent OK rows for later steps (i.e. it stopped before mutating data).
-- DELETE FROM obf_ObfuscationConfig WHERE TargetSchema = @target AND ColumnName = 'NoSuchColumn'; -- cleanup

-- ---------------------------------------------------------------------
-- TEST 9: Validation catches a deliberately broken state
-- ---------------------------------------------------------------------
-- (against the target schema)
-- INSERT INTO dap_Actor (UserID, CreatedBy, FirstName, LastName)
--   VALUES ('nonexistent-obfuscated-value@example.invalid', NULL, 'X', 'Y');
-- (against obf_admin)
-- CALL obf_admin.obf_sp_validate_obfuscation(@target, UUID());
-- EXPECT: SQLSTATE 45000 raised, obf_ObfuscationRunLog shows the orphan count for dap_Actor.UserID.
-- DELETE FROM dap_Actor WHERE UserID = 'nonexistent-obfuscated-value@example.invalid'; -- cleanup (target schema)

-- ---------------------------------------------------------------------
-- TEST 10: Orphan user-reference values (pre-existing values in a
--   NAMING_CONVENTION / MANUAL column that match no dap_User.UserID).
--   The framework must (a) report them BEFORE mutating anything, and
--   (b) handle them per obf_UserReferenceRegistry.OrphanAction so no
--   original value is left behind and the run does NOT false-fail.
-- ---------------------------------------------------------------------
-- Assumes the TEST 0 fixture, freshly reset (no prior obfuscation).

-- 10a. OBFUSCATE (default): stray value is mapped + replaced, run succeeds.
-- UPDATE dap_Actor SET CreatedBy = 'ghost-user@test.com' WHERE ActorID = 1;   -- target schema
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);   -- obf_admin
-- EXPECT: run returns a RunID (no SQLSTATE 45000); the CALL emits a
--   diagnostic result set listing (dap_Actor, CreatedBy, 'ghost-user@test.com', 1)
--   from obf_sp_report_orphan_user_references; obf_ObfuscationRunLog has a
--   obf_sp_report_orphan_user_references 'WARN' row followed by
--   obf_sp_resolve_orphan_user_references 'OK' rows.
-- SELECT COUNT(*) AS ghost_remaining FROM dap_Actor WHERE CreatedBy = 'ghost-user@test.com';   -- target
-- EXPECT: 0
-- SELECT COUNT(*) AS createdby_all_known_obf                                                    -- obf_admin
--   FROM <target>.dap_Actor a JOIN obf_UserObfuscationMapping m
--     ON m.TargetSchema = @target AND m.ObfuscatedUserID = a.CreatedBy;
-- EXPECT: equals the number of non-null CreatedBy rows

-- 10b. NULLIFY: stray value is set NULL instead of mapped.
-- (reset fixture)
-- UPDATE dap_Actor SET CreatedBy = 'ghost-user@test.com' WHERE ActorID = 1;   -- target schema
-- CALL obf_admin.obf_sp_discover_user_references(@target, UUID());           -- obf_admin
-- UPDATE obf_UserReferenceRegistry SET OrphanAction = 'NULLIFY'
--   WHERE TargetSchema = @target AND TableName = 'dap_Actor' AND ColumnName = 'CreatedBy';
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- SELECT CreatedBy FROM dap_Actor WHERE ActorID = 1;   -- target schema. EXPECT: NULL
-- EXPECT: run succeeds.

-- 10c. IGNORE: stray sentinel kept, run succeeds, validation does not flag it.
-- (reset fixture)
-- UPDATE dap_Actor SET CreatedBy = 'SYSTEM' WHERE ActorID = 1;               -- target schema
-- CALL obf_admin.obf_sp_discover_user_references(@target, UUID());           -- obf_admin
-- UPDATE obf_UserReferenceRegistry SET OrphanAction = 'IGNORE'
--   WHERE TargetSchema = @target AND TableName = 'dap_Actor' AND ColumnName = 'CreatedBy';
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- SELECT COUNT(*) AS sentinel_kept FROM dap_Actor WHERE CreatedBy = 'SYSTEM';  -- target. EXPECT: 1
-- EXPECT: run succeeds; obf_ObfuscationRunLog shows obf_sp_resolve_orphan_user_references
--   and obf_sp_validate_obfuscation 'SKIP' rows for dap_Actor.CreatedBy, and
--   'Validation passed.'

-- 10d. Idempotency with a stray present (OBFUSCATE): run 2-3x, confirm the
--   synthesised mapping row count and every obfuscated value are stable.

-- ---------------------------------------------------------------------
-- TEST 11: obf_sp_validate_config — UNIQUE constraints & type compatibility
-- ---------------------------------------------------------------------
-- 11a. A UNIQUE index on a configured column is flagged (WARN), run proceeds.
-- ALTER TABLE dap_User ADD CONSTRAINT UQ_User_Phone UNIQUE (PhoneNumber);    -- target schema
-- CALL obf_admin.obf_sp_validate_config(@target, UUID());                   -- obf_admin
-- EXPECT: obf_ObfuscationRunLog has a obf_sp_validate_config 'WARN' row naming
--   dap_User.PhoneNumber / UQ_User_Phone; the CALL also returns a diagnostic
--   result set of unique-indexed configured columns; no SQLSTATE raised.

-- 11b. STATIC on a single-column unique index with >1 row is fatal, pre-mutation.
-- (reset fixture)
-- ALTER TABLE dap_User ADD COLUMN ExternalRef VARCHAR(64);                  -- target schema
-- UPDATE dap_User SET ExternalRef = SUBSTRING_INDEX(UserID,'@',1);  -- distinct
-- ALTER TABLE dap_User ADD CONSTRAINT UQ_User_ExtRef UNIQUE (ExternalRef);
-- INSERT INTO obf_ObfuscationConfig (TargetSchema,TableName,ColumnName,ObfuscationType,StaticValue) -- obf_admin
--   VALUES (@target, 'dap_User','ExternalRef','STATIC','REDACTED');
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- EXPECT: SQLSTATE 45000 from obf_sp_validate_config; dap_User.ExternalRef and all
--   other columns unchanged (it stopped before any mutation).

-- 11c. A numeric reference column is flagged as type-incompatible.
-- (reset fixture)
-- CREATE TABLE dap_Widget (WidgetID BIGINT PRIMARY KEY AUTO_INCREMENT, CreatedBy BIGINT);  -- target
-- INSERT INTO dap_Widget (CreatedBy) VALUES (101),(102);
-- CALL obf_admin.obf_sp_discover_user_references(@target, UUID());                          -- obf_admin
-- EXPECT: obf_sp_discover_user_references 'WARN' row; its diagnostic result set shows
--   dap_Widget.CreatedBy with TypeLooksCompatible = 0.

-- ---------------------------------------------------------------------
-- TEST 12: obf_sp_validate_obfuscation — reconciliation & residual-PII
--   (CALLs against obf_admin; DELETE/UPDATE against the target schema)
-- ---------------------------------------------------------------------
-- 12a. Clean run records BEFORE/AFTER snapshots and both checks pass.
-- (reset fixture)
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- SELECT * FROM obf_ObfuscationRowCountSnapshot WHERE RunID = <that RunID>;
-- EXPECT: BEFORE and AFTER rows per table, equal counts; obf_ObfuscationRunLog shows
--   'Row-count reconciliation passed' and 'Residual-PII spot checks passed'.

-- 12b. A row-count change during the run is caught.
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);  -- capture @rid
-- DELETE FROM dap_Actor WHERE ActorID = 2;                    -- simulate a trigger/bug (target)
-- CALL obf_admin.obf_sp_validate_obfuscation(@target, @rid);
-- EXPECT: SQLSTATE 45000; log line 'Row count changed: dap_Actor before=2 after=1'.

-- 12c. A real value left behind in a configured column is caught.
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);  -- capture @rid
-- UPDATE dap_User SET FirstName = 'Zoltan' WHERE UserID LIKE '%@example.invalid' LIMIT 1;  -- target
-- CALL obf_admin.obf_sp_validate_obfuscation(@target, @rid);
-- EXPECT: SQLSTATE 45000; log line names dap_User.FirstName (FIRST_NAME) as residual PII.

-- 12d. Standalone call with no BEFORE snapshot skips reconciliation (does not fail on it).
-- CALL obf_admin.obf_sp_validate_obfuscation(@target, UUID());   -- on an otherwise-clean obfuscated DB
-- EXPECT: 'Row-count reconciliation skipped — no BEFORE snapshot' log row; proc
--   returns without error (unless 10a/10c find a real problem).

-- ---------------------------------------------------------------------
-- TEST 13: Run-state tracking & resume after a partial failure
--   (CALLs against obf_admin; fixture edits against the target schema)
-- ---------------------------------------------------------------------
-- 13a. Clean run records an obf_ObfuscationRun row.
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- CALL obf_admin.obf_sp_obfuscation_status(@target);
-- EXPECT: obf_ObfuscationRun row Status='COMPLETED' with the salt; obf_sp_obfuscation_status
--   Assessment = 'Last run COMPLETED cleanly...'; zero FK constraints dropped.

-- 13b. A failure between FK-drop and FK-restore leaves a visible half-migrated state.
-- (reset fixture)
-- CALL obf_admin.obf_sp_discover_user_references(@target, UUID());
-- UPDATE obf_UserReferenceRegistry SET OrphanAction='IGNORE'
--   WHERE TargetSchema=@target AND TableName='dap_Actor' AND ColumnName='UserID';  -- so the bad row is not fixed up
-- SET FOREIGN_KEY_CHECKS=0;                                                        -- target schema
-- INSERT INTO dap_Actor (UserID,CreatedBy,FirstName,LastName)
--   VALUES ('orphan-no-parent@x.com',NULL,'A','B');                -- FK-restore will reject this
-- SET FOREIGN_KEY_CHECKS=1;
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- EXPECT: SQLSTATE 23000; obf_ObfuscationRun row Status='FAILED' with ErrorSqlState='23000'
--   and the real FK message in ErrorText; FK_Actor_User absent from
--   information_schema.TABLE_CONSTRAINTS; obf_sp_obfuscation_status Assessment starts
--   'HALF-MIGRATED'.

-- 13c. Fix the cause and resume with the SAME salt.
-- DELETE FROM dap_Actor WHERE UserID='orphan-no-parent@x.com';    -- target schema
-- UPDATE obf_UserReferenceRegistry SET OrphanAction='OBFUSCATE'   -- obf_admin
--   WHERE TargetSchema=@target AND TableName='dap_Actor' AND ColumnName='UserID';
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- EXPECT: run succeeds; obf_ObfuscationRunLog shows a obf_sp_obfuscate_database 'WARN'
--   ('Resuming after an interrupted/failed run...'); FK_Actor_User restored;
--   obf_sp_obfuscation_status Assessment = 'Last run COMPLETED cleanly...'; the earlier
--   FAILED row is retained in obf_ObfuscationRun for audit.

-- ---------------------------------------------------------------------
-- TEST 14: Robustness / housekeeping (F7, F8, F9)
-- ---------------------------------------------------------------------
-- 14a. F7 — synthetic pickers work with non-contiguous / non-zero-based SeedID.
--   (obf_Synthetic* tables are GLOBAL, shared across every target.)
-- DELETE FROM obf_SyntheticFirstName;
-- INSERT INTO obf_SyntheticFirstName (SeedID,NameValue) VALUES (10,'Alta'),(25,'Bruno'),(500,'Dara'),(9999,'Cleo');
-- DELETE FROM obf_SyntheticLastName;
-- INSERT INTO obf_SyntheticLastName  (SeedID,NameValue) VALUES (3,'Kade'),(77,'Loom'),(1201,'Mira');
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- EXPECT: no NULL FirstName/LastName; every value is from the pool; a second run
--   with the same salt leaves them unchanged (deterministic).

-- 14b. F8 — obf_FkConstraintBackup does not grow; obf_sp_obfuscation_prune trims history.
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 't1',10000,FALSE);
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 't2',10000,FALSE);
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 't3',10000,FALSE);
-- SELECT COUNT(*) FROM obf_FkConstraintBackup WHERE TargetSchema=@target;              -- EXPECT: 1 (not 3)
-- SELECT RunID IS NOT NULL FROM obf_FkConstraintBackup WHERE TargetSchema=@target;     -- EXPECT: RunID stamped
-- CALL obf_admin.obf_sp_obfuscation_prune(@target, 1);
-- SELECT COUNT(*) FROM obf_ObfuscationRun WHERE TargetSchema=@target;                  -- EXPECT: 1
-- SELECT COUNT(DISTINCT RunID) FROM obf_ObfuscationRunLog WHERE TargetSchema=@target;  -- EXPECT: 1
-- CALL obf_admin.obf_sp_obfuscation_prune(@target, 0);                         -- EXPECT: SQLSTATE 45000

-- 14c. F9 — EMAIL type never double-suffixes.
-- ALTER TABLE dap_User ADD COLUMN AltEmail VARCHAR(254);   -- target schema
-- UPDATE dap_User SET AltEmail = CONCAT('alt.', SUBSTRING_INDEX(UserID,'@',1), '@corp.example');
-- INSERT INTO obf_ObfuscationConfig (TargetSchema,TableName,ColumnName,ObfuscationType)   -- obf_admin
--   VALUES (@target, 'dap_User','AltEmail','EMAIL');
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- SELECT COUNT(*) FROM dap_User WHERE AltEmail LIKE '%@example.invalid@example.invalid%';   -- EXPECT: 0
-- SELECT COUNT(*) FROM dap_User WHERE AltEmail RLIKE '^user_[0-9a-f]{16}@example\\.invalid$';-- EXPECT: all rows
-- EXPECT: a second run with the same salt leaves AltEmail unchanged.

-- ---------------------------------------------------------------------
-- TEST 15: Collation-agnostic reference joins
--   OriginalUserID is stored LOWER()-cased and every reference join is
--   m.OriginalUserID = LOWER(t.<col>), so case-variant reference values
--   resolve correctly regardless of column collation.
-- ---------------------------------------------------------------------
-- 15a. A mixed-case value in a reference column links to the right user.
-- UPDATE dap_Actor SET CreatedBy = 'JOHN@TEST.COM' WHERE ActorID = 1;   -- same user, upper case (target)
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);   -- obf_admin
-- SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema=@target AND OriginalUserID <> LOWER(OriginalUserID);  -- EXPECT: 0
-- SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema=@target;                                             -- EXPECT: 3 (no spurious 4th)
-- SELECT a.CreatedBy = m.ObfuscatedUserID
--   FROM <target>.dap_Actor a JOIN obf_UserObfuscationMapping m
--     ON m.TargetSchema=@target AND m.OriginalUserID='john@test.com' WHERE a.ActorID=1;  -- EXPECT: 1

-- 15b. Under a case-sensitive collation, case-only duplicate UserIDs are rejected.
-- ALTER TABLE dap_Actor DROP FOREIGN KEY FK_Actor_User;                              -- target schema
-- ALTER TABLE dap_User MODIFY UserID VARCHAR(255) COLLATE utf8mb4_bin;
-- INSERT INTO dap_User (UserID,FirstName,LastName) VALUES ('John@dup.com','J','D'),('john@dup.com','j','d');
-- CALL obf_admin.obf_sp_create_user_mapping(@target, UUID(),'test-salt-001');        -- obf_admin
-- EXPECT: SQLSTATE 45000 ('dap_User.UserID has case-only duplicate values.').

-- ---------------------------------------------------------------------
-- TEST 16: A reference column too narrow for the obfuscated user id is
--   caught pre-flight, before any destructive step (FK drop included).
-- ---------------------------------------------------------------------
-- (reset fixture)
-- ALTER TABLE dap_Actor MODIFY CreatedBy VARCHAR(20);   -- narrower than the obfuscated email needs (target)
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);   -- obf_admin
-- EXPECT: SQLSTATE 45000 from obf_sp_validate_reference_column_lengths; FK_Actor_User
--   still present in information_schema.TABLE_CONSTRAINTS (nothing destructive ran);
--   obf_ObfuscationRunLog names dap_Actor.CreatedBy with its current/required length.

-- ---------------------------------------------------------------------
-- TEST 17: The obfuscated user id never crosses 50 characters, so a
--   VARCHAR(50) reference column succeeds with NO schema change.
-- ---------------------------------------------------------------------
-- (reset fixture)
-- ALTER TABLE dap_Actor MODIFY CreatedBy VARCHAR(50);   -- target schema
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);   -- obf_admin
-- EXPECT: run succeeds (no SQLSTATE 45000).
-- SELECT MAX(LENGTH(CreatedBy)) FROM dap_Actor;   -- EXPECT: <= 50 (currently 49)

-- ---------------------------------------------------------------------
-- TEST 18: obf_TableSeedOverride unblocks a configured column on a table
--   with no user-reference column and no formal PRIMARY KEY (real legacy/
--   staging tables sometimes have an "id"-style column that was never
--   declared as a key constraint).
-- ---------------------------------------------------------------------
-- (reset fixture)
-- CREATE TABLE dap_NoPkContact (id INT NOT NULL, FirstName VARCHAR(50));  -- target schema
-- INSERT INTO dap_NoPkContact (id, FirstName) VALUES (1,'John'),(2,'Jane');
-- INSERT INTO obf_ObfuscationConfig (TargetSchema,TableName,ColumnName,ObfuscationType)   -- obf_admin
--   VALUES (@target, 'dap_NoPkContact','FirstName','FIRST_NAME');
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- EXPECT: FirstName untouched; obf_ObfuscationRunLog has a SKIP row naming dap_NoPkContact.
-- INSERT INTO obf_TableSeedOverride (TargetSchema,TableName,ColumnName) VALUES (@target, 'dap_NoPkContact','id');
-- CALL obf_admin.obf_sp_obfuscate_database(@target, 'test-salt-001', 10000, FALSE);
-- EXPECT: FirstName now obfuscated (drawn from obf_SyntheticFirstName), keyed off id.

-- ---------------------------------------------------------------------
-- TEST 19: Multi-target isolation — one obf_admin install obfuscating
--   two different target schemas keeps every state table fully separate.
-- ---------------------------------------------------------------------
-- SET @target2 = 'AnotherSchema';
-- (build the same fixture in @target2, configure it in obf_ObfuscationConfig with TargetSchema=@target2)
-- CALL obf_admin.obf_sp_obfuscate_database(@target,  'salt-1', 10000, FALSE);
-- CALL obf_admin.obf_sp_obfuscate_database(@target2, 'salt-2', 10000, FALSE);
-- SELECT COUNT(DISTINCT TargetSchema) FROM obf_UserObfuscationMapping WHERE TargetSchema IN (@target, @target2);  -- EXPECT: 2
-- SELECT COUNT(*) FROM obf_UserObfuscationMapping m1 JOIN obf_UserObfuscationMapping m2
--   ON m1.OriginalUserID = m2.OriginalUserID
--   WHERE m1.TargetSchema = @target AND m2.TargetSchema = @target2 AND m1.ObfuscatedUserID = m2.ObfuscatedUserID;
-- EXPECT: 0 -- same original email maps to a DIFFERENT obfuscated value per target (different salts).

-- ---------------------------------------------------------------------
-- Review the full run history for a target at any point (run against obf_admin):
-- ---------------------------------------------------------------------
SELECT * FROM obf_ObfuscationRunLog WHERE TargetSchema = @target ORDER BY LogID;
SELECT * FROM obf_ObfuscationRun    WHERE TargetSchema = @target ORDER BY StartedAt;
-- CALL obf_admin.obf_sp_obfuscation_status(@target);

-- ---------------------------------------------------------------------
-- Or drive the whole plan as assertions:  bash test/run-all.sh
-- ---------------------------------------------------------------------
