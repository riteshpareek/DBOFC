-- =====================================================================
-- Database-Side Data Obfuscation Framework
-- Target: MariaDB
--
-- ARCHITECTURE: this script installs entirely into a dedicated ADMIN
-- schema (`obf_admin` below -- a fixed name chosen at authoring time; if
-- you rename it, find/replace `obf_admin` throughout this file). None of
-- the framework's ~35 objects are installed into any target application
-- schema. Every entry point instead takes the target schema name as an
-- explicit p_target_schema parameter, so ONE obf_admin install can
-- obfuscate any number of target schemas, each fully isolated from the
-- others (every admin-side state table carries a TargetSchema column).
--
-- Run this once, from any starting schema:
--   SOURCE 02-Implementation.sql;
-- Then, per target schema you want to obfuscate:
--   CALL obf_admin.obf_sp_obfuscate_database('appiandev2', 'secret-salt', 50000, FALSE);
--
-- Assumes: this runs against the LOWER-ENVIRONMENT COPY only, after the
--          production->lower copy has completed.
-- Assumes: dap_User.UserID is NOT the user's email address -- it's a
--          stripped, local-part-shaped identifier derived from it (e.g.
--          "Wendy.Boyce" for Wendy.Boyce@sa.gov.au). It still directly
--          names a real person, so it is obfuscated the same as any other
--          PII (see obf_fn_generate_obfuscated_user_id); it is just not
--          given an '@domain' suffix, since the original never had one.
--          Adjust column names below if your actual schema differs.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS obf_admin;

