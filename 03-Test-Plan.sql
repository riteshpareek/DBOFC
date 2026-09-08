-- =====================================================================
-- Test Plan — Database-Side Data Obfuscation Framework
-- Run these against a disposable copy of the lower environment (or a
-- small synthetic sample schema) BEFORE running against the real refresh.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TEST 0: Minimal fixture (skip if testing against a real lower-env copy)
-- ---------------------------------------------------------------------
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
-- INSERT INTO ObfuscationConfig (TableName, ColumnName, ObfuscationType) VALUES
--   ('dap_User',  'FirstName', 'FIRST_NAME'), ('dap_User',  'LastName', 'LAST_NAME'),
--   ('dap_User',  'PhoneNumber','PHONE'),     ('dap_User',  'Address',  'ADDRESS'),
--   ('dap_Actor', 'FirstName', 'FIRST_NAME'), ('dap_Actor', 'LastName', 'LAST_NAME');

-- ---------------------------------------------------------------------
-- TEST 1: Deterministic UserID mapping
--   Same input -> same output, every time.
-- ---------------------------------------------------------------------
SELECT
    fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) AS run_1,
    fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) AS run_2,
    fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) =
    fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) AS is_deterministic;
-- EXPECT: run_1 = run_2, is_deterministic = 1

-- Different input -> (near-certainly) different output.
SELECT
    fn_generate_obfuscated_email('john@test.com', 'test-salt', 0, 40) <>
    fn_generate_obfuscated_email('jane@test.com', 'test-salt', 0, 40) AS differs_by_input;
-- EXPECT: differs_by_input = 1

-- ---------------------------------------------------------------------
-- TEST 2: Full run + referential integrity
-- ---------------------------------------------------------------------
CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);

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
-- TEST 3: Consistent mapping across tables
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
-- TEST 4: PII replacement — no original values remain
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

CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);

SELECT SHA2(GROUP_CONCAT(UserID, FirstName, LastName, PhoneNumber, Address ORDER BY UserID), 256) AS state_after
FROM dap_User;
-- EXPECT: state_after = state_before (second run is a no-op on already-obfuscated data)

-- ---------------------------------------------------------------------
-- TEST 7: Collision handling (synthetic scenario)
--   Force a collision by pre-inserting a mapping row whose
--   ObfuscatedUserID equals what attempt 0 would generate for a new
--   user, then confirm the retry logic (attempt 1+) produces a
--   different, still-deterministic value instead of failing.
-- ---------------------------------------------------------------------
-- SET @collide_target = fn_generate_obfuscated_email('newuser@test.com', 'test-salt-001', 0, 40);
-- INSERT INTO UserObfuscationMapping (OriginalUserID, ObfuscatedUserID, CreatedDate)
--   VALUES ('someone-else@test.com', @collide_target, NOW());
-- INSERT INTO dap_User (UserID, FirstName, LastName) VALUES ('newuser@test.com', 'New', 'User');
-- CALL sp_create_user_mapping(UUID(), 'test-salt-001');
-- SELECT * FROM UserObfuscationMapping WHERE OriginalUserID = 'newuser@test.com';
-- EXPECT: a row exists, with ObfuscatedUserID <> @collide_target (attempt 1 value used)

-- ---------------------------------------------------------------------
-- TEST 8: Failure handling — bad config is rejected before any data changes
-- ---------------------------------------------------------------------
-- INSERT INTO ObfuscationConfig (TableName, ColumnName, ObfuscationType)
--   VALUES ('dap_User', 'NoSuchColumn', 'STATIC');
-- CALL sp_obfuscate_database('test-salt-002', 10000, FALSE);
-- EXPECT: procedure raises SQLSTATE 45000 from sp_validate_config, and
-- ObfuscationRunLog shows an ERROR row for sp_validate_config with no
-- subsequent OK rows for later steps (i.e. it stopped before mutating data).
-- DELETE FROM ObfuscationConfig WHERE ColumnName = 'NoSuchColumn'; -- cleanup