-- ---------------------------------------------------------------------
-- 0. CONFIGURATION SCHEMA (admin schema, one row set per TargetSchema)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS obf_admin.obf_ObfuscationConfig (
    ConfigID          BIGINT AUTO_INCREMENT PRIMARY KEY,
    TargetSchema      VARCHAR(128) NOT NULL,
    TableName         VARCHAR(128) NOT NULL,
    ColumnName        VARCHAR(128) NOT NULL,
    ObfuscationType   VARCHAR(50)  NOT NULL,   -- FIRST_NAME | LAST_NAME | PHONE | ADDRESS | EMAIL | STATIC | HASH
    StaticValue       VARCHAR(255) NULL,       -- used when ObfuscationType = STATIC
    Enabled           BOOLEAN      NOT NULL DEFAULT TRUE,
    UNIQUE KEY UK_ObfuscationConfig (TargetSchema, TableName, ColumnName)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS obf_admin.obf_UserReferenceRegistry (
    RegistryID        BIGINT AUTO_INCREMENT PRIMARY KEY,
    TargetSchema      VARCHAR(128) NOT NULL,
    TableName         VARCHAR(128) NOT NULL,
    ColumnName        VARCHAR(128) NOT NULL,
    DiscoveryMethod   VARCHAR(30)  NOT NULL,   -- FOREIGN_KEY | NAMING_CONVENTION | MANUAL
    ConstraintName    VARCHAR(128) NULL,
    Enabled           BOOLEAN      NOT NULL DEFAULT TRUE,
    -- What to do with a value in this column that does NOT correspond to any
    -- dap_User.UserID (a departed user, a system sentinel, historical bad data):
    --   OBFUSCATE (default) - synthesise a mapping row for it so it is replaced
    --                         like any other reference; guarantees no original
    --                         value survives.
    --   NULLIFY             - set those values to NULL.
    --   IGNORE              - leave them untouched AND stop the post-run
    --                         validation from flagging them. Only set this once
    --                         you have seen the pre-flight orphan report and
    --                         confirmed the values are non-sensitive.
    OrphanAction      VARCHAR(10)  NOT NULL DEFAULT 'OBFUSCATE',
    UNIQUE KEY UK_UserReferenceRegistry (TargetSchema, TableName, ColumnName)
) ENGINE=InnoDB;

-- For installs created before OrphanAction existed.
ALTER TABLE obf_admin.obf_UserReferenceRegistry
    ADD COLUMN IF NOT EXISTS OrphanAction VARCHAR(10) NOT NULL DEFAULT 'OBFUSCATE';

-- obf_sp_obfuscate_configured_columns needs a deterministic per-row seed column
-- (a registered user-reference column, else the table's own PRIMARY KEY) to
-- generate stable synthetic values. Some real schemas have tables with an
-- obvious unique row identifier (an "id"/"XxxID" column) that was simply never
-- declared as a PRIMARY KEY constraint. Rather than requiring a DBA to alter
-- the target application's schema just to unblock obfuscation, this table
-- lets them register that column explicitly as a manual seed -- checked only
-- after the user-reference and true-PRIMARY-KEY lookups both come up empty.
-- The DBA is responsible for confirming the column is actually unique per row
-- (a non-unique seed does not corrupt data -- worst case two rows collapse
-- onto the same synthetic value -- but does weaken the "distinct rows get
-- distinct synthetic identities" property).
CREATE TABLE IF NOT EXISTS obf_admin.obf_TableSeedOverride (
    TargetSchema VARCHAR(128) NOT NULL,
    TableName    VARCHAR(128) NOT NULL,
    ColumnName   VARCHAR(128) NOT NULL,
    PRIMARY KEY (TargetSchema, TableName)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS obf_admin.obf_UserObfuscationMapping (
    TargetSchema      VARCHAR(128) NOT NULL,
    OriginalUserID    VARCHAR(255) NOT NULL,
    ObfuscatedUserID  VARCHAR(255) NOT NULL,
    CreatedDate       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (TargetSchema, OriginalUserID),
    UNIQUE KEY UK_ObfuscatedUserID (TargetSchema, ObfuscatedUserID)
) ENGINE=InnoDB;

-- Captures FK definitions so they can be dropped and restored exactly.
-- Rows are transient: a row lives only while its constraint is dropped. The
-- orchestrator deletes already-restored rows for this TargetSchema at the
-- start of every run, so this table normally holds nothing for a given
-- target (or, mid-run / after a failure, just that target's currently-
-- dropped constraints).
CREATE TABLE IF NOT EXISTS obf_admin.obf_FkConstraintBackup (
    BackupID              BIGINT AUTO_INCREMENT PRIMARY KEY,
    RunID                 CHAR(36)      NULL,       -- run that dropped this constraint
    TargetSchema          VARCHAR(128)  NOT NULL,
    ConstraintName        VARCHAR(128)  NOT NULL,
    TableName             VARCHAR(128)  NOT NULL,
    ColumnList            VARCHAR(1024) NOT NULL,   -- ordinal-ordered, comma separated
    ReferencedTableName   VARCHAR(128)  NOT NULL,
    ReferencedColumnList  VARCHAR(1024) NOT NULL,
    UpdateRule            VARCHAR(20)   NOT NULL,
    DeleteRule            VARCHAR(20)   NOT NULL,
    DroppedDate           DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    RestoredDate          DATETIME      NULL
) ENGINE=InnoDB;
ALTER TABLE obf_admin.obf_FkConstraintBackup ADD COLUMN IF NOT EXISTS RunID CHAR(36) NULL;

CREATE TABLE IF NOT EXISTS obf_admin.obf_ObfuscationRunLog (
    LogID        BIGINT AUTO_INCREMENT PRIMARY KEY,
    RunID        CHAR(36)     NOT NULL,
    TargetSchema VARCHAR(128) NOT NULL,
    StepName     VARCHAR(100) NOT NULL,
    StepStatus   VARCHAR(20)  NOT NULL,   -- START | OK | SKIP | WARN | ERROR
    Message      VARCHAR(1000) NULL,
    LoggedAt     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- One header row per obf_sp_obfuscate_database() invocation. Because the FK
-- drop/restore steps issue DDL (which implicitly commits in MariaDB) the run
-- is NOT atomic -- a failure part-way leaves the schema partly migrated but
-- fully recoverable by re-running. This table + obf_sp_obfuscation_status()
-- make that state visible instead of silent.
CREATE TABLE IF NOT EXISTS obf_admin.obf_ObfuscationRun (
    RunID       CHAR(36)      NOT NULL PRIMARY KEY,
    TargetSchema VARCHAR(128) NOT NULL,
    Status      VARCHAR(20)   NOT NULL,   -- RUNNING | COMPLETED | FAILED | SUPERSEDED
    Salt        VARCHAR(64)   NULL,       -- kept so a resume run can reuse the same salt
    -- microsecond precision so back-to-back runs order deterministically
    StartedAt   DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    FinishedAt  DATETIME(6)   NULL,
    ErrorSqlState CHAR(5)     NULL,
    ErrorText   VARCHAR(512)  NULL
) ENGINE=InnoDB;
-- Upgrade precision on installs created before DATETIME(6).
ALTER TABLE obf_admin.obf_ObfuscationRun
    MODIFY COLUMN StartedAt  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    MODIFY COLUMN FinishedAt DATETIME(6) NULL;

-- Per-run BEFORE/AFTER row counts for the reconciliation check in
-- obf_sp_validate_obfuscation (no obfuscation step should add or remove rows).
CREATE TABLE IF NOT EXISTS obf_admin.obf_ObfuscationRowCountSnapshot (
    RunID       CHAR(36)     NOT NULL,
    TargetSchema VARCHAR(128) NOT NULL,
    TableName   VARCHAR(128) NOT NULL,
    Phase       VARCHAR(10)  NOT NULL,   -- BEFORE | AFTER
    RowsCounted BIGINT       NOT NULL,
    CapturedAt  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (RunID, TableName, Phase)
) ENGINE=InnoDB;

-- Synthetic seed data (extend freely). GLOBAL / shared across every target
-- schema -- there's no reason to duplicate the name/address pool per target,
-- and sharing gives one place to extend it. SeedID only has to be unique --
-- the obf_fn_synthetic_* pickers select by ORDER BY SeedID + positional
-- offset, so gaps or a non-zero start are fine.
CREATE TABLE IF NOT EXISTS obf_admin.obf_SyntheticFirstName (
    SeedID     INT PRIMARY KEY,
    NameValue  VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS obf_admin.obf_SyntheticLastName (
    SeedID     INT PRIMARY KEY,
    NameValue  VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS obf_admin.obf_SyntheticStreetAddress (
    SeedID        INT PRIMARY KEY,
    AddressValue  VARCHAR(255) NOT NULL
) ENGINE=InnoDB;

-- Minimal seed sets — extend as needed for better distribution.
INSERT IGNORE INTO obf_admin.obf_SyntheticFirstName (SeedID, NameValue) VALUES
 (0,'David'),(1,'Sarah'),(2,'Michael'),(3,'Emma'),(4,'James'),(5,'Olivia'),
 (6,'Daniel'),(7,'Sophie'),(8,'Ryan'),(9,'Grace'),(10,'Thomas'),(11,'Chloe'),
 (12,'Andrew'),(13,'Hannah'),(14,'Matthew'),(15,'Ella'),(16,'Joshua'),(17,'Lily'),
 (18,'Nathan'),(19,'Zoe');

INSERT IGNORE INTO obf_admin.obf_SyntheticLastName (SeedID, NameValue) VALUES
 (0,'Williams'),(1,'Brown'),(2,'Taylor'),(3,'Anderson'),(4,'Clark'),(5,'Mitchell'),
 (6,'Campbell'),(7,'Stewart'),(8,'Morris'),(9,'Rogers'),(10,'Reed'),(11,'Cook'),
 (12,'Bell'),(13,'Murphy'),(14,'Bailey'),(15,'Cooper'),(16,'Richardson'),(17,'Foster'),
 (18,'Hughes'),(19,'Price');

INSERT IGNORE INTO obf_admin.obf_SyntheticStreetAddress (SeedID, AddressValue) VALUES
 (0,'12 Wattle Street'),(1,'45 Banksia Road'),(2,'8 Coral Avenue'),(3,'21 Marigold Lane'),
 (4,'67 Grevillea Court'),(5,'3 Boronia Place'),(6,'19 Acacia Drive'),(7,'55 Hakea Crescent'),
 (8,'27 Melaleuca Way'),(9,'14 Bottlebrush Street');

-- ---------------------------------------------------------------------
-- 1. HELPER FUNCTIONS
-- ---------------------------------------------------------------------

DELIMITER $$

-- Safely backtick-quotes an identifier that ultimately comes only from
-- information_schema / trusted config tables (never from raw user input).
CREATE OR REPLACE FUNCTION obf_admin.obf_fn_quote_identifier(p_identifier VARCHAR(128))
RETURNS VARCHAR(132)
DETERMINISTIC
BEGIN
    RETURN CONCAT('`', REPLACE(p_identifier, '`', '``'), '`');
END$$

-- Builds a fully schema-qualified, backtick-quoted "`schema`.`table`"
-- reference. Every dynamic-SQL statement that touches a TARGET schema table
-- uses this (the target schema is only known at runtime via
-- p_target_schema, so it can only ever appear inside dynamic SQL -- see the
-- architecture note at the top of this file).
CREATE OR REPLACE FUNCTION obf_admin.obf_fn_quote_qualified(p_schema VARCHAR(128), p_table VARCHAR(128))
RETURNS VARCHAR(266)
DETERMINISTIC
BEGIN
    RETURN CONCAT(obf_admin.obf_fn_quote_identifier(p_schema), '.', obf_admin.obf_fn_quote_identifier(p_table));
END$$

-- Deterministic, salted, collision-resistant obfuscated user id generator.
-- dap_User.UserID is NOT an email address -- it's a stripped, local-part-
-- shaped identifier derived from one (e.g. "Wendy.Boyce" for
-- Wendy.Boyce@sa.gov.au), but it still directly names a real person, so it
-- still needs full obfuscation. The replacement mirrors that same
-- "Word.Word" shape (two dot-separated hash segments) with no '@domain'
-- suffix -- the original value never had one either.
-- p_max_len lets the caller fit the result to the real column's
-- character_maximum_length (see obf_sp_create_user_mapping).
CREATE OR REPLACE FUNCTION obf_admin.obf_fn_generate_obfuscated_user_id(
    p_original_user_id  VARCHAR(255),
    p_salt              VARCHAR(64),
    p_attempt           INT,
    p_max_len           INT
)
RETURNS VARCHAR(255)
DETERMINISTIC
BEGIN
    DECLARE v_hash  VARCHAR(64);
    DECLARE v_local VARCHAR(64);
    DECLARE v_split INT;

    -- p_attempt only changes on a mapping-table unique-key collision retry
    -- (astronomically unlikely with SHA-256, but handled rather than assumed away).
    SET v_hash = SHA2(CONCAT(p_salt, '|', LOWER(p_original_user_id), '|', p_attempt), 256);

    IF p_max_len < 9 THEN
        SET p_max_len = 9; -- floor: keeps collision risk sane and leaves room for the '.'
    END IF;

    -- Cap at 33 hex chars of hash (~132 bits of entropy, unchanged from
    -- before) NO MATTER HOW WIDE dap_User.UserID is, then split the result
    -- around a '.' to mirror the real value's "Word.Word" shape.
    -- obf_sp_validate_reference_column_lengths mirrors this same 33-char
    -- (+1 for the '.') ceiling; keep the two in sync if this ever changes.
    SET v_local = LOWER(SUBSTRING(v_hash, 1, LEAST(p_max_len, 33)));
    SET v_split = CEIL(LENGTH(v_local) / 2);

    RETURN CONCAT(LEFT(v_local, v_split), '.', SUBSTRING(v_local, v_split + 1));
END$$

-- Deterministic synthetic FIRST name, keyed by the user's identity (not
-- by the raw name value) so users sharing a real first name don't
-- necessarily collapse onto the same synthetic identity.
CREATE OR REPLACE FUNCTION obf_admin.obf_fn_synthetic_first_name(p_user_key VARCHAR(255))
RETURNS VARCHAR(50)
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_count INT;
    DECLARE v_idx INT;
    DECLARE v_result VARCHAR(50);

    SELECT COUNT(*) INTO v_count FROM obf_admin.obf_SyntheticFirstName;
    IF v_count = 0 THEN
        RETURN 'Person';
    END IF;

    SET v_idx = CRC32(SHA2(CONCAT('fname|', p_user_key), 256)) MOD v_count;
    -- positional pick (0..v_count-1): works for any SeedID values, not just 0..N-1
    SELECT NameValue INTO v_result FROM obf_admin.obf_SyntheticFirstName ORDER BY SeedID LIMIT v_idx, 1;
    RETURN v_result;
END$$

CREATE OR REPLACE FUNCTION obf_admin.obf_fn_synthetic_last_name(p_user_key VARCHAR(255))
RETURNS VARCHAR(50)
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_count INT;
    DECLARE v_idx INT;
    DECLARE v_result VARCHAR(50);

    SELECT COUNT(*) INTO v_count FROM obf_admin.obf_SyntheticLastName;
    IF v_count = 0 THEN
        RETURN 'Surname';
    END IF;

    SET v_idx = CRC32(SHA2(CONCAT('lname|', p_user_key), 256)) MOD v_count;
    SELECT NameValue INTO v_result FROM obf_admin.obf_SyntheticLastName ORDER BY SeedID LIMIT v_idx, 1;
    RETURN v_result;
END$$

CREATE OR REPLACE FUNCTION obf_admin.obf_fn_synthetic_street_address(p_user_key VARCHAR(255))
RETURNS VARCHAR(255)
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_count INT;
    DECLARE v_idx INT;
    DECLARE v_result VARCHAR(255);

    SELECT COUNT(*) INTO v_count FROM obf_admin.obf_SyntheticStreetAddress;
    IF v_count = 0 THEN
        RETURN '1 Example Street';
    END IF;

    SET v_idx = CRC32(SHA2(CONCAT('addr|', p_user_key), 256)) MOD v_count;
    SELECT AddressValue INTO v_result FROM obf_admin.obf_SyntheticStreetAddress ORDER BY SeedID LIMIT v_idx, 1;
    RETURN v_result;
END$$

-- Deterministic synthetic phone number. Fixed Australian-style mobile
-- format shown as an example — adjust the literal pattern for your locale.
CREATE OR REPLACE FUNCTION obf_admin.obf_fn_synthetic_phone(p_user_key VARCHAR(255), p_max_len INT)
RETURNS VARCHAR(50)
DETERMINISTIC
BEGIN
    DECLARE v_hash BIGINT UNSIGNED;
    DECLARE v_digits VARCHAR(20);
    DECLARE v_result VARCHAR(50);

    SET v_hash = CONV(SUBSTRING(SHA2(CONCAT('phone|', p_user_key), 256), 1, 8), 16, 10);
    SET v_digits = LPAD(v_hash MOD 100000000, 8, '0');
    SET v_result = CONCAT('04', v_digits);

    IF p_max_len IS NOT NULL AND p_max_len > 0 AND LENGTH(v_result) > p_max_len THEN
        SET v_result = LEFT(v_result, p_max_len);
    END IF;

    RETURN v_result;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 2. LOGGING HELPER
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_log_step(
    IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36), IN p_step VARCHAR(100),
    IN p_status VARCHAR(20), IN p_message VARCHAR(1000)
)
BEGIN
    INSERT INTO obf_admin.obf_ObfuscationRunLog (RunID, TargetSchema, StepName, StepStatus, Message)
    VALUES (p_run_id, p_target_schema, p_step, p_status, p_message);
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 3. obf_sp_validate_config
--    Sanity-checks obf_ObfuscationConfig against live metadata before
--    anything destructive happens.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_validate_config(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE v_missing INT;
    DECLARE v_fatal INT DEFAULT 0;
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_type VARCHAR(50);
    DECLARE v_index VARCHAR(128);
    DECLARE v_index_cols INT;
    DECLARE v_sql TEXT;

    -- Every enabled configured column that sits inside a UNIQUE index (incl. PK).
    DECLARE cur_uq CURSOR FOR
        SELECT oc.TableName, oc.ColumnName, oc.ObfuscationType, s.INDEX_NAME,
               (SELECT COUNT(*) FROM information_schema.STATISTICS s2
                 WHERE s2.TABLE_SCHEMA = p_target_schema
                   AND s2.TABLE_NAME  = oc.TableName
                   AND s2.INDEX_NAME  = s.INDEX_NAME) AS index_cols
        FROM obf_admin.obf_ObfuscationConfig oc
        JOIN information_schema.STATISTICS s
          ON s.TABLE_SCHEMA = p_target_schema
         AND s.TABLE_NAME   = oc.TableName
         AND s.COLUMN_NAME  = oc.ColumnName
         AND s.NON_UNIQUE   = 0
        WHERE oc.TargetSchema = p_target_schema AND oc.Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- 1. Configured columns that do not exist -- fatal, stop before any mutation.
    SELECT COUNT(*) INTO v_missing
    FROM obf_admin.obf_ObfuscationConfig oc
    LEFT JOIN information_schema.COLUMNS c
        ON c.TABLE_SCHEMA = p_target_schema
       AND c.TABLE_NAME  = oc.TableName
       AND c.COLUMN_NAME = oc.ColumnName
    WHERE oc.TargetSchema = p_target_schema
      AND oc.Enabled = TRUE
      AND c.COLUMN_NAME IS NULL;

    IF v_missing > 0 THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_config', 'ERROR',
            CONCAT(v_missing, ' obf_ObfuscationConfig row(s) reference columns that do not exist in ', p_target_schema, '.'));
        SELECT oc.TableName, oc.ColumnName
        FROM obf_admin.obf_ObfuscationConfig oc
        LEFT JOIN information_schema.COLUMNS c
            ON c.TABLE_SCHEMA = p_target_schema
           AND c.TABLE_NAME  = oc.TableName
           AND c.COLUMN_NAME = oc.ColumnName
        WHERE oc.TargetSchema = p_target_schema AND oc.Enabled = TRUE AND c.COLUMN_NAME IS NULL;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'obf_ObfuscationConfig references non-existent columns. Fix config before proceeding.';
    END IF;

    -- 2. UNIQUE constraints on configured PII columns. Obfuscating into a small
    -- or non-injective value space under a UNIQUE index risks a mid-run
    -- duplicate-key failure. Flag every case (WARN) so it is not attempted
    -- silently; hard-stop the guaranteed failure: STATIC writes one literal to
    -- every row, so on a single-column unique index with >1 row it cannot
    -- succeed.
    OPEN cur_uq;
    uq_loop: LOOP
        FETCH cur_uq INTO v_table, v_column, v_type, v_index, v_index_cols;
        IF done THEN LEAVE uq_loop; END IF;

        IF v_type = 'STATIC' AND v_index_cols = 1 THEN
            SET v_sql = CONCAT('SELECT COUNT(*) INTO @vc_rows2 FROM (SELECT 1 FROM ',
                               obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' LIMIT 2) x');
            SET @sql_stmt = v_sql;
            PREPARE st FROM @sql_stmt; EXECUTE st; DEALLOCATE PREPARE st;

            IF @vc_rows2 >= 2 THEN
                SET v_fatal = v_fatal + 1;
                CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_config', 'ERROR',
                    CONCAT(v_table, '.', v_column, ': ObfuscationType=STATIC writes one literal to every row, but ',
                           'single-column unique index ', v_index, ' forbids duplicates and the table has >1 row. ',
                           'Use HASH, or relax the constraint for this column.'));
            ELSE
                CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_config', 'WARN',
                    CONCAT(v_table, '.', v_column, ' is under unique index ', v_index,
                           ' and typed STATIC (table has <=1 row, so not fatal yet).'));
            END IF;
        ELSE
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_config', 'WARN',
                CONCAT(v_table, '.', v_column, ' is under unique index ', v_index, ' (', v_type,
                       '); obfuscated values must remain unique or the run will fail with a duplicate-key error. ',
                       'Confirm the replacement value space is large enough.'));
        END IF;
    END LOOP;
    CLOSE cur_uq;

    -- Diagnostic result set: every configured column that shares a unique index.
    SELECT oc.TableName, oc.ColumnName, oc.ObfuscationType, s.INDEX_NAME AS UniqueIndex
    FROM obf_admin.obf_ObfuscationConfig oc
    JOIN information_schema.STATISTICS s
      ON s.TABLE_SCHEMA = p_target_schema AND s.TABLE_NAME = oc.TableName
     AND s.COLUMN_NAME = oc.ColumnName AND s.NON_UNIQUE = 0
    WHERE oc.TargetSchema = p_target_schema AND oc.Enabled = TRUE
    ORDER BY oc.TableName, oc.ColumnName, s.INDEX_NAME;

    IF v_fatal > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'obf_ObfuscationConfig has a column whose obfuscation type cannot satisfy a UNIQUE constraint — see obf_ObfuscationRunLog.';
    END IF;

    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_config', 'OK',
        'All configured columns exist; UNIQUE-constraint checks complete.');
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 4. obf_sp_discover_user_references
--    Populates obf_UserReferenceRegistry from FK metadata + naming
--    convention. Re-runnable: refreshes rather than duplicates.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_discover_user_references(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    -- 4a. True foreign keys pointing at dap_User.UserID
    INSERT INTO obf_admin.obf_UserReferenceRegistry (TargetSchema, TableName, ColumnName, DiscoveryMethod, ConstraintName)
    SELECT
        p_target_schema, kcu.TABLE_NAME, kcu.COLUMN_NAME, 'FOREIGN_KEY', kcu.CONSTRAINT_NAME
    FROM information_schema.KEY_COLUMN_USAGE kcu
    WHERE kcu.TABLE_SCHEMA = p_target_schema
      AND kcu.REFERENCED_TABLE_SCHEMA = p_target_schema
      AND kcu.REFERENCED_TABLE_NAME = 'dap_User'
      AND kcu.REFERENCED_COLUMN_NAME = 'UserID'
    ON DUPLICATE KEY UPDATE
        DiscoveryMethod = 'FOREIGN_KEY',
        ConstraintName  = VALUES(ConstraintName),
        Enabled = TRUE;

    -- 4b. Naming-convention columns (CreatedBy, ModifiedBy, etc.) that are
    -- NOT already captured as an FK above — these are value copies, not
    -- enforced relationships, so they need a separate discovery path.
    INSERT INTO obf_admin.obf_UserReferenceRegistry (TargetSchema, TableName, ColumnName, DiscoveryMethod, ConstraintName)
    SELECT
        p_target_schema, cc.TABLE_NAME, cc.COLUMN_NAME, 'NAMING_CONVENTION', NULL
    FROM information_schema.COLUMNS cc
    JOIN information_schema.TABLES tt
        ON tt.TABLE_SCHEMA = cc.TABLE_SCHEMA AND tt.TABLE_NAME = cc.TABLE_NAME
    WHERE cc.TABLE_SCHEMA = p_target_schema
      AND tt.TABLE_TYPE = 'BASE TABLE'
      AND cc.COLUMN_NAME IN ('CreatedBy','CreatedUser','CreatedUserID','ModifiedBy','ModifiedUserID')
      AND NOT EXISTS (
          SELECT 1 FROM obf_admin.obf_UserReferenceRegistry r
          WHERE r.TargetSchema = p_target_schema AND r.TableName = cc.TABLE_NAME AND r.ColumnName = cc.COLUMN_NAME
      )
    ON DUPLICATE KEY UPDATE Enabled = TRUE;

    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_discover_user_references', 'OK',
        (SELECT CONCAT(COUNT(*), ' user-reference column(s) registered.')
         FROM obf_admin.obf_UserReferenceRegistry WHERE TargetSchema = p_target_schema AND Enabled = TRUE));

    -- 4c. Type-compatibility check. dap_User.UserID is assumed string-typed (it
    -- holds a stripped, email-derived identifier, per the script header). A
    -- registered reference column
    -- that is numeric/temporal almost certainly is NOT a UserID copy —
    -- obfuscating it would corrupt it. Flag (WARN); the DBA should set
    -- Enabled=FALSE for any false positive, or fix the schema/discovery.
    SET @dbobf_userid_type = (
        SELECT DATA_TYPE FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = p_target_schema AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID'
    );
    IF EXISTS (
        SELECT 1
        FROM obf_admin.obf_UserReferenceRegistry r
        JOIN information_schema.COLUMNS c
          ON c.TABLE_SCHEMA = p_target_schema AND c.TABLE_NAME = r.TableName AND c.COLUMN_NAME = r.ColumnName
        WHERE r.TargetSchema = p_target_schema AND r.Enabled = TRUE
          AND @dbobf_userid_type IN ('varchar','char','text','tinytext','mediumtext','longtext')
          AND c.DATA_TYPE NOT IN ('varchar','char','text','tinytext','mediumtext','longtext','enum','set')
    ) THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_discover_user_references', 'WARN',
            'One or more registered user-reference columns are not string-typed like dap_User.UserID — review the diagnostic result set and set Enabled=FALSE for any that are not UserID copies.');
    END IF;

    -- Diagnostic result set for a human to eyeball before destructive steps run.
    SELECT r.RegistryID, r.TableName, r.ColumnName, r.DiscoveryMethod, r.ConstraintName,
           r.OrphanAction, c.DATA_TYPE AS ColumnDataType,
           (c.DATA_TYPE IN ('varchar','char','text','tinytext','mediumtext','longtext','enum','set')
            OR @dbobf_userid_type NOT IN ('varchar','char','text','tinytext','mediumtext','longtext')) AS TypeLooksCompatible
    FROM obf_admin.obf_UserReferenceRegistry r
    LEFT JOIN information_schema.COLUMNS c
      ON c.TABLE_SCHEMA = p_target_schema AND c.TABLE_NAME = r.TableName AND c.COLUMN_NAME = r.ColumnName
    WHERE r.TargetSchema = p_target_schema AND r.Enabled = TRUE
    ORDER BY r.DiscoveryMethod, r.TableName, r.ColumnName;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 4d. obf_sp_validate_reference_column_lengths
--     obf_sp_obfuscate_user_references writes the SAME obfuscated user id
--     value into every registered reference column that it writes into
--     dap_User.UserID (no per-column truncation -- truncating differently
--     per column would let two different users' obfuscated ids collide on
--     a narrow column). That value's max length is dictated by
--     dap_User.UserID's own column width (see
--     obf_fn_generate_obfuscated_user_id / obf_sp_create_user_mapping). A
--     narrower reference column can't hold it and the UPDATE fails with
--     "Data too long for column" -- but only after
--     obf_sp_drop_user_fk_constraints has already run. Catch it here,
--     right after discovery and before any destructive step.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_validate_reference_column_lengths(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE v_userid_len INT;
    DECLARE v_local_len INT;
    DECLARE v_required_len INT;
    DECLARE v_fatal INT DEFAULT 0;

    SELECT CHARACTER_MAXIMUM_LENGTH INTO v_userid_len
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = p_target_schema AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID';

    IF v_userid_len IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'dap_User.UserID column not found.';
    END IF;

    -- Same formula as obf_sp_create_user_mapping / obf_fn_generate_obfuscated_user_id,
    -- including that function's 33-char hash ceiling (-> 34 chars total with
    -- the '.' separator, regardless of how wide dap_User.UserID itself is).
    -- Keep in sync with it.
    SET v_local_len = GREATEST(v_userid_len - 1, 8);
    SET v_required_len = LEAST(v_local_len, 33) + 1;

    DROP TEMPORARY TABLE IF EXISTS obf_RefColumnLengthReport;
    CREATE TEMPORARY TABLE obf_RefColumnLengthReport (
        TableName      VARCHAR(128),
        ColumnName     VARCHAR(128),
        ColumnLength   INT,
        RequiredLength INT
    );

    INSERT INTO obf_RefColumnLengthReport (TableName, ColumnName, ColumnLength, RequiredLength)
    SELECT r.TableName, r.ColumnName, c.CHARACTER_MAXIMUM_LENGTH, v_required_len
    FROM obf_admin.obf_UserReferenceRegistry r
    JOIN information_schema.COLUMNS c
      ON c.TABLE_SCHEMA = p_target_schema AND c.TABLE_NAME = r.TableName AND c.COLUMN_NAME = r.ColumnName
    WHERE r.TargetSchema = p_target_schema AND r.Enabled = TRUE
      AND c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL
      AND c.CHARACTER_MAXIMUM_LENGTH < v_required_len;

    SET v_fatal = (SELECT COUNT(*) FROM obf_RefColumnLengthReport);

    IF v_fatal > 0 THEN
        INSERT INTO obf_admin.obf_ObfuscationRunLog (RunID, TargetSchema, StepName, StepStatus, Message)
        SELECT p_run_id, p_target_schema, 'obf_sp_validate_reference_column_lengths', 'ERROR',
               CONCAT(TableName, '.', ColumnName, ' is VARCHAR(', ColumnLength,
                      ') but the obfuscated user id needs up to ', RequiredLength,
                      ' characters -- widen the column, set Enabled=FALSE for it, ',
                      'or use a narrower dap_User.UserID before running.')
        FROM obf_RefColumnLengthReport;

        SELECT * FROM obf_RefColumnLengthReport ORDER BY TableName, ColumnName;

        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'One or more user-reference columns are too narrow to hold the obfuscated user id -- see obf_ObfuscationRunLog.';
    END IF;

    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_reference_column_lengths', 'OK',
        CONCAT('All registered reference columns can hold up to ', v_required_len, ' characters.'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 5. obf_sp_create_user_mapping
--    Builds obf_UserObfuscationMapping deterministically. Idempotent:
--    only inserts users not already mapped. dap_User lives in the TARGET
--    schema, so every statement touching it is built as dynamic SQL,
--    schema-qualified via obf_fn_quote_qualified(p_target_schema, 'dap_User').
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_create_user_mapping(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36), IN p_salt VARCHAR(64))
BEGIN
    DECLARE v_col_len INT;
    DECLARE v_local_len INT;
    DECLARE v_remaining INT DEFAULT 0;
    DECLARE v_dup_exists INT DEFAULT 0;
    DECLARE v_sql TEXT;
    DECLARE v_target_tbl VARCHAR(266);
    DECLARE v_mapping_where TEXT;

    -- Fit the generated value to the real column length instead of assuming one.
    SELECT CHARACTER_MAXIMUM_LENGTH INTO v_col_len
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = p_target_schema AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID';

    IF v_col_len IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'dap_User.UserID column not found.';
    END IF;

    -- reserve 1 char for the '.' separator between the two hash segments
    SET v_local_len = GREATEST(v_col_len - 1, 8);
    SET v_target_tbl = obf_admin.obf_fn_quote_qualified(p_target_schema, 'dap_User');

    -- OriginalUserID is stored LOWER()-cased so downstream reference joins can be
    -- collation-agnostic (m.OriginalUserID = LOWER(t.<col>)) without depending on
    -- the schema's default collation. That only works as a 1:1 mapping if no two
    -- dap_User rows differ solely by UserID letter case -- a case-insensitive PK
    -- forbids it, but a *_bin / *_cs collation would not, and merging two real
    -- users is worse than a hard stop.
    SET v_sql = CONCAT(
        'SELECT COUNT(*) INTO @vc_dup_exists FROM (',
          'SELECT LOWER(UserID) lu FROM ', v_target_tbl,
          ' WHERE UserID IS NOT NULL GROUP BY lu HAVING COUNT(*) > 1',
        ') d'
    );
    SET @sql_stmt = v_sql;
    PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    SET v_dup_exists = @vc_dup_exists;

    IF v_dup_exists > 0 THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_create_user_mapping', 'ERROR',
            'dap_User has rows that differ only by UserID letter case; a 1:1 obfuscation mapping is impossible. Resolve the duplicates first.');
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'dap_User.UserID has case-only duplicate values.';
    END IF;

    -- Insert mapping for any user not yet mapped.
    --
    -- IDEMPOTENCY NOTE: on a re-run, dap_User.UserID may already HOLD an
    -- obfuscated value from a prior run (this same procedure updates it
    -- later in the orchestration). Without the extra "NOT IN (...
    -- ObfuscatedUserID)" guard below, a second run would treat that
    -- already-obfuscated value as a brand-new "original" value and
    -- re-hash it into yet another value every time it's run -- silently
    -- breaking idempotency and drifting the mapping further from the
    -- true original on every re-run. The guard makes a value that's
    -- already someone's ObfuscatedUserID ineligible to be treated as a
    -- new OriginalUserID.
    --
    -- COLLISION NOTE: this is INSERT IGNORE, not plain INSERT. If an
    -- attempt-0 ObfuscatedUserID would violate UK_ObfuscatedUserID --
    -- either against a pre-existing mapping row or against another
    -- dap_User row hashing to the same value in this very batch -- that
    -- row is silently skipped here and left unmapped, then picked up by
    -- the escalating-attempt retry loop below (attempt 1..5). A plain
    -- INSERT would instead abort the whole procedure on the first such
    -- collision, making the retry loop unreachable.
    SET v_mapping_where = CONCAT(
        'FROM ', v_target_tbl, ' u ',
        'LEFT JOIN obf_admin.obf_UserObfuscationMapping m ',
          'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.OriginalUserID = CONVERT(LOWER(u.UserID) USING utf8mb4) COLLATE utf8mb4_general_ci ',
        'WHERE m.OriginalUserID IS NULL AND u.UserID IS NOT NULL ',
        '  AND CONVERT(u.UserID USING utf8mb4) COLLATE utf8mb4_general_ci NOT IN (SELECT ObfuscatedUserID FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = ', QUOTE(p_target_schema), ')'
    );

    SET v_sql = CONCAT(
        'INSERT IGNORE INTO obf_admin.obf_UserObfuscationMapping (TargetSchema, OriginalUserID, ObfuscatedUserID, CreatedDate) ',
        'SELECT ', QUOTE(p_target_schema), ', LOWER(u.UserID), ',
               'obf_admin.obf_fn_generate_obfuscated_user_id(u.UserID, ', QUOTE(p_salt), ', 0, ', v_local_len, '), NOW() ',
        v_mapping_where
    );
    SET @sql_stmt = v_sql;
    PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;

    -- Collision handling: if the unique key on ObfuscatedUserID was violated
    -- for any of the just-attempted rows, they simply won't be present yet.
    -- Retry loop, escalating the attempt counter, capped to avoid infinite loop.
    SET v_sql = CONCAT('SELECT COUNT(*) INTO @vc_remaining ', v_mapping_where);
    SET @sql_stmt = v_sql;
    PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    SET v_remaining = @vc_remaining;

    retry_loop: BEGIN
        DECLARE v_attempt INT DEFAULT 1;
        WHILE v_remaining > 0 AND v_attempt <= 5 DO
            SET v_sql = CONCAT(
                'INSERT IGNORE INTO obf_admin.obf_UserObfuscationMapping (TargetSchema, OriginalUserID, ObfuscatedUserID, CreatedDate) ',
                'SELECT ', QUOTE(p_target_schema), ', LOWER(u.UserID), ',
                       'obf_admin.obf_fn_generate_obfuscated_user_id(u.UserID, ', QUOTE(p_salt), ', ', v_attempt, ', ', v_local_len, '), NOW() ',
                v_mapping_where
            );
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;

            SET v_sql = CONCAT('SELECT COUNT(*) INTO @vc_remaining ', v_mapping_where);
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
            SET v_remaining = @vc_remaining;
            SET v_attempt = v_attempt + 1;
        END WHILE;
    END retry_loop;

    IF v_remaining > 0 THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_create_user_mapping', 'ERROR',
            CONCAT(v_remaining, ' user(s) could not be mapped after retries — investigate collisions.'));
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User mapping incomplete after collision retries.';
    ELSE
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_create_user_mapping', 'OK',
            (SELECT CONCAT(COUNT(*), ' users mapped.')
             FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = p_target_schema));
    END IF;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 5b. Orphan user-reference handling