-- ---------------------------------------------------------------------
-- TEST 9: Validation catches a deliberately broken state
-- ---------------------------------------------------------------------
-- INSERT INTO dap_Actor (UserID, CreatedBy, FirstName, LastName)
--   VALUES ('nonexistent-obfuscated-value@example.invalid', NULL, 'X', 'Y');
-- CALL sp_validate_obfuscation(UUID());
-- EXPECT: SQLSTATE 45000 raised, ObfuscationRunLog shows the orphan count for dap_Actor.UserID.
-- DELETE FROM dap_Actor WHERE UserID = 'nonexistent-obfuscated-value@example.invalid'; -- cleanup

-- ---------------------------------------------------------------------
-- TEST 10: Orphan user-reference values (pre-existing values in a
--   NAMING_CONVENTION / MANUAL column that match no dap_User.UserID).
--   The framework must (a) report them BEFORE mutating anything, and
--   (b) handle them per UserReferenceRegistry.OrphanAction so no
--   original value is left behind and the run does NOT false-fail.
-- ---------------------------------------------------------------------
-- Assumes the TEST 0 fixture, freshly reset (no prior obfuscation).

-- 10a. OBFUSCATE (default): stray value is mapped + replaced, run succeeds.
-- UPDATE dap_Actor SET CreatedBy = 'ghost-user@test.com' WHERE ActorID = 1;
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- EXPECT: run returns a RunID (no SQLSTATE 45000); the CALL emits a
--   diagnostic result set listing (dap_Actor, CreatedBy, 'ghost-user@test.com', 1)
--   from sp_report_orphan_user_references; ObfuscationRunLog has a
--   sp_report_orphan_user_references 'WARN' row followed by
--   sp_resolve_orphan_user_references 'OK' rows.
-- SELECT COUNT(*) AS ghost_remaining FROM dap_Actor WHERE CreatedBy = 'ghost-user@test.com';
-- EXPECT: 0
-- SELECT COUNT(*) AS createdby_all_known_obf
--   FROM dap_Actor a JOIN UserObfuscationMapping m ON m.ObfuscatedUserID = a.CreatedBy;
-- EXPECT: equals the number of non-null CreatedBy rows

-- 10b. NULLIFY: stray value is set NULL instead of mapped.
-- (reset fixture)
-- UPDATE dap_Actor SET CreatedBy = 'ghost-user@test.com' WHERE ActorID = 1;
-- CALL sp_discover_user_references(UUID());
-- UPDATE UserReferenceRegistry SET OrphanAction = 'NULLIFY'
--   WHERE TableName = 'dap_Actor' AND ColumnName = 'CreatedBy';
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- SELECT CreatedBy FROM dap_Actor WHERE ActorID = 1;   -- EXPECT: NULL
-- EXPECT: run succeeds.

-- 10c. IGNORE: stray sentinel kept, run succeeds, validation does not flag it.
-- (reset fixture)
-- UPDATE dap_Actor SET CreatedBy = 'SYSTEM' WHERE ActorID = 1;
-- CALL sp_discover_user_references(UUID());
-- UPDATE UserReferenceRegistry SET OrphanAction = 'IGNORE'
--   WHERE TableName = 'dap_Actor' AND ColumnName = 'CreatedBy';
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- SELECT COUNT(*) AS sentinel_kept FROM dap_Actor WHERE CreatedBy = 'SYSTEM';  -- EXPECT: 1
-- EXPECT: run succeeds; ObfuscationRunLog shows sp_resolve_orphan_user_references
--   and sp_validate_obfuscation 'SKIP' rows for dap_Actor.CreatedBy, and
--   'Validation passed.'

-- 10d. Idempotency with a stray present (OBFUSCATE): run 2-3x, confirm the
--   synthesised mapping row count and every obfuscated value are stable.

-- ---------------------------------------------------------------------
-- TEST 11: sp_validate_config — UNIQUE constraints & type compatibility
-- ---------------------------------------------------------------------
-- 11a. A UNIQUE index on a configured column is flagged (WARN), run proceeds.
-- ALTER TABLE dap_User ADD CONSTRAINT UQ_User_Phone UNIQUE (PhoneNumber);
-- CALL sp_validate_config(UUID());
-- EXPECT: ObfuscationRunLog has a sp_validate_config 'WARN' row naming
--   dap_User.PhoneNumber / UQ_User_Phone; the CALL also returns a diagnostic
--   result set of unique-indexed configured columns; no SQLSTATE raised.