--     A user-reference value that matches no dap_User.UserID never gets a
--     mapping row, so obf_sp_obfuscate_user_references would silently leave
--     the ORIGINAL value in place — a PII leak, and one the old post-run
--     check could only flag *after* everything was already committed.
--     FK-discovered columns cannot have these (the constraint forbids it);
--     NAMING_CONVENTION / MANUAL columns routinely do (ex-staff, 'SYSTEM'
--     sentinels, legacy bad data).
--
--     obf_sp_report_orphan_user_references  — pre-flight, read-only. Emits
--         every offending (table, column, value) so a DBA can eyeball it
--         BEFORE any destructive step and, if needed, set
--         obf_UserReferenceRegistry.OrphanAction.
--     obf_sp_resolve_orphan_user_references — acts per column's
--         OrphanAction: OBFUSCATE (default) synthesises a mapping row for
--         each stray value so it is rewritten like any other reference;
--         NULLIFY sets them NULL; IGNORE leaves them and tells
--         obf_sp_validate_obfuscation not to flag them.
--     Both run after the mapping is built (so real users are already
--     mapped and only genuine strays remain) and before FK drop.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_report_orphan_user_references(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_action VARCHAR(10);
    DECLARE v_sql TEXT;
    DECLARE v_actionable BIGINT DEFAULT 0;

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName, OrphanAction
        FROM obf_admin.obf_UserReferenceRegistry WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    DROP TEMPORARY TABLE IF EXISTS obf_OrphanUserRefReport;
    CREATE TEMPORARY TABLE obf_OrphanUserRefReport (
        TableName        VARCHAR(128),
        ColumnName       VARCHAR(128),
        OrphanAction     VARCHAR(10),
        OrphanValue      VARCHAR(255),
        RowsWithValue    BIGINT
    );

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_table, v_column, v_action;
        IF done THEN LEAVE read_loop; END IF;

        -- A "stray": non-NULL, not an OriginalUserID we are about to map, and
        -- not already an ObfuscatedUserID (so re-runs don't re-report handled
        -- values).
        SET v_sql = CONCAT(
            'INSERT INTO obf_OrphanUserRefReport ',
            'SELECT ', QUOTE(v_table), ', ', QUOTE(v_column), ', ', QUOTE(v_action), ', ',
                   't.', obf_admin.obf_fn_quote_identifier(v_column), ', COUNT(*) ',
            'FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t ',
            'LEFT JOIN obf_admin.obf_UserObfuscationMapping mo ',
              'ON mo.TargetSchema = ', QUOTE(p_target_schema), ' AND mo.OriginalUserID   = CONVERT(LOWER(t.', obf_admin.obf_fn_quote_identifier(v_column), ') USING utf8mb4) COLLATE utf8mb4_general_ci ',
            'LEFT JOIN obf_admin.obf_UserObfuscationMapping mx ',
              'ON mx.TargetSchema = ', QUOTE(p_target_schema), ' AND mx.ObfuscatedUserID = CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci ',
            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
            '  AND mo.OriginalUserID IS NULL ',
            '  AND mx.ObfuscatedUserID IS NULL ',
            'GROUP BY t.', obf_admin.obf_fn_quote_identifier(v_column));
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END LOOP;
    CLOSE cur;

    SET v_actionable = (SELECT IFNULL(SUM(RowsWithValue), 0)
                        FROM obf_OrphanUserRefReport WHERE OrphanAction <> 'IGNORE');

    IF v_actionable > 0 THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_report_orphan_user_references', 'WARN',
            CONCAT(v_actionable, ' row(s) across ',
                   (SELECT COUNT(DISTINCT CONCAT(TableName, '.', ColumnName))
                    FROM obf_OrphanUserRefReport WHERE OrphanAction <> 'IGNORE'),
                   ' column(s) hold a user-reference value with no dap_User match; they will be handled per OrphanAction. Review the diagnostic result set.'));
    ELSE
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_report_orphan_user_references', 'OK',
            'No unhandled orphan user-reference values.');
    END IF;

    SELECT * FROM obf_OrphanUserRefReport ORDER BY TableName, ColumnName, OrphanValue;
END$$
DELIMITER ;

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_resolve_orphan_user_references(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36), IN p_salt VARCHAR(64))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_action VARCHAR(10);
    DECLARE v_col_len INT;
    DECLARE v_local_len INT;
    DECLARE v_sql TEXT;
    DECLARE v_remaining BIGINT;
    DECLARE v_attempt INT;
    DECLARE v_affected BIGINT;

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName, OrphanAction
        FROM obf_admin.obf_UserReferenceRegistry WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- SET (subquery) not SELECT..INTO: yields NULL on no match instead of
    -- raising NOT FOUND (which the cursor's handler above would also catch).
    SET v_col_len = (
        SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = p_target_schema AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID'
    );
    IF v_col_len IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'dap_User.UserID column not found.';
    END IF;
    SET v_local_len = GREATEST(v_col_len - 1, 8);

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_table, v_column, v_action;
        IF done THEN LEAVE read_loop; END IF;

        IF v_action = 'IGNORE' THEN
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_resolve_orphan_user_references', 'SKIP',
                CONCAT(v_table, '.', v_column, ' — OrphanAction=IGNORE; unmatched values left as-is.'));
            ITERATE read_loop;
        END IF;

        IF v_action = 'NULLIFY' THEN
            SET v_affected = 1;
            WHILE v_affected > 0 DO
                SET v_sql = CONCAT(
                    'UPDATE ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t ',
                    'SET t.', obf_admin.obf_fn_quote_identifier(v_column), ' = NULL ',
                    'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                    '  AND CONVERT(LOWER(t.', obf_admin.obf_fn_quote_identifier(v_column), ') USING utf8mb4) COLLATE utf8mb4_general_ci NOT IN ',
                         '(SELECT OriginalUserID FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = ', QUOTE(p_target_schema), ') ',
                    '  AND CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci NOT IN ',
                         '(SELECT ObfuscatedUserID FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = ', QUOTE(p_target_schema), ') ',
                    'LIMIT 50000');
                SET @sql_stmt = v_sql;
                PREPARE stmt FROM @sql_stmt; EXECUTE stmt;
                SET v_affected = ROW_COUNT(); DEALLOCATE PREPARE stmt;
            END WHILE;
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_resolve_orphan_user_references', 'OK',
                CONCAT(v_table, '.', v_column, ' — unmatched values set to NULL.'));
            ITERATE read_loop;
        END IF;

        -- Default: OBFUSCATE. Synthesise a mapping row for every stray value so
        -- obf_sp_obfuscate_user_references rewrites it. Same escalating-attempt
        -- collision handling as obf_sp_create_user_mapping.
        SET v_attempt = 0;
        SET v_remaining = 1;
        WHILE v_remaining > 0 AND v_attempt <= 5 DO
            SET v_sql = CONCAT(
                'INSERT IGNORE INTO obf_admin.obf_UserObfuscationMapping (TargetSchema, OriginalUserID, ObfuscatedUserID, CreatedDate) ',
                'SELECT DISTINCT ', QUOTE(p_target_schema), ', LOWER(t.', obf_admin.obf_fn_quote_identifier(v_column), '), ',
                       'obf_admin.obf_fn_generate_obfuscated_user_id(t.', obf_admin.obf_fn_quote_identifier(v_column), ', ',
                            QUOTE(p_salt), ', ', v_attempt, ', ', v_local_len, '), NOW() ',
                'FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t ',
                'LEFT JOIN obf_admin.obf_UserObfuscationMapping m ',
                  'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.OriginalUserID = CONVERT(LOWER(t.', obf_admin.obf_fn_quote_identifier(v_column), ') USING utf8mb4) COLLATE utf8mb4_general_ci ',
                'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                '  AND m.OriginalUserID IS NULL ',
                '  AND CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci NOT IN ',
                     '(SELECT ObfuscatedUserID FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = ', QUOTE(p_target_schema), ')');
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;

            SET v_sql = CONCAT(
                'SELECT COUNT(*) INTO @orphan_remaining FROM (',
                  'SELECT DISTINCT t.', obf_admin.obf_fn_quote_identifier(v_column), ' AS v ',
                  'FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t ',
                  'LEFT JOIN obf_admin.obf_UserObfuscationMapping m ',
                    'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.OriginalUserID = CONVERT(LOWER(t.', obf_admin.obf_fn_quote_identifier(v_column), ') USING utf8mb4) COLLATE utf8mb4_general_ci ',
                  'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                  '  AND m.OriginalUserID IS NULL ',
                  '  AND CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci NOT IN ',
                       '(SELECT ObfuscatedUserID FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = ', QUOTE(p_target_schema), ')',
                ') d');
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
            SET v_remaining = @orphan_remaining;
            SET v_attempt = v_attempt + 1;
        END WHILE;

        IF v_remaining > 0 THEN
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_resolve_orphan_user_references', 'ERROR',
                CONCAT(v_table, '.', v_column, ' — ', v_remaining,
                       ' orphan value(s) unmapped after collision retries.'));
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Orphan user-reference mapping incomplete after collision retries.';
        ELSE
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_resolve_orphan_user_references', 'OK',
                CONCAT(v_table, '.', v_column, ' — unmatched values mapped for obfuscation.'));
        END IF;
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 6. FK management: drop constraints referencing dap_User.UserID,
--    capturing exact definitions, then restore them later.
--    This is the alternative to SET FOREIGN_KEY_CHECKS=0 — restoring
--    the constraint re-validates every row and fails loudly if broken.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_drop_user_fk_constraints(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_constraint VARCHAR(128);
    DECLARE v_table VARCHAR(128);
    DECLARE v_cols VARCHAR(1024);
    DECLARE v_ref_table VARCHAR(128);
    DECLARE v_ref_cols VARCHAR(1024);
    DECLARE v_update_rule VARCHAR(20);
    DECLARE v_delete_rule VARCHAR(20);
    DECLARE v_sql TEXT;

    DECLARE cur CURSOR FOR
        SELECT
            rc.CONSTRAINT_NAME, rc.TABLE_NAME,
            GROUP_CONCAT(kcu.COLUMN_NAME ORDER BY kcu.ORDINAL_POSITION),
            rc.REFERENCED_TABLE_NAME,
            GROUP_CONCAT(kcu.REFERENCED_COLUMN_NAME ORDER BY kcu.ORDINAL_POSITION),
            rc.UPDATE_RULE, rc.DELETE_RULE
        FROM information_schema.REFERENTIAL_CONSTRAINTS rc
        JOIN information_schema.KEY_COLUMN_USAGE kcu
            ON kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
           AND kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
           AND kcu.TABLE_NAME = rc.TABLE_NAME
        WHERE rc.CONSTRAINT_SCHEMA = p_target_schema
          AND rc.REFERENCED_TABLE_NAME = 'dap_User'
        GROUP BY rc.CONSTRAINT_NAME, rc.TABLE_NAME, rc.REFERENCED_TABLE_NAME, rc.UPDATE_RULE, rc.DELETE_RULE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_constraint, v_table, v_cols, v_ref_table, v_ref_cols, v_update_rule, v_delete_rule;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Skip if already backed up and not yet restored (re-run safety)
        IF NOT EXISTS (
            SELECT 1 FROM obf_admin.obf_FkConstraintBackup
            WHERE TargetSchema = p_target_schema AND ConstraintName = v_constraint AND TableName = v_table AND RestoredDate IS NULL
        ) THEN
            INSERT INTO obf_admin.obf_FkConstraintBackup
                (RunID, TargetSchema, ConstraintName, TableName, ColumnList, ReferencedTableName, ReferencedColumnList, UpdateRule, DeleteRule)
            VALUES
                (p_run_id, p_target_schema, v_constraint, v_table, v_cols, v_ref_table, v_ref_cols, v_update_rule, v_delete_rule);
        END IF;

        SET v_sql = CONCAT('ALTER TABLE ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table),
                            ' DROP FOREIGN KEY ', obf_admin.obf_fn_quote_identifier(v_constraint));
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;

        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_drop_user_fk_constraints', 'OK',
            CONCAT('Dropped ', v_constraint, ' on ', v_table));
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_restore_user_fk_constraints(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_id BIGINT;
    DECLARE v_constraint VARCHAR(128);
    DECLARE v_table VARCHAR(128);
    DECLARE v_cols VARCHAR(1024);
    DECLARE v_ref_table VARCHAR(128);
    DECLARE v_ref_cols VARCHAR(1024);
    DECLARE v_update_rule VARCHAR(20);
    DECLARE v_delete_rule VARCHAR(20);
    DECLARE v_sql TEXT;

    DECLARE cur CURSOR FOR
        SELECT BackupID, ConstraintName, TableName, ColumnList, ReferencedTableName, ReferencedColumnList, UpdateRule, DeleteRule
        FROM obf_admin.obf_FkConstraintBackup
        WHERE TargetSchema = p_target_schema AND RestoredDate IS NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id, v_constraint, v_table, v_cols, v_ref_table, v_ref_cols, v_update_rule, v_delete_rule;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Rebuild "col1`,`col2" style quoted lists from the stored CSV.
        SET v_sql = CONCAT(
            'ALTER TABLE ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table),
            ' ADD CONSTRAINT ', obf_admin.obf_fn_quote_identifier(v_constraint),
            ' FOREIGN KEY (`', REPLACE(v_cols, ',', '`,`'), '`)',
            ' REFERENCES ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_ref_table),
            ' (`', REPLACE(v_ref_cols, ',', '`,`'), '`)',
            ' ON UPDATE ', v_update_rule,
            ' ON DELETE ', v_delete_rule
        );

        -- This ALTER will fail with a real, actionable error if any row
        -- would violate the constraint — i.e. it doubles as a referential
        -- integrity validation step.
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;

        UPDATE obf_admin.obf_FkConstraintBackup SET RestoredDate = NOW() WHERE BackupID = v_id;

        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_restore_user_fk_constraints', 'OK',
            CONCAT('Restored ', v_constraint, ' on ', v_table));
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 7. obf_sp_obfuscate_user_references
--    Updates every column registered in obf_UserReferenceRegistry to its
--    mapped obfuscated value. Batched to avoid huge single transactions.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_obfuscate_user_references(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36), IN p_batch_size INT)
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_sql TEXT;
    DECLARE v_rows_affected BIGINT;

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName FROM obf_admin.obf_UserReferenceRegistry
        WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    IF p_batch_size IS NULL OR p_batch_size <= 0 THEN
        SET p_batch_size = 50000;
    END IF;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_table, v_column;
        IF done THEN
            LEAVE read_loop;
        END IF;

        SET v_rows_affected = 1;
        WHILE v_rows_affected > 0 DO
            -- NOTE: LIMIT on a multi-table UPDATE is MariaDB-only (10.3+). MySQL
            -- rejects it -- do not port this batching pattern to MySQL as-is.
            SET v_sql = CONCAT(
                'UPDATE ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t ',
                'JOIN obf_admin.obf_UserObfuscationMapping m ',
                  'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.OriginalUserID = CONVERT(LOWER(t.', obf_admin.obf_fn_quote_identifier(v_column), ') USING utf8mb4) COLLATE utf8mb4_general_ci ',
                'SET t.', obf_admin.obf_fn_quote_identifier(v_column), ' = m.ObfuscatedUserID ',
                'WHERE CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci <> m.ObfuscatedUserID ',
                'LIMIT ', p_batch_size
            );
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt;
            EXECUTE stmt;
            SET v_rows_affected = ROW_COUNT();
            DEALLOCATE PREPARE stmt;
        END WHILE;

        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_obfuscate_user_references', 'OK',
            CONCAT(v_table, '.', v_column, ' updated.'));
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 8. obf_sp_obfuscate_user_table
--    Updates dap_User.UserID itself from the mapping. Run only after
--    FKs referencing it have been dropped (see orchestrator). dap_User
--    lives in the target schema, so this is dynamic SQL.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_obfuscate_user_table(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE v_sql TEXT;
    DECLARE v_rows_affected BIGINT;

    SET v_sql = CONCAT(
        'UPDATE ', obf_admin.obf_fn_quote_qualified(p_target_schema, 'dap_User'), ' u ',
        'JOIN obf_admin.obf_UserObfuscationMapping m ',
          'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.OriginalUserID = CONVERT(LOWER(u.UserID) USING utf8mb4) COLLATE utf8mb4_general_ci ',
        'SET u.UserID = m.ObfuscatedUserID ',
        'WHERE CONVERT(u.UserID USING utf8mb4) COLLATE utf8mb4_general_ci <> m.ObfuscatedUserID'
    );
    SET @sql_stmt = v_sql;
    PREPARE stmt FROM @sql_stmt;
    EXECUTE stmt;
    SET v_rows_affected = ROW_COUNT();
    DEALLOCATE PREPARE stmt;

    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_obfuscate_user_table', 'OK',
        CONCAT(v_rows_affected, ' dap_User row(s) updated.'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 9. obf_sp_obfuscate_configured_columns
--    Dynamic dispatch over obf_ObfuscationConfig. Each PII column is joined
--    back to dap_User via the same user-reference chain so replacement
--    values are keyed off the OWNING USER, not the raw string value —
--    satisfying "John Smith / John Brown / John Taylor" independence.
--
--    Assumption: every table carrying PII columns also carries a
--    UserID-typed column (itself, or via obf_UserReferenceRegistry) that
--    identifies the owning user, used as the deterministic seed. If a
--    table has no such column, its own PRIMARY KEY is used as the seed
--    instead (still deterministic, just not shared across tables); if it
--    has no PRIMARY KEY either, a column registered in
--    obf_TableSeedOverride is used as a last resort. A table matching none
--    of the three is SKIPped (its configured columns are left untouched).
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_obfuscate_configured_columns(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36), IN p_batch_size INT, IN p_salt VARCHAR(64))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_type VARCHAR(50);
    DECLARE v_static VARCHAR(255);
    DECLARE v_pk_col VARCHAR(128);
    DECLARE v_col_len INT;
    DECLARE v_sql TEXT;
    DECLARE v_rows_affected BIGINT;
    DECLARE v_seed_expr VARCHAR(256);
    DECLARE v_qualified_table VARCHAR(266);

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName, ObfuscationType, StaticValue
        FROM obf_admin.obf_ObfuscationConfig WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    IF p_batch_size IS NULL OR p_batch_size <= 0 THEN
        SET p_batch_size = 50000;
    END IF;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_table, v_column, v_type, v_static;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Determine a deterministic per-row seed: prefer a user-reference
        -- column on the same table if one is registered, else fall back
        -- to the table's own primary key column, else a registered
        -- obf_TableSeedOverride.
        --
        -- NOTE: these use SET (subquery) rather than SELECT ... INTO on
        -- purpose. A SELECT ... INTO that matches zero rows raises a
        -- NOT FOUND condition, and the CONTINUE HANDLER FOR NOT FOUND
        -- declared above for the cursor would catch THAT too (handlers
        -- are scoped to the whole block, not just the cursor's FETCH),
        -- silently ending the outer loop after the first "not found"
        -- lookup. SET (subquery) simply yields NULL on no match instead.
        -- When a table has more than one registered user-reference column
        -- (e.g. its own "UserID"/owner column AND an audit column like
        -- "CreatedBy"), prefer an FK-discovered column over a
        -- naming-convention one. An FK column typically represents "this
        -- row IS/belongs to this user"; a CreatedBy/ModifiedBy column
        -- only records who acted on it. Seeding PII off the wrong one
        -- would incorrectly collapse different row-owners who merely
        -- share a creator onto the same synthetic identity.
        SET v_pk_col = (
            SELECT ColumnName FROM obf_admin.obf_UserReferenceRegistry
            WHERE TargetSchema = p_target_schema AND TableName = v_table AND Enabled = TRUE
            ORDER BY (DiscoveryMethod = 'FOREIGN_KEY') DESC, ColumnName
            LIMIT 1
        );

        IF v_pk_col IS NULL THEN
            SET v_pk_col = (
                SELECT kcu.COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE kcu
                JOIN information_schema.TABLE_CONSTRAINTS tc
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE kcu.TABLE_SCHEMA = p_target_schema AND kcu.TABLE_NAME = v_table
                  AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                LIMIT 1
            );
        END IF;

        -- Last resort: a DBA-registered manual seed column.
        IF v_pk_col IS NULL THEN
            SET v_pk_col = (
                SELECT ColumnName FROM obf_admin.obf_TableSeedOverride
                WHERE TargetSchema = p_target_schema AND TableName = v_table
            );
        END IF;

        IF v_pk_col IS NULL THEN
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_obfuscate_configured_columns', 'SKIP',
                CONCAT('No usable seed column (user reference, PK, or obf_TableSeedOverride) found for ', v_table, '.', v_column));
        ELSE
            SET v_col_len = (
                SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = p_target_schema AND TABLE_NAME = v_table AND COLUMN_NAME = v_column
            );

            SET v_qualified_table = obf_admin.obf_fn_quote_qualified(p_target_schema, v_table);
            SET v_seed_expr = CONCAT('t.', obf_admin.obf_fn_quote_identifier(v_pk_col));

            SET v_rows_affected = 1;
            WHILE v_rows_affected > 0 DO
                CASE v_type
                    WHEN 'FIRST_NAME' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = obf_admin.obf_fn_synthetic_first_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> obf_admin.obf_fn_synthetic_first_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'LIMIT ', p_batch_size);

                    WHEN 'LAST_NAME' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = obf_admin.obf_fn_synthetic_last_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> obf_admin.obf_fn_synthetic_last_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'LIMIT ', p_batch_size);

                    WHEN 'PHONE' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = obf_admin.obf_fn_synthetic_phone(CAST(', v_seed_expr, ' AS CHAR), ', IFNULL(v_col_len, 20), ') ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> obf_admin.obf_fn_synthetic_phone(CAST(', v_seed_expr, ' AS CHAR), ', IFNULL(v_col_len, 20), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'ADDRESS' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = LEFT(obf_admin.obf_fn_synthetic_street_address(CAST(', v_seed_expr, ' AS CHAR)), ', IFNULL(v_col_len, 255), ') ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> LEFT(obf_admin.obf_fn_synthetic_street_address(CAST(', v_seed_expr, ' AS CHAR)), ', IFNULL(v_col_len, 255), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'EMAIL' THEN
                        -- Secondary email columns (not the primary UserID). Deterministic,
                        -- keyed off the row's stable seed + salt via a HASH of the seed --
                        -- never the raw seed value, so we never emit
                        -- "user<an-already-obfuscated-email>@example.invalid". The
                        -- "<> target" guard (not a NOT LIKE) keeps it idempotent even if
                        -- the column is too narrow to hold the full '@example.invalid'.
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = LEFT(CONCAT(''user_'', LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), 16), ''@example.invalid''), ', IFNULL(v_col_len, 254), ') ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> LEFT(CONCAT(''user_'', LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), 16), ''@example.invalid''), ', IFNULL(v_col_len, 254), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'HASH' THEN
                        -- One-way pseudonymisation, keyed off the row's STABLE seed
                        -- (its owning user-reference column, or its PK) plus the run
                        -- salt -- deliberately NOT off the column's own value.
                        --
                        -- Hashing the live column value was unsafe here: this block
                        -- runs inside "WHILE v_rows_affected > 0", and SHA2(current
                        -- value) changes the value on every pass, so ROW_COUNT() never
                        -- reaches 0 and the loop spins forever. Seeding off a value
                        -- that this procedure never mutates makes the target
                        -- deterministic, so the "<> target" guard below turns the
                        -- second pass into a genuine no-op, and re-running the whole
                        -- orchestrator is idempotent.
                        --
                        -- Trade-off: two rows with equal original values only hash
                        -- alike if they also share a seed. For per-user columns
                        -- (the common case) that is exactly right; if you need
                        -- equal-value -> equal-hash on a non-user column, hash it via
                        -- a dedicated column pair instead of this type.
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), ', IFNULL(v_col_len, 64), ') ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), ', IFNULL(v_col_len, 64), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'STATIC' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', v_qualified_table, ' t SET t.', obf_admin.obf_fn_quote_identifier(v_column),
                            ' = ', QUOTE(LEFT(IFNULL(v_static, ''), IFNULL(v_col_len, 255))), ' ',
                            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', obf_admin.obf_fn_quote_identifier(v_column), ' <> ', QUOTE(LEFT(IFNULL(v_static, ''), IFNULL(v_col_len, 255))), ' ',
                            'LIMIT ', p_batch_size);

                    ELSE
                        SET v_sql = NULL;
                END CASE;

                IF v_sql IS NULL THEN
                    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_obfuscate_configured_columns', 'SKIP',
                        CONCAT('Unknown ObfuscationType "', v_type, '" for ', v_table, '.', v_column));
                    SET v_rows_affected = 0;
                ELSE
                    SET @sql_stmt = v_sql;
                    PREPARE stmt FROM @sql_stmt;
                    EXECUTE stmt;
                    SET v_rows_affected = ROW_COUNT();
                    DEALLOCATE PREPARE stmt;
                END IF;
            END WHILE;

            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_obfuscate_configured_columns', 'OK',
                CONCAT(v_table, '.', v_column, ' (', v_type, ') processed.'));
        END IF;

        SET v_pk_col = NULL; -- reset for next loop iteration
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 9b. obf_sp_snapshot_row_counts
--     Records COUNT(*) for dap_User and every table named in
--     obf_ObfuscationConfig / obf_UserReferenceRegistry for this target
--     schema, tagged BEFORE or AFTER, so obf_sp_validate_obfuscation can
--     prove the process neither added nor removed rows. Re-runnable
--     (upserts on RunID+TableName+Phase).
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_snapshot_row_counts(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36), IN p_phase VARCHAR(10))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_sql TEXT;

    DECLARE cur CURSOR FOR
        SELECT 'dap_User' AS t
        UNION SELECT DISTINCT TableName FROM obf_admin.obf_ObfuscationConfig     WHERE TargetSchema = p_target_schema AND Enabled = TRUE
        UNION SELECT DISTINCT TableName FROM obf_admin.obf_UserReferenceRegistry WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    rc_loop: LOOP
        FETCH cur INTO v_table;
        IF done THEN LEAVE rc_loop; END IF;

        IF EXISTS (SELECT 1 FROM information_schema.TABLES
                   WHERE TABLE_SCHEMA = p_target_schema AND TABLE_NAME = v_table) THEN
            SET v_sql = CONCAT(
                'INSERT INTO obf_admin.obf_ObfuscationRowCountSnapshot (RunID, TargetSchema, TableName, Phase, RowsCounted) ',
                'SELECT ', QUOTE(p_run_id), ', ', QUOTE(p_target_schema), ', ', QUOTE(v_table), ', ', QUOTE(p_phase), ', COUNT(*) FROM ',
                obf_admin.obf_fn_quote_qualified(p_target_schema, v_table),
                ' ON DUPLICATE KEY UPDATE RowsCounted = VALUES(RowsCounted), CapturedAt = NOW()');
            SET @sql_stmt = v_sql;
            PREPARE st FROM @sql_stmt; EXECUTE st; DEALLOCATE PREPARE st;
        END IF;
    END LOOP;
    CLOSE cur;

    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_snapshot_row_counts', 'OK',
        CONCAT(p_phase, ' row-count snapshot captured for ',
               (SELECT COUNT(*) FROM obf_admin.obf_ObfuscationRowCountSnapshot
                WHERE RunID = p_run_id AND TargetSchema = p_target_schema AND Phase = p_phase),
               ' table(s).'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 10. obf_sp_validate_obfuscation
--     Post-run checks:
--       10a  orphaned user-reference values (excl. OrphanAction=IGNORE)
--       10b  row-count reconciliation vs the BEFORE snapshot
--       10c  residual-PII spot checks (heuristic)
--       10d  overall status — SIGNAL 45000 if any of the above failed
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_validate_obfuscation(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE v_unmapped_refs BIGINT DEFAULT 0;
    DECLARE v_rc_mismatch   BIGINT DEFAULT 0;
    DECLARE v_residual      BIGINT DEFAULT 0;
    DECLARE done  INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_action VARCHAR(10);
    DECLARE v_type VARCHAR(50);
    DECLARE v_sql TEXT;
    DECLARE v_cnt BIGINT;

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName, OrphanAction FROM obf_admin.obf_UserReferenceRegistry
        WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE cur_cfg CURSOR FOR
        SELECT TableName, ColumnName, ObfuscationType FROM obf_admin.obf_ObfuscationConfig
        WHERE TargetSchema = p_target_schema AND Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- 10a. After a clean run every user-reference value must be either NULL or a
    -- known ObfuscatedUserID. Strays were reported pre-flight and handled by
    -- obf_sp_resolve_orphan_user_references, so a hit here means THIS run left
    -- something inconsistent — a bug, or an interrupted/partial run — not merely
    -- pre-existing bad data. Columns a DBA set to OrphanAction='IGNORE' are a
    -- deliberate exception and are skipped.
    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_table, v_column, v_action;
        IF done THEN
            LEAVE read_loop;
        END IF;

        IF v_action = 'IGNORE' THEN
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'SKIP',
                CONCAT(v_table, '.', v_column, ' — OrphanAction=IGNORE, not checked for unmatched values.'));
            ITERATE read_loop;
        END IF;

        SET v_sql = CONCAT(
            'SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t ',
            'LEFT JOIN obf_admin.obf_UserObfuscationMapping m ',
              'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.ObfuscatedUserID = CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci ',
            'WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL AND m.ObfuscatedUserID IS NULL'
        );
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
        SET v_cnt = @cnt;

        IF v_cnt > 0 THEN
            SET v_unmapped_refs = v_unmapped_refs + v_cnt;
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'ERROR',
                CONCAT(v_cnt, ' row(s) in ', v_table, '.', v_column,
                       ' still hold a value that is not a known obfuscated user.'));
        END IF;
    END LOOP;
    CLOSE cur;

    -- 10b. Row-count reconciliation. No obfuscation step should add or remove
    -- rows; a mismatch means a trigger or a bug did. Compares the AFTER counts
    -- to the BEFORE snapshot obf_sp_obfuscate_database took right after discovery.
    -- Skipped (not failed) when called standalone with a RunID that has no
    -- BEFORE snapshot.
    IF EXISTS (SELECT 1 FROM obf_admin.obf_ObfuscationRowCountSnapshot WHERE RunID = p_run_id AND TargetSchema = p_target_schema AND Phase = 'BEFORE') THEN
        CALL obf_admin.obf_sp_snapshot_row_counts(p_target_schema, p_run_id, 'AFTER');

        SELECT COUNT(*) INTO v_rc_mismatch
        FROM obf_admin.obf_ObfuscationRowCountSnapshot b
        JOIN obf_admin.obf_ObfuscationRowCountSnapshot a
          ON a.RunID = b.RunID AND a.TableName = b.TableName AND a.Phase = 'AFTER'
        WHERE b.RunID = p_run_id AND b.TargetSchema = p_target_schema AND b.Phase = 'BEFORE'
          AND a.RowsCounted <> b.RowsCounted;

        IF v_rc_mismatch > 0 THEN
            INSERT INTO obf_admin.obf_ObfuscationRunLog (RunID, TargetSchema, StepName, StepStatus, Message)
            SELECT p_run_id, p_target_schema, 'obf_sp_validate_obfuscation', 'ERROR',
                   CONCAT('Row count changed: ', b.TableName,
                          ' before=', b.RowsCounted, ' after=', a.RowsCounted)
            FROM obf_admin.obf_ObfuscationRowCountSnapshot b
            JOIN obf_admin.obf_ObfuscationRowCountSnapshot a
              ON a.RunID = b.RunID AND a.TableName = b.TableName AND a.Phase = 'AFTER'
            WHERE b.RunID = p_run_id AND b.TargetSchema = p_target_schema AND b.Phase = 'BEFORE'
              AND a.RowsCounted <> b.RowsCounted;
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'ERROR',
                CONCAT(v_rc_mismatch, ' table(s) changed row count during obfuscation.'));
        ELSE
            CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'OK',
                'Row-count reconciliation passed (no table gained or lost rows).');
        END IF;
    ELSE
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'SKIP',
            'Row-count reconciliation skipped — no BEFORE snapshot for this RunID (standalone call?).');
    END IF;

    -- 10c. Residual-PII spot checks. Heuristic, not exhaustive: catches values
    -- that plainly did not get obfuscated (a dap_User.UserID that isn't a
    -- known ObfuscatedUserID; a configured EMAIL column without the
    -- @example.invalid marker; a name/address not drawn from the Synthetic*
    -- pool; a phone not in the generator's 04######## shape). It cannot detect
    -- a residual value that happens to coincide with an obfuscated one, and it
    -- says nothing about STATIC/HASH columns (no fixed shape to test).
    --
    -- dap_User.UserID is checked against the mapping table itself, not a
    -- string pattern -- unlike a configured EMAIL column, its obfuscated
    -- form (see obf_fn_generate_obfuscated_user_id) has no fixed marker like
    -- '@example.invalid' to match against, since the original value never
    -- had a domain either.
    SET v_sql = CONCAT(
        'SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, 'dap_User'), ' t ',
        'LEFT JOIN obf_admin.obf_UserObfuscationMapping m ',
          'ON m.TargetSchema = ', QUOTE(p_target_schema), ' AND m.ObfuscatedUserID = CONVERT(t.UserID USING utf8mb4) COLLATE utf8mb4_general_ci ',
        'WHERE t.UserID IS NOT NULL AND m.ObfuscatedUserID IS NULL'
    );
    SET @sql_stmt = v_sql;
    PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    IF @cnt > 0 THEN
        SET v_residual = v_residual + @cnt;
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'ERROR',
            CONCAT(@cnt, ' dap_User.UserID value(s) are not a known obfuscated user id.'));
    END IF;

    SET done = 0;
    OPEN cur_cfg;
    rp_loop: LOOP
        FETCH cur_cfg INTO v_table, v_column, v_type;
        IF done THEN LEAVE rp_loop; END IF;

        SET v_sql = NULL;
        CASE v_type
            WHEN 'EMAIL' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table),
                    ' WHERE ', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL AND ',
                    obf_admin.obf_fn_quote_identifier(v_column), ' NOT LIKE ''%@example.invalid''');
            WHEN 'FIRST_NAME' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t',
                    ' WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL AND NOT EXISTS (',
                    'SELECT 1 FROM obf_admin.obf_SyntheticFirstName s WHERE s.NameValue = CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci)');
            WHEN 'LAST_NAME' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t',
                    ' WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL AND NOT EXISTS (',
                    'SELECT 1 FROM obf_admin.obf_SyntheticLastName s WHERE s.NameValue = CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci)');
            WHEN 'ADDRESS' THEN
                -- ADDRESS is LEFT(synthetic, col_len), so match on equality OR prefix.
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table), ' t',
                    ' WHERE t.', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL AND NOT EXISTS (',
                    'SELECT 1 FROM obf_admin.obf_SyntheticStreetAddress s WHERE s.AddressValue = CONVERT(t.', obf_admin.obf_fn_quote_identifier(v_column), ' USING utf8mb4) COLLATE utf8mb4_general_ci',
                    ' OR s.AddressValue LIKE CONVERT(CONCAT(t.', obf_admin.obf_fn_quote_identifier(v_column), ', ''%'') USING utf8mb4) COLLATE utf8mb4_general_ci)');
            WHEN 'PHONE' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', obf_admin.obf_fn_quote_qualified(p_target_schema, v_table),
                    ' WHERE ', obf_admin.obf_fn_quote_identifier(v_column), ' IS NOT NULL AND ',
                    obf_admin.obf_fn_quote_identifier(v_column), ' NOT REGEXP ''^04[0-9]{1,8}$''');
            ELSE
                SET v_sql = NULL;  -- STATIC / HASH: nothing reliable to assert
        END CASE;

        IF v_sql IS NOT NULL THEN
            SET @cnt = 0;
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
            IF @cnt > 0 THEN
                SET v_residual = v_residual + @cnt;
                CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'ERROR',
                    CONCAT(@cnt, ' value(s) in ', v_table, '.', v_column, ' (', v_type,
                           ') are not in the obfuscated form — possible residual PII.'));
            END IF;
        END IF;
    END LOOP;
    CLOSE cur_cfg;

    IF v_residual = 0 THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'OK',
            'Residual-PII spot checks passed (heuristic).');
    END IF;

    -- 10d. Overall status
    IF v_unmapped_refs > 0 OR v_rc_mismatch > 0 OR v_residual > 0 THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'ERROR',
            CONCAT('Post-run validation FAILED — orphaned refs: ', v_unmapped_refs,
                   ', row-count mismatches: ', v_rc_mismatch,
                   ', residual-PII hits: ', v_residual, '. ',
                   'The refresh did not complete cleanly — fix the cause and re-run obf_sp_obfuscate_database (it resumes).'));
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Post-run validation failed — see obf_ObfuscationRunLog for the offending table.column(s).';
    ELSE
        CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_validate_obfuscation', 'OK', 'Validation passed.');
    END IF;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 11. obf_sp_purge_sensitive_staging