-- 11b. STATIC on a single-column unique index with >1 row is fatal, pre-mutation.
-- (reset fixture)
-- ALTER TABLE dap_User ADD COLUMN ExternalRef VARCHAR(64);
-- UPDATE dap_User SET ExternalRef = SUBSTRING_INDEX(UserID,'@',1);  -- distinct
-- ALTER TABLE dap_User ADD CONSTRAINT UQ_User_ExtRef UNIQUE (ExternalRef);
-- INSERT INTO ObfuscationConfig (TableName,ColumnName,ObfuscationType,StaticValue)
--   VALUES ('dap_User','ExternalRef','STATIC','REDACTED');
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- EXPECT: SQLSTATE 45000 from sp_validate_config; dap_User.ExternalRef and all
--   other columns unchanged (it stopped before any mutation).

-- 11c. A numeric reference column is flagged as type-incompatible.
-- (reset fixture)
-- CREATE TABLE dap_Widget (WidgetID BIGINT PRIMARY KEY AUTO_INCREMENT, CreatedBy BIGINT);
-- INSERT INTO dap_Widget (CreatedBy) VALUES (101),(102);
-- CALL sp_discover_user_references(UUID());
-- EXPECT: sp_discover_user_references 'WARN' row; its diagnostic result set shows
--   dap_Widget.CreatedBy with TypeLooksCompatible = 0.

-- ---------------------------------------------------------------------
-- TEST 12: sp_validate_obfuscation — reconciliation & residual-PII
-- ---------------------------------------------------------------------
-- 12a. Clean run records BEFORE/AFTER snapshots and both checks pass.
-- (reset fixture)
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- SELECT * FROM ObfuscationRowCountSnapshot WHERE RunID = <that RunID>;
-- EXPECT: BEFORE and AFTER rows per table, equal counts; ObfuscationRunLog shows
--   'Row-count reconciliation passed' and 'Residual-PII spot checks passed'.

-- 12b. A row-count change during the run is caught.
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);  -- capture @rid
-- DELETE FROM dap_Actor WHERE ActorID = 2;                    -- simulate a trigger/bug
-- CALL sp_validate_obfuscation(@rid);
-- EXPECT: SQLSTATE 45000; log line 'Row count changed: dap_Actor before=2 after=1'.

-- 12c. A real value left behind in a configured column is caught.
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);  -- capture @rid
-- UPDATE dap_User SET FirstName = 'Zoltan' WHERE UserID LIKE '%@example.invalid' LIMIT 1;
-- CALL sp_validate_obfuscation(@rid);
-- EXPECT: SQLSTATE 45000; log line names dap_User.FirstName (FIRST_NAME) as residual PII.

-- 12d. Standalone call with no BEFORE snapshot skips reconciliation (does not fail on it).
-- CALL sp_validate_obfuscation(UUID());   -- on an otherwise-clean obfuscated DB
-- EXPECT: 'Row-count reconciliation skipped — no BEFORE snapshot' log row; proc
--   returns without error (unless 10a/10c find a real problem).

-- ---------------------------------------------------------------------
-- TEST 13: Run-state tracking & resume after a partial failure
-- ---------------------------------------------------------------------
-- 13a. Clean run records an ObfuscationRun row.
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- CALL sp_obfuscation_status();
-- EXPECT: ObfuscationRun row Status='COMPLETED' with the salt; sp_obfuscation_status
--   Assessment = 'Last run COMPLETED cleanly...'; zero FK constraints dropped.

-- 13b. A failure between FK-drop and FK-restore leaves a visible half-migrated state.
-- (reset fixture)
-- CALL sp_discover_user_references(UUID());
-- UPDATE UserReferenceRegistry SET OrphanAction='IGNORE'
--   WHERE TableName='dap_Actor' AND ColumnName='UserID';           -- so the bad row is not fixed up
-- SET FOREIGN_KEY_CHECKS=0;
-- INSERT INTO dap_Actor (UserID,CreatedBy,FirstName,LastName)
--   VALUES ('orphan-no-parent@x.com',NULL,'A','B');                -- FK-restore will reject this
-- SET FOREIGN_KEY_CHECKS=1;
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- EXPECT: SQLSTATE 23000; ObfuscationRun row Status='FAILED' with ErrorSqlState='23000'
--   and the real FK message in ErrorText; FK_Actor_User absent from
--   information_schema.TABLE_CONSTRAINTS; sp_obfuscation_status Assessment starts
--   'HALF-MIGRATED'.

-- 13c. Fix the cause and resume with the SAME salt.
-- DELETE FROM dap_Actor WHERE UserID='orphan-no-parent@x.com';
-- UPDATE UserReferenceRegistry SET OrphanAction='OBFUSCATE'
--   WHERE TableName='dap_Actor' AND ColumnName='UserID';
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- EXPECT: run succeeds; ObfuscationRunLog shows a sp_obfuscate_database 'WARN'
--   ('Resuming after an interrupted/failed run...'); FK_Actor_User restored;
--   sp_obfuscation_status Assessment = 'Last run COMPLETED cleanly...'; the earlier
--   FAILED row is retained in ObfuscationRun for audit.

-- ---------------------------------------------------------------------
-- TEST 14: Robustness / housekeeping (F7, F8, F9)
-- ---------------------------------------------------------------------
-- 14a. F7 — synthetic pickers work with non-contiguous / non-zero-based SeedID.
-- DELETE FROM SyntheticFirstName;
-- INSERT INTO SyntheticFirstName (SeedID,NameValue) VALUES (10,'Alta'),(25,'Bruno'),(500,'Dara'),(9999,'Cleo');
-- DELETE FROM SyntheticLastName;
-- INSERT INTO SyntheticLastName  (SeedID,NameValue) VALUES (3,'Kade'),(77,'Loom'),(1201,'Mira');
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- EXPECT: no NULL FirstName/LastName; every value is from the pool; a second run
--   with the same salt leaves them unchanged (deterministic).

-- 14b. F8 — FkConstraintBackup does not grow; sp_obfuscation_prune trims history.
-- CALL sp_obfuscate_database('t1',10000,FALSE);
-- CALL sp_obfuscate_database('t2',10000,FALSE);
-- CALL sp_obfuscate_database('t3',10000,FALSE);
-- SELECT COUNT(*) FROM FkConstraintBackup;              -- EXPECT: 1 (not 3)
-- SELECT RunID IS NOT NULL FROM FkConstraintBackup;     -- EXPECT: RunID stamped
-- CALL sp_obfuscation_prune(1);
-- SELECT COUNT(*) FROM ObfuscationRun;                  -- EXPECT: 1
-- SELECT COUNT(DISTINCT RunID) FROM ObfuscationRunLog;  -- EXPECT: 1
-- CALL sp_obfuscation_prune(0);                         -- EXPECT: SQLSTATE 45000

-- 14c. F9 — EMAIL type never double-suffixes.
-- ALTER TABLE dap_User ADD COLUMN AltEmail VARCHAR(254);
-- UPDATE dap_User SET AltEmail = CONCAT('alt.', SUBSTRING_INDEX(UserID,'@',1), '@corp.example');
-- INSERT INTO ObfuscationConfig (TableName,ColumnName,ObfuscationType) VALUES ('dap_User','AltEmail','EMAIL');
-- CALL sp_obfuscate_database('test-salt-001', 10000, FALSE);
-- SELECT COUNT(*) FROM dap_User WHERE AltEmail LIKE '%@example.invalid@example.invalid%';   -- EXPECT: 0
-- SELECT COUNT(*) FROM dap_User WHERE AltEmail RLIKE '^user_[0-9a-f]{16}@example\\.invalid$';-- EXPECT: all rows
-- EXPECT: a second run with the same salt leaves AltEmail unchanged.

-- ---------------------------------------------------------------------
-- Review the full run history at any point:
-- ---------------------------------------------------------------------
SELECT * FROM ObfuscationRunLog ORDER BY LogID;
SELECT * FROM ObfuscationRun    ORDER BY StartedAt;
-- CALL sp_obfuscation_status();