--     Optional cleanup: strips real PII (OriginalUserID) out of the
--     mapping table once obfuscation is validated. Only call this once
--     you're sure no further delta-sync re-run against production is
--     planned for this refresh cycle — see design doc §C.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_purge_sensitive_staging(IN p_target_schema VARCHAR(128), IN p_run_id CHAR(36))
BEGIN
    DECLARE v_rows_affected BIGINT;

    UPDATE obf_admin.obf_UserObfuscationMapping
    SET OriginalUserID = CONCAT('purged-', ObfuscatedUserID)
    WHERE TargetSchema = p_target_schema AND OriginalUserID NOT LIKE 'purged-%';
    -- Note: OriginalUserID is part of the primary key, so it can't be set to
    -- NULL; overwriting with a non-reversible placeholder achieves the same
    -- goal while keeping the table's row identity stable.
    SET v_rows_affected = ROW_COUNT();

    CALL obf_admin.obf_sp_log_step(p_target_schema, p_run_id, 'obf_sp_purge_sensitive_staging', 'OK',
        CONCAT(v_rows_affected, ' mapping row(s) purged of original PII.'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 11b. obf_sp_obfuscation_status
--      Read-only. Run this BEFORE (re-)running obf_sp_obfuscate_database to
--      see whether a target schema is mid-migration: last run outcome, any
--      FK constraints currently dropped, whether the mapping still holds PII.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_obfuscation_status(IN p_target_schema VARCHAR(128))
BEGIN
    SELECT RunID, Status, Salt, StartedAt, FinishedAt, ErrorSqlState, ErrorText
    FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema ORDER BY StartedAt DESC LIMIT 5;

    -- Non-empty => a prior run stopped between FK drop and FK restore.
    SELECT ConstraintName, TableName, ReferencedTableName, DroppedDate
    FROM obf_admin.obf_FkConstraintBackup
    WHERE TargetSchema = p_target_schema AND RestoredDate IS NULL
    ORDER BY DroppedDate, TableName, ConstraintName;

    SELECT
        (SELECT Status FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema ORDER BY StartedAt DESC LIMIT 1)                    AS LastRunStatus,
        (SELECT COUNT(*) FROM obf_admin.obf_FkConstraintBackup WHERE TargetSchema = p_target_schema AND RestoredDate IS NULL)                      AS FkConstraintsCurrentlyDropped,
        (SELECT COUNT(*) FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema = p_target_schema AND OriginalUserID NOT LIKE 'purged-%')    AS MappingRowsHoldingOriginalPII,
        CASE
            WHEN (SELECT COUNT(*) FROM obf_admin.obf_FkConstraintBackup WHERE TargetSchema = p_target_schema AND RestoredDate IS NULL) > 0
                THEN 'HALF-MIGRATED: FK constraints are currently dropped. Re-run obf_sp_obfuscate_database() with the SAME salt to finish.'
            WHEN (SELECT Status FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema ORDER BY StartedAt DESC LIMIT 1) = 'RUNNING'
                THEN 'A run is in progress, or one died without recording an outcome. Re-run to resume.'
            WHEN (SELECT Status FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema ORDER BY StartedAt DESC LIMIT 1) = 'FAILED'
                THEN 'Last run FAILED (see ErrorText). Fix the cause and re-run with the same salt; it resumes.'
            WHEN (SELECT Status FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema ORDER BY StartedAt DESC LIMIT 1) = 'COMPLETED'
                THEN 'Last run COMPLETED cleanly. Safe to open the environment.'
            ELSE 'No obfuscation run has been recorded yet.'
        END AS Assessment;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 11c. obf_sp_obfuscation_prune
--      Optional housekeeping, DBA-invoked. Keeps the most recent
--      p_keep_runs runs' worth of run/log/snapshot history FOR THIS
--      TARGET SCHEMA and drops anything older. Never touches another
--      target's history, a RUNNING run, or an un-restored
--      obf_FkConstraintBackup row. (The orchestrator already discards
--      restored FK backups every run, so obf_FkConstraintBackup does not
--      grow on its own.)
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_obfuscation_prune(IN p_target_schema VARCHAR(128), IN p_keep_runs INT)
BEGIN
    DECLARE v_keep INT;

    IF p_keep_runs IS NULL OR p_keep_runs < 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'obf_sp_obfuscation_prune: p_keep_runs must be >= 1.';
    END IF;
    SET v_keep = p_keep_runs;

    -- Keep the newest v_keep finished runs for this target; drop the rest.
    -- (Prune by RunID set, not by timestamp -- DATETIME is second-precision
    -- and several runs can share a second.)
    DELETE FROM obf_admin.obf_ObfuscationRun
     WHERE TargetSchema = p_target_schema
       AND Status <> 'RUNNING'
       AND RunID NOT IN (
           SELECT RunID FROM (
               SELECT RunID FROM obf_admin.obf_ObfuscationRun
               WHERE TargetSchema = p_target_schema
               ORDER BY StartedAt DESC, RunID DESC
               LIMIT v_keep
           ) keep
       );

    -- Drop child rows that no longer belong to a known run for this target.
    -- This also clears log/snapshot rows from standalone sub-procedure calls
    -- (e.g. CALL obf_sp_validate_obfuscation(p_target_schema, UUID())) that
    -- never had a header row.
    DELETE FROM obf_admin.obf_ObfuscationRunLog
     WHERE TargetSchema = p_target_schema
       AND RunID NOT IN (SELECT RunID FROM obf_admin.obf_ObfuscationRun);
    DELETE FROM obf_admin.obf_ObfuscationRowCountSnapshot
     WHERE TargetSchema = p_target_schema
       AND RunID NOT IN (SELECT RunID FROM obf_admin.obf_ObfuscationRun);
    DELETE FROM obf_admin.obf_FkConstraintBackup
     WHERE TargetSchema = p_target_schema
       AND RestoredDate IS NOT NULL
       AND (RunID IS NULL OR RunID NOT IN (SELECT RunID FROM obf_admin.obf_ObfuscationRun));

    SELECT CONCAT('Kept the newest ', p_keep_runs, ' run(s) for ', p_target_schema, '; ',
                  (SELECT COUNT(*) FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema),
                  ' run row(s) remain.') AS Result;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 12. obf_sp_obfuscate_database
--     Master orchestrator. Single entry point.
--     p_target_schema : the application schema to obfuscate (this admin
--                     schema's own state is fully isolated per target —
--                     see the architecture note at the top of this file)
--     p_salt        : a secret, run-specific salt (rotate per environment refresh;
--                     a RESUME run must reuse the interrupted run's salt)
--     p_batch_size  : batching for large-table UPDATEs (default 50000)
--     p_purge_after : TRUE to strip OriginalUserID after successful validation
--
--     NOT atomic, by design. obf_sp_drop_user_fk_constraints /
--     obf_sp_restore_user_fk_constraints issue DDL (implicit COMMIT in
--     MariaDB), and the large UPDATEs commit in batches on purpose so they
--     don't hold locks for hours (see design doc, "Large tables /
--     long-running transactions"). A failure therefore leaves the target
--     schema PARTLY migrated -- but every step is idempotent and dropped
--     FKs are recorded in obf_FkConstraintBackup, so re-running with the
--     SAME salt (against the SAME target schema) finishes the job.
--     obf_sp_obfuscation_status(p_target_schema) reports whether a target
--     schema is mid-migration.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE obf_admin.obf_sp_obfuscate_database(
    IN p_target_schema VARCHAR(128),
    IN p_salt VARCHAR(64),
    IN p_batch_size INT,
    IN p_purge_after BOOLEAN
)
BEGIN
    DECLARE v_run_id CHAR(36) DEFAULT UUID();
    DECLARE v_dangling_fk INT DEFAULT 0;
    DECLARE v_prev_status VARCHAR(20);

    -- On any error: record the outcome (so obf_sp_obfuscation_status can
    -- report it and a resume run knows what happened), then re-raise. The
    -- schema is not rolled back -- see the header note -- so the message
    -- points at the resume path rather than claiming a clean abort.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DECLARE v_sqlstate CHAR(5) DEFAULT '00000';
        DECLARE v_msg VARCHAR(512) DEFAULT '';
        GET DIAGNOSTICS CONDITION 1 v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        UPDATE obf_admin.obf_ObfuscationRun
           SET Status = 'FAILED', FinishedAt = NOW(),
               ErrorSqlState = v_sqlstate, ErrorText = LEFT(v_msg, 512)
         WHERE RunID = v_run_id;
        CALL obf_admin.obf_sp_log_step(p_target_schema, v_run_id, 'obf_sp_obfuscate_database', 'ERROR',
            CONCAT('Run FAILED (', v_sqlstate, '): ', LEFT(v_msg, 380),
                   ' -- schema may be partly migrated; fix the cause and re-run with the SAME salt to resume.'));
        RESIGNAL;
    END;

    -- Pre-flight run-state, scoped to THIS target schema only -- another
    -- target's genuinely-running job must never be touched. Retire any
    -- prior run for this target that never recorded an outcome (hard
    -- crash / killed connection), then note if we are resuming.
    UPDATE obf_admin.obf_ObfuscationRun SET Status = 'SUPERSEDED', FinishedAt = NOW()
     WHERE TargetSchema = p_target_schema AND Status = 'RUNNING';
    -- Discard spent FK backups for this target (constraint already back on
    -- the table -- the row is redundant with information_schema).
    -- Un-restored rows are the resume signal and are kept.
    DELETE FROM obf_admin.obf_FkConstraintBackup WHERE TargetSchema = p_target_schema AND RestoredDate IS NOT NULL;
    SET v_dangling_fk = (SELECT COUNT(*) FROM obf_admin.obf_FkConstraintBackup WHERE TargetSchema = p_target_schema AND RestoredDate IS NULL);
    SET v_prev_status = (SELECT Status FROM obf_admin.obf_ObfuscationRun WHERE TargetSchema = p_target_schema ORDER BY StartedAt DESC LIMIT 1);

    INSERT INTO obf_admin.obf_ObfuscationRun (RunID, TargetSchema, Status, Salt) VALUES (v_run_id, p_target_schema, 'RUNNING', p_salt);
    CALL obf_admin.obf_sp_log_step(p_target_schema, v_run_id, 'obf_sp_obfuscate_database', 'START', CONCAT('Run started, RunID=', v_run_id));

    IF v_dangling_fk > 0 OR v_prev_status IN ('FAILED', 'SUPERSEDED') THEN
        CALL obf_admin.obf_sp_log_step(p_target_schema, v_run_id, 'obf_sp_obfuscate_database', 'WARN',
            CONCAT('Resuming after an interrupted/failed run (previous status: ', IFNULL(v_prev_status, '?'),
                   '; FK constraints currently dropped: ', v_dangling_fk,
                   '). Every step is idempotent; the salt MUST match the interrupted run. See obf_sp_obfuscation_status().'));
    END IF;

    CALL obf_admin.obf_sp_validate_config(p_target_schema, v_run_id);
    CALL obf_admin.obf_sp_discover_user_references(p_target_schema, v_run_id);
    CALL obf_admin.obf_sp_validate_reference_column_lengths(p_target_schema, v_run_id);

    -- BEFORE row-count snapshot (registry + config tables are known now).
    -- obf_sp_validate_obfuscation compares AFTER counts against this.
    CALL obf_admin.obf_sp_snapshot_row_counts(p_target_schema, v_run_id, 'BEFORE');

    CALL obf_admin.obf_sp_create_user_mapping(p_target_schema, v_run_id, p_salt);

    -- Pre-flight: surface (don't yet touch) any user-reference value that has
    -- no dap_User match, so it can be eyeballed before destructive steps.
    CALL obf_admin.obf_sp_report_orphan_user_references(p_target_schema, v_run_id);
    -- Act on those values per each column's obf_UserReferenceRegistry.OrphanAction
    -- (OBFUSCATE | NULLIFY | IGNORE). Runs before FK drop so mapped values are
    -- then rewritten by obf_sp_obfuscate_user_references like any other reference.
    CALL obf_admin.obf_sp_resolve_orphan_user_references(p_target_schema, v_run_id, p_salt);

    CALL obf_admin.obf_sp_drop_user_fk_constraints(p_target_schema, v_run_id);
    CALL obf_admin.obf_sp_obfuscate_user_references(p_target_schema, v_run_id, p_batch_size);
    CALL obf_admin.obf_sp_obfuscate_user_table(p_target_schema, v_run_id);
    CALL obf_admin.obf_sp_restore_user_fk_constraints(p_target_schema, v_run_id); -- re-validates FKs as a side effect

    CALL obf_admin.obf_sp_obfuscate_configured_columns(p_target_schema, v_run_id, p_batch_size, p_salt);

    CALL obf_admin.obf_sp_validate_obfuscation(p_target_schema, v_run_id);

    IF p_purge_after THEN
        CALL obf_admin.obf_sp_purge_sensitive_staging(p_target_schema, v_run_id);
    END IF;

    UPDATE obf_admin.obf_ObfuscationRun SET Status = 'COMPLETED', FinishedAt = NOW() WHERE RunID = v_run_id;
    CALL obf_admin.obf_sp_log_step(p_target_schema, v_run_id, 'obf_sp_obfuscate_database', 'OK', 'Run completed successfully.');

    SELECT v_run_id AS RunID;
END$$
DELIMITER ;

-- =====================================================================
-- Example configuration inserts (adjust to your real column inventory)
-- =====================================================================
-- INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType) VALUES
--   ('appiandev2', 'dap_User',  'FirstName',    'FIRST_NAME'),
--   ('appiandev2', 'dap_User',  'LastName',     'LAST_NAME'),
--   ('appiandev2', 'dap_User',  'PhoneNumber',  'PHONE'),
--   ('appiandev2', 'dap_User',  'Address',      'ADDRESS'),
--   ('appiandev2', 'dap_Actor', 'FirstName',    'FIRST_NAME'),
--   ('appiandev2', 'dap_Actor', 'LastName',     'LAST_NAME'),
--   ('appiandev2', 'dap_Actor', 'PhoneNumber',  'PHONE'),
--   ('appiandev2', 'dap_Actor', 'Address',      'ADDRESS');

-- =====================================================================
-- Example execution
-- =====================================================================
-- CALL obf_admin.obf_sp_obfuscate_database('appiandev2', 'CHANGE-THIS-SECRET-SALT-PER-ENVIRONMENT', 50000, FALSE);
-- SELECT * FROM obf_admin.obf_ObfuscationRunLog WHERE TargetSchema = 'appiandev2' ORDER BY LogID;
