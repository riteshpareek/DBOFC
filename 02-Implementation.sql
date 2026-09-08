-- =====================================================================
-- Database-Side Data Obfuscation Framework
-- Target: MariaDB
-- Assumes: this script runs against the LOWER-ENVIRONMENT COPY only,
--          after the production->lower copy has completed.
-- Assumes: dap_User.UserID *is* the email address (per spec section 1).
--          Adjust column names below if your actual schema differs.
-- =====================================================================

-- Run this against the target schema, e.g.:
--   USE Appian;

-- ---------------------------------------------------------------------
-- 0. CONFIGURATION SCHEMA
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ObfuscationConfig (
    ConfigID          BIGINT AUTO_INCREMENT PRIMARY KEY,
    TableName         VARCHAR(128) NOT NULL,
    ColumnName        VARCHAR(128) NOT NULL,
    ObfuscationType   VARCHAR(50)  NOT NULL,   -- FIRST_NAME | LAST_NAME | PHONE | ADDRESS | EMAIL | STATIC | HASH
    StaticValue       VARCHAR(255) NULL,       -- used when ObfuscationType = STATIC
    Enabled           BOOLEAN      NOT NULL DEFAULT TRUE,
    UNIQUE KEY UK_ObfuscationConfig (TableName, ColumnName)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS UserReferenceRegistry (
    RegistryID        BIGINT AUTO_INCREMENT PRIMARY KEY,
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
    UNIQUE KEY UK_UserReferenceRegistry (TableName, ColumnName)
) ENGINE=InnoDB;

-- For installs created before OrphanAction existed.
ALTER TABLE UserReferenceRegistry
    ADD COLUMN IF NOT EXISTS OrphanAction VARCHAR(10) NOT NULL DEFAULT 'OBFUSCATE';

CREATE TABLE IF NOT EXISTS UserObfuscationMapping (
    OriginalUserID    VARCHAR(255) NOT NULL,
    ObfuscatedUserID  VARCHAR(255) NOT NULL,
    CreatedDate       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (OriginalUserID),
    UNIQUE KEY UK_ObfuscatedUserID (ObfuscatedUserID)
) ENGINE=InnoDB;

-- Captures FK definitions so they can be dropped and restored exactly.
-- Rows are transient: a row lives only while its constraint is dropped. The
-- orchestrator deletes already-restored rows at the start of every run, so this
-- table normally holds nothing (or, mid-run / after a failure, just the
-- currently-dropped constraints).
CREATE TABLE IF NOT EXISTS FkConstraintBackup (
    BackupID              BIGINT AUTO_INCREMENT PRIMARY KEY,
    RunID                 CHAR(36)      NULL,       -- run that dropped this constraint
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
ALTER TABLE FkConstraintBackup ADD COLUMN IF NOT EXISTS RunID CHAR(36) NULL;

CREATE TABLE IF NOT EXISTS ObfuscationRunLog (
    LogID        BIGINT AUTO_INCREMENT PRIMARY KEY,
    RunID        CHAR(36)     NOT NULL,
    StepName     VARCHAR(100) NOT NULL,
    StepStatus   VARCHAR(20)  NOT NULL,   -- START | OK | SKIP | WARN | ERROR
    Message      VARCHAR(1000) NULL,
    LoggedAt     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- One header row per sp_obfuscate_database() invocation. Because the FK
-- drop/restore steps issue DDL (which implicitly commits in MariaDB) the run
-- is NOT atomic — a failure part-way leaves the schema partly migrated but
-- fully recoverable by re-running. This table + sp_obfuscation_status() make
-- that state visible instead of silent.
CREATE TABLE IF NOT EXISTS ObfuscationRun (
    RunID       CHAR(36)      NOT NULL PRIMARY KEY,
    Status      VARCHAR(20)   NOT NULL,   -- RUNNING | COMPLETED | FAILED | SUPERSEDED
    Salt        VARCHAR(64)   NULL,       -- kept so a resume run can reuse the same salt
    -- microsecond precision so back-to-back runs order deterministically
    StartedAt   DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    FinishedAt  DATETIME(6)   NULL,
    ErrorSqlState CHAR(5)     NULL,
    ErrorText   VARCHAR(512)  NULL
) ENGINE=InnoDB;
-- Upgrade precision on installs created before DATETIME(6).
ALTER TABLE ObfuscationRun
    MODIFY COLUMN StartedAt  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    MODIFY COLUMN FinishedAt DATETIME(6) NULL;

-- Per-run BEFORE/AFTER row counts for the reconciliation check in
-- sp_validate_obfuscation (no obfuscation step should add or remove rows).
CREATE TABLE IF NOT EXISTS ObfuscationRowCountSnapshot (
    RunID       CHAR(36)     NOT NULL,
    TableName   VARCHAR(128) NOT NULL,
    Phase       VARCHAR(10)  NOT NULL,   -- BEFORE | AFTER
    RowsCounted BIGINT       NOT NULL,
    CapturedAt  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (RunID, TableName, Phase)
) ENGINE=InnoDB;

-- Synthetic seed data (extend freely). SeedID only has to be unique — the
-- fn_synthetic_* pickers select by ORDER BY SeedID + positional offset, so
-- gaps or a non-zero start are fine.
CREATE TABLE IF NOT EXISTS SyntheticFirstName (
    SeedID     INT PRIMARY KEY,
    NameValue  VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS SyntheticLastName (
    SeedID     INT PRIMARY KEY,
    NameValue  VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS SyntheticStreetAddress (
    SeedID        INT PRIMARY KEY,
    AddressValue  VARCHAR(255) NOT NULL
) ENGINE=InnoDB;

-- Minimal seed sets — extend as needed for better distribution.
INSERT IGNORE INTO SyntheticFirstName (SeedID, NameValue) VALUES
 (0,'David'),(1,'Sarah'),(2,'Michael'),(3,'Emma'),(4,'James'),(5,'Olivia'),
 (6,'Daniel'),(7,'Sophie'),(8,'Ryan'),(9,'Grace'),(10,'Thomas'),(11,'Chloe'),
 (12,'Andrew'),(13,'Hannah'),(14,'Matthew'),(15,'Ella'),(16,'Joshua'),(17,'Lily'),
 (18,'Nathan'),(19,'Zoe');

INSERT IGNORE INTO SyntheticLastName (SeedID, NameValue) VALUES
 (0,'Williams'),(1,'Brown'),(2,'Taylor'),(3,'Anderson'),(4,'Clark'),(5,'Mitchell'),
 (6,'Campbell'),(7,'Stewart'),(8,'Morris'),(9,'Rogers'),(10,'Reed'),(11,'Cook'),
 (12,'Bell'),(13,'Murphy'),(14,'Bailey'),(15,'Cooper'),(16,'Richardson'),(17,'Foster'),
 (18,'Hughes'),(19,'Price');

INSERT IGNORE INTO SyntheticStreetAddress (SeedID, AddressValue) VALUES
 (0,'12 Wattle Street'),(1,'45 Banksia Road'),(2,'8 Coral Avenue'),(3,'21 Marigold Lane'),
 (4,'67 Grevillea Court'),(5,'3 Boronia Place'),(6,'19 Acacia Drive'),(7,'55 Hakea Crescent'),
 (8,'27 Melaleuca Way'),(9,'14 Bottlebrush Street');

-- ---------------------------------------------------------------------
-- 1. HELPER FUNCTIONS
-- ---------------------------------------------------------------------

DELIMITER $$

-- Safely backtick-quotes an identifier that ultimately comes only from
-- information_schema / trusted config tables (never from raw user input).
CREATE OR REPLACE FUNCTION fn_quote_identifier(p_identifier VARCHAR(128))
RETURNS VARCHAR(132)
DETERMINISTIC
BEGIN
    RETURN CONCAT('`', REPLACE(p_identifier, '`', '``'), '`');
END$$

-- Deterministic, salted, collision-resistant obfuscated email generator.
-- p_local_part_len lets the caller fit the result to the real column's
-- character_maximum_length (see sp_create_user_mapping).
CREATE OR REPLACE FUNCTION fn_generate_obfuscated_email(
    p_original_email  VARCHAR(255),
    p_salt            VARCHAR(64),
    p_attempt         INT,
    p_local_part_len  INT
)
RETURNS VARCHAR(255)
DETERMINISTIC
BEGIN
    DECLARE v_hash VARCHAR(64);
    DECLARE v_local VARCHAR(64);

    -- p_attempt only changes on a mapping-table unique-key collision retry
    -- (astronomically unlikely with SHA-256, but handled rather than assumed away).
    SET v_hash = SHA2(CONCAT(p_salt, '|', LOWER(p_original_email), '|', p_attempt), 256);

    IF p_local_part_len < 8 THEN
        SET p_local_part_len = 8; -- floor to keep collision risk sane
    END IF;

    SET v_local = LOWER(SUBSTRING(v_hash, 1, LEAST(p_local_part_len, 40)));

    RETURN CONCAT(v_local, '@example.invalid');
END$$

-- Deterministic synthetic FIRST name, keyed by the user's identity (not
-- by the raw name value) so users sharing a real first name don't
-- necessarily collapse onto the same synthetic identity.
CREATE OR REPLACE FUNCTION fn_synthetic_first_name(p_user_key VARCHAR(255))
RETURNS VARCHAR(50)
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_count INT;
    DECLARE v_idx INT;
    DECLARE v_result VARCHAR(50);

    SELECT COUNT(*) INTO v_count FROM SyntheticFirstName;
    IF v_count = 0 THEN
        RETURN 'Person';
    END IF;

    SET v_idx = CRC32(SHA2(CONCAT('fname|', p_user_key), 256)) MOD v_count;
    -- positional pick (0..v_count-1): works for any SeedID values, not just 0..N-1
    SELECT NameValue INTO v_result FROM SyntheticFirstName ORDER BY SeedID LIMIT v_idx, 1;
    RETURN v_result;
END$$

CREATE OR REPLACE FUNCTION fn_synthetic_last_name(p_user_key VARCHAR(255))
RETURNS VARCHAR(50)
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_count INT;
    DECLARE v_idx INT;
    DECLARE v_result VARCHAR(50);

    SELECT COUNT(*) INTO v_count FROM SyntheticLastName;
    IF v_count = 0 THEN
        RETURN 'Surname';
    END IF;

    SET v_idx = CRC32(SHA2(CONCAT('lname|', p_user_key), 256)) MOD v_count;
    SELECT NameValue INTO v_result FROM SyntheticLastName ORDER BY SeedID LIMIT v_idx, 1;
    RETURN v_result;
END$$

CREATE OR REPLACE FUNCTION fn_synthetic_street_address(p_user_key VARCHAR(255))
RETURNS VARCHAR(255)
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_count INT;
    DECLARE v_idx INT;
    DECLARE v_result VARCHAR(255);

    SELECT COUNT(*) INTO v_count FROM SyntheticStreetAddress;
    IF v_count = 0 THEN
        RETURN '1 Example Street';
    END IF;

    SET v_idx = CRC32(SHA2(CONCAT('addr|', p_user_key), 256)) MOD v_count;
    SELECT AddressValue INTO v_result FROM SyntheticStreetAddress ORDER BY SeedID LIMIT v_idx, 1;
    RETURN v_result;
END$$

-- Deterministic synthetic phone number. Fixed Australian-style mobile
-- format shown as an example — adjust the literal pattern for your locale.
CREATE OR REPLACE FUNCTION fn_synthetic_phone(p_user_key VARCHAR(255), p_max_len INT)
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
CREATE OR REPLACE PROCEDURE sp_log_step(
    IN p_run_id CHAR(36), IN p_step VARCHAR(100),
    IN p_status VARCHAR(20), IN p_message VARCHAR(1000)
)
BEGIN
    INSERT INTO ObfuscationRunLog (RunID, StepName, StepStatus, Message)
    VALUES (p_run_id, p_step, p_status, p_message);
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 3. sp_validate_config
--    Sanity-checks ObfuscationConfig against live metadata before
--    anything destructive happens.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_validate_config(IN p_run_id CHAR(36))
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
                 WHERE s2.TABLE_SCHEMA = DATABASE()
                   AND s2.TABLE_NAME  = oc.TableName
                   AND s2.INDEX_NAME  = s.INDEX_NAME) AS index_cols
        FROM ObfuscationConfig oc
        JOIN information_schema.STATISTICS s
          ON s.TABLE_SCHEMA = DATABASE()
         AND s.TABLE_NAME   = oc.TableName
         AND s.COLUMN_NAME  = oc.ColumnName
         AND s.NON_UNIQUE   = 0
        WHERE oc.Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- 1. Configured columns that do not exist -- fatal, stop before any mutation.
    SELECT COUNT(*) INTO v_missing
    FROM ObfuscationConfig oc
    LEFT JOIN information_schema.COLUMNS c
        ON c.TABLE_SCHEMA = DATABASE()
       AND c.TABLE_NAME  = oc.TableName
       AND c.COLUMN_NAME = oc.ColumnName
    WHERE oc.Enabled = TRUE
      AND c.COLUMN_NAME IS NULL;

    IF v_missing > 0 THEN
        CALL sp_log_step(p_run_id, 'sp_validate_config', 'ERROR',
            CONCAT(v_missing, ' ObfuscationConfig row(s) reference columns that do not exist in the current schema.'));
        SELECT oc.TableName, oc.ColumnName
        FROM ObfuscationConfig oc
        LEFT JOIN information_schema.COLUMNS c
            ON c.TABLE_SCHEMA = DATABASE()
           AND c.TABLE_NAME  = oc.TableName
           AND c.COLUMN_NAME = oc.ColumnName
        WHERE oc.Enabled = TRUE AND c.COLUMN_NAME IS NULL;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ObfuscationConfig references non-existent columns. Fix config before proceeding.';
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
                               fn_quote_identifier(v_table), ' LIMIT 2) x');
            SET @sql_stmt = v_sql;
            PREPARE st FROM @sql_stmt; EXECUTE st; DEALLOCATE PREPARE st;

            IF @vc_rows2 >= 2 THEN
                SET v_fatal = v_fatal + 1;
                CALL sp_log_step(p_run_id, 'sp_validate_config', 'ERROR',
                    CONCAT(v_table, '.', v_column, ': ObfuscationType=STATIC writes one literal to every row, but ',
                           'single-column unique index ', v_index, ' forbids duplicates and the table has >1 row. ',
                           'Use HASH, or relax the constraint for this column.'));
            ELSE
                CALL sp_log_step(p_run_id, 'sp_validate_config', 'WARN',
                    CONCAT(v_table, '.', v_column, ' is under unique index ', v_index,
                           ' and typed STATIC (table has <=1 row, so not fatal yet).'));
            END IF;
        ELSE
            CALL sp_log_step(p_run_id, 'sp_validate_config', 'WARN',
                CONCAT(v_table, '.', v_column, ' is under unique index ', v_index, ' (', v_type,
                       '); obfuscated values must remain unique or the run will fail with a duplicate-key error. ',
                       'Confirm the replacement value space is large enough.'));
        END IF;
    END LOOP;
    CLOSE cur_uq;

    -- Diagnostic result set: every configured column that shares a unique index.
    SELECT oc.TableName, oc.ColumnName, oc.ObfuscationType, s.INDEX_NAME AS UniqueIndex
    FROM ObfuscationConfig oc
    JOIN information_schema.STATISTICS s
      ON s.TABLE_SCHEMA = DATABASE() AND s.TABLE_NAME = oc.TableName
     AND s.COLUMN_NAME = oc.ColumnName AND s.NON_UNIQUE = 0
    WHERE oc.Enabled = TRUE
    ORDER BY oc.TableName, oc.ColumnName, s.INDEX_NAME;

    IF v_fatal > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ObfuscationConfig has a column whose obfuscation type cannot satisfy a UNIQUE constraint — see ObfuscationRunLog.';
    END IF;

    CALL sp_log_step(p_run_id, 'sp_validate_config', 'OK',
        'All configured columns exist; UNIQUE-constraint checks complete.');
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 4. sp_discover_user_references
--    Populates UserReferenceRegistry from FK metadata + naming
--    convention. Re-runnable: refreshes rather than duplicates.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_discover_user_references(IN p_run_id CHAR(36))
BEGIN
    -- 4a. True foreign keys pointing at dap_User.UserID
    INSERT INTO UserReferenceRegistry (TableName, ColumnName, DiscoveryMethod, ConstraintName)
    SELECT
        kcu.TABLE_NAME, kcu.COLUMN_NAME, 'FOREIGN_KEY', kcu.CONSTRAINT_NAME
    FROM information_schema.KEY_COLUMN_USAGE kcu
    WHERE kcu.TABLE_SCHEMA = DATABASE()
      AND kcu.REFERENCED_TABLE_SCHEMA = DATABASE()
      AND kcu.REFERENCED_TABLE_NAME = 'dap_User'
      AND kcu.REFERENCED_COLUMN_NAME = 'UserID'
    ON DUPLICATE KEY UPDATE
        DiscoveryMethod = 'FOREIGN_KEY',
        ConstraintName  = VALUES(ConstraintName),
        Enabled = TRUE;

    -- 4b. Naming-convention columns (CreatedBy, ModifiedBy, etc.) that are
    -- NOT already captured as an FK above — these are value copies, not
    -- enforced relationships, so they need a separate discovery path.
    INSERT INTO UserReferenceRegistry (TableName, ColumnName, DiscoveryMethod, ConstraintName)
    SELECT
        cc.TABLE_NAME, cc.COLUMN_NAME, 'NAMING_CONVENTION', NULL
    FROM information_schema.COLUMNS cc
    JOIN information_schema.TABLES tt
        ON tt.TABLE_SCHEMA = cc.TABLE_SCHEMA AND tt.TABLE_NAME = cc.TABLE_NAME
    WHERE cc.TABLE_SCHEMA = DATABASE()
      AND tt.TABLE_TYPE = 'BASE TABLE'
      AND cc.COLUMN_NAME IN ('CreatedBy','CreatedUser','CreatedUserID','ModifiedBy','ModifiedUserID')
      AND NOT EXISTS (
          SELECT 1 FROM UserReferenceRegistry r
          WHERE r.TableName = cc.TABLE_NAME AND r.ColumnName = cc.COLUMN_NAME
      )
    ON DUPLICATE KEY UPDATE Enabled = TRUE;

    CALL sp_log_step(p_run_id, 'sp_discover_user_references', 'OK',
        (SELECT CONCAT(COUNT(*), ' user-reference column(s) registered.') FROM UserReferenceRegistry WHERE Enabled = TRUE));

    -- 4c. Type-compatibility check. dap_User.UserID is assumed string-typed (it
    -- holds the email, per the script header). A registered reference column
    -- that is numeric/temporal almost certainly is NOT a UserID copy —
    -- obfuscating it would corrupt it. Flag (WARN); the DBA should set
    -- Enabled=FALSE for any false positive, or fix the schema/discovery.
    SET @dbobf_userid_type = (
        SELECT DATA_TYPE FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID'
    );
    IF EXISTS (
        SELECT 1
        FROM UserReferenceRegistry r
        JOIN information_schema.COLUMNS c
          ON c.TABLE_SCHEMA = DATABASE() AND c.TABLE_NAME = r.TableName AND c.COLUMN_NAME = r.ColumnName
        WHERE r.Enabled = TRUE
          AND @dbobf_userid_type IN ('varchar','char','text','tinytext','mediumtext','longtext')
          AND c.DATA_TYPE NOT IN ('varchar','char','text','tinytext','mediumtext','longtext','enum','set')
    ) THEN
        CALL sp_log_step(p_run_id, 'sp_discover_user_references', 'WARN',
            'One or more registered user-reference columns are not string-typed like dap_User.UserID — review the diagnostic result set and set Enabled=FALSE for any that are not UserID copies.');
    END IF;

    -- Diagnostic result set for a human to eyeball before destructive steps run.
    SELECT r.RegistryID, r.TableName, r.ColumnName, r.DiscoveryMethod, r.ConstraintName,
           r.OrphanAction, c.DATA_TYPE AS ColumnDataType,
           (c.DATA_TYPE IN ('varchar','char','text','tinytext','mediumtext','longtext','enum','set')
            OR @dbobf_userid_type NOT IN ('varchar','char','text','tinytext','mediumtext','longtext')) AS TypeLooksCompatible
    FROM UserReferenceRegistry r
    LEFT JOIN information_schema.COLUMNS c
      ON c.TABLE_SCHEMA = DATABASE() AND c.TABLE_NAME = r.TableName AND c.COLUMN_NAME = r.ColumnName
    WHERE r.Enabled = TRUE
    ORDER BY r.DiscoveryMethod, r.TableName, r.ColumnName;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 5. sp_create_user_mapping
--    Builds UserObfuscationMapping deterministically. Idempotent:
--    only inserts users not already mapped.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_create_user_mapping(IN p_run_id CHAR(36), IN p_salt VARCHAR(64))
BEGIN
    DECLARE v_col_len INT;
    DECLARE v_local_len INT;
    DECLARE v_remaining INT DEFAULT 0;

    -- Fit the generated value to the real column length instead of assuming one.
    SELECT CHARACTER_MAXIMUM_LENGTH INTO v_col_len
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID';

    IF v_col_len IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'dap_User.UserID column not found.';
    END IF;

    -- reserve room for '@example.invalid' (16 chars)
    SET v_local_len = GREATEST(v_col_len - 17, 8);

    -- OriginalUserID is stored LOWER()-cased so downstream reference joins can be
    -- collation-agnostic (m.OriginalUserID = LOWER(t.<col>)) without depending on
    -- the schema's default collation. That only works as a 1:1 mapping if no two
    -- dap_User rows differ solely by UserID letter case -- a case-insensitive PK
    -- forbids it, but a *_bin / *_cs collation would not, and merging two real
    -- users is worse than a hard stop.
    IF EXISTS (
        SELECT 1 FROM (
            SELECT LOWER(UserID) lu FROM dap_User WHERE UserID IS NOT NULL
            GROUP BY lu HAVING COUNT(*) > 1
        ) d
    ) THEN
        CALL sp_log_step(p_run_id, 'sp_create_user_mapping', 'ERROR',
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
    INSERT IGNORE INTO UserObfuscationMapping (OriginalUserID, ObfuscatedUserID, CreatedDate)
    SELECT LOWER(u.UserID),
           fn_generate_obfuscated_email(u.UserID, p_salt, 0, v_local_len),
           NOW()
    FROM dap_User u
    LEFT JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(u.UserID)
    WHERE m.OriginalUserID IS NULL
      AND u.UserID IS NOT NULL
      AND u.UserID NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping);

    -- Collision handling: if the unique key on ObfuscatedUserID was violated
    -- for any of the just-attempted rows, they simply won't be present yet.
    -- Retry loop, escalating the attempt counter, capped to avoid infinite loop.
    SET v_remaining = (
        SELECT COUNT(*) FROM dap_User u
        LEFT JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(u.UserID)
        WHERE m.OriginalUserID IS NULL AND u.UserID IS NOT NULL
          AND u.UserID NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping)
    );

    retry_loop: BEGIN
        DECLARE v_attempt INT DEFAULT 1;
        WHILE v_remaining > 0 AND v_attempt <= 5 DO
            INSERT IGNORE INTO UserObfuscationMapping (OriginalUserID, ObfuscatedUserID, CreatedDate)
            SELECT LOWER(u.UserID),
                   fn_generate_obfuscated_email(u.UserID, p_salt, v_attempt, v_local_len),
                   NOW()
            FROM dap_User u
            LEFT JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(u.UserID)
            WHERE m.OriginalUserID IS NULL AND u.UserID IS NOT NULL
              AND u.UserID NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping);

            SET v_remaining = (
                SELECT COUNT(*) FROM dap_User u
                LEFT JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(u.UserID)
                WHERE m.OriginalUserID IS NULL AND u.UserID IS NOT NULL
                  AND u.UserID NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping)
            );
            SET v_attempt = v_attempt + 1;
        END WHILE;
    END retry_loop;

    IF v_remaining > 0 THEN
        CALL sp_log_step(p_run_id, 'sp_create_user_mapping', 'ERROR',
            CONCAT(v_remaining, ' user(s) could not be mapped after retries — investigate collisions.'));
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User mapping incomplete after collision retries.';
    ELSE
        CALL sp_log_step(p_run_id, 'sp_create_user_mapping', 'OK',
            (SELECT CONCAT(COUNT(*), ' users mapped.') FROM UserObfuscationMapping));
    END IF;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 5b. Orphan user-reference handling
--     A user-reference value that matches no dap_User.UserID never gets a
--     mapping row, so sp_obfuscate_user_references would silently leave the
--     ORIGINAL value in place — a PII leak, and one the old post-run check
--     could only flag *after* everything was already committed. FK-discovered
--     columns cannot have these (the constraint forbids it); NAMING_CONVENTION
--     / MANUAL columns routinely do (ex-staff, 'SYSTEM' sentinels, legacy bad
--     data).
--
--     sp_report_orphan_user_references  — pre-flight, read-only. Emits every
--         offending (table, column, value) so a DBA can eyeball it BEFORE any
--         destructive step and, if needed, set UserReferenceRegistry.OrphanAction.
--     sp_resolve_orphan_user_references — acts per column's OrphanAction:
--         OBFUSCATE (default) synthesises a mapping row for each stray value so
--         it is rewritten like any other reference; NULLIFY sets them NULL;
--         IGNORE leaves them and tells sp_validate_obfuscation not to flag them.
--     Both run after the mapping is built (so real users are already mapped and
--     only genuine strays remain) and before FK drop.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_report_orphan_user_references(IN p_run_id CHAR(36))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_action VARCHAR(10);
    DECLARE v_sql TEXT;
    DECLARE v_actionable BIGINT DEFAULT 0;

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName, OrphanAction
        FROM UserReferenceRegistry WHERE Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    DROP TEMPORARY TABLE IF EXISTS _OrphanUserRefReport;
    CREATE TEMPORARY TABLE _OrphanUserRefReport (
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
            'INSERT INTO _OrphanUserRefReport ',
            'SELECT ', QUOTE(v_table), ', ', QUOTE(v_column), ', ', QUOTE(v_action), ', ',
                   't.', fn_quote_identifier(v_column), ', COUNT(*) ',
            'FROM ', fn_quote_identifier(v_table), ' t ',
            'LEFT JOIN UserObfuscationMapping mo ON mo.OriginalUserID   = LOWER(t.', fn_quote_identifier(v_column), ') ',
            'LEFT JOIN UserObfuscationMapping mx ON mx.ObfuscatedUserID = t.', fn_quote_identifier(v_column), ' ',
            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
            '  AND mo.OriginalUserID IS NULL ',
            '  AND mx.ObfuscatedUserID IS NULL ',
            'GROUP BY t.', fn_quote_identifier(v_column));
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END LOOP;
    CLOSE cur;

    SET v_actionable = (SELECT IFNULL(SUM(RowsWithValue), 0)
                        FROM _OrphanUserRefReport WHERE OrphanAction <> 'IGNORE');

    IF v_actionable > 0 THEN
        CALL sp_log_step(p_run_id, 'sp_report_orphan_user_references', 'WARN',
            CONCAT(v_actionable, ' row(s) across ',
                   (SELECT COUNT(DISTINCT CONCAT(TableName, '.', ColumnName))
                    FROM _OrphanUserRefReport WHERE OrphanAction <> 'IGNORE'),
                   ' column(s) hold a user-reference value with no dap_User match; they will be handled per OrphanAction. Review the diagnostic result set.'));
    ELSE
        CALL sp_log_step(p_run_id, 'sp_report_orphan_user_references', 'OK',
            'No unhandled orphan user-reference values.');
    END IF;

    SELECT * FROM _OrphanUserRefReport ORDER BY TableName, ColumnName, OrphanValue;
END$$
DELIMITER ;

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_resolve_orphan_user_references(IN p_run_id CHAR(36), IN p_salt VARCHAR(64))
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
        FROM UserReferenceRegistry WHERE Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- SET (subquery) not SELECT..INTO: yields NULL on no match instead of
    -- raising NOT FOUND (which the cursor's handler above would also catch).
    SET v_col_len = (
        SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'dap_User' AND COLUMN_NAME = 'UserID'
    );
    IF v_col_len IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'dap_User.UserID column not found.';
    END IF;
    SET v_local_len = GREATEST(v_col_len - 17, 8);

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_table, v_column, v_action;
        IF done THEN LEAVE read_loop; END IF;

        IF v_action = 'IGNORE' THEN
            CALL sp_log_step(p_run_id, 'sp_resolve_orphan_user_references', 'SKIP',
                CONCAT(v_table, '.', v_column, ' — OrphanAction=IGNORE; unmatched values left as-is.'));
            ITERATE read_loop;
        END IF;

        IF v_action = 'NULLIFY' THEN
            SET v_affected = 1;
            WHILE v_affected > 0 DO
                SET v_sql = CONCAT(
                    'UPDATE ', fn_quote_identifier(v_table), ' t ',
                    'SET t.', fn_quote_identifier(v_column), ' = NULL ',
                    'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                    '  AND LOWER(t.', fn_quote_identifier(v_column), ') NOT IN (SELECT OriginalUserID   FROM UserObfuscationMapping) ',
                    '  AND t.', fn_quote_identifier(v_column), ' NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping) ',
                    'LIMIT 50000');
                SET @sql_stmt = v_sql;
                PREPARE stmt FROM @sql_stmt; EXECUTE stmt;
                SET v_affected = ROW_COUNT(); DEALLOCATE PREPARE stmt;
            END WHILE;
            CALL sp_log_step(p_run_id, 'sp_resolve_orphan_user_references', 'OK',
                CONCAT(v_table, '.', v_column, ' — unmatched values set to NULL.'));
            ITERATE read_loop;
        END IF;

        -- Default: OBFUSCATE. Synthesise a mapping row for every stray value so
        -- sp_obfuscate_user_references rewrites it. Same escalating-attempt
        -- collision handling as sp_create_user_mapping.
        SET v_attempt = 0;
        SET v_remaining = 1;
        WHILE v_remaining > 0 AND v_attempt <= 5 DO
            SET v_sql = CONCAT(
                'INSERT IGNORE INTO UserObfuscationMapping (OriginalUserID, ObfuscatedUserID, CreatedDate) ',
                'SELECT DISTINCT LOWER(t.', fn_quote_identifier(v_column), '), ',
                       'fn_generate_obfuscated_email(t.', fn_quote_identifier(v_column), ', ',
                            QUOTE(p_salt), ', ', v_attempt, ', ', v_local_len, '), NOW() ',
                'FROM ', fn_quote_identifier(v_table), ' t ',
                'LEFT JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(t.', fn_quote_identifier(v_column), ') ',
                'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                '  AND m.OriginalUserID IS NULL ',
                '  AND t.', fn_quote_identifier(v_column), ' NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping)');
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;

            SET v_sql = CONCAT(
                'SELECT COUNT(*) INTO @orphan_remaining FROM (',
                  'SELECT DISTINCT t.', fn_quote_identifier(v_column), ' AS v ',
                  'FROM ', fn_quote_identifier(v_table), ' t ',
                  'LEFT JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(t.', fn_quote_identifier(v_column), ') ',
                  'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                  '  AND m.OriginalUserID IS NULL ',
                  '  AND t.', fn_quote_identifier(v_column), ' NOT IN (SELECT ObfuscatedUserID FROM UserObfuscationMapping)',
                ') d');
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
            SET v_remaining = @orphan_remaining;
            SET v_attempt = v_attempt + 1;
        END WHILE;

        IF v_remaining > 0 THEN
            CALL sp_log_step(p_run_id, 'sp_resolve_orphan_user_references', 'ERROR',
                CONCAT(v_table, '.', v_column, ' — ', v_remaining,
                       ' orphan value(s) unmapped after collision retries.'));
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Orphan user-reference mapping incomplete after collision retries.';
        ELSE
            CALL sp_log_step(p_run_id, 'sp_resolve_orphan_user_references', 'OK',
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
CREATE OR REPLACE PROCEDURE sp_drop_user_fk_constraints(IN p_run_id CHAR(36))
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
        WHERE rc.CONSTRAINT_SCHEMA = DATABASE()
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
            SELECT 1 FROM FkConstraintBackup
            WHERE ConstraintName = v_constraint AND TableName = v_table AND RestoredDate IS NULL
        ) THEN
            INSERT INTO FkConstraintBackup
                (RunID, ConstraintName, TableName, ColumnList, ReferencedTableName, ReferencedColumnList, UpdateRule, DeleteRule)
            VALUES
                (p_run_id, v_constraint, v_table, v_cols, v_ref_table, v_ref_cols, v_update_rule, v_delete_rule);
        END IF;

        SET v_sql = CONCAT('ALTER TABLE ', fn_quote_identifier(v_table),
                            ' DROP FOREIGN KEY ', fn_quote_identifier(v_constraint));
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;

        CALL sp_log_step(p_run_id, 'sp_drop_user_fk_constraints', 'OK',
            CONCAT('Dropped ', v_constraint, ' on ', v_table));
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_restore_user_fk_constraints(IN p_run_id CHAR(36))
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
        FROM FkConstraintBackup
        WHERE RestoredDate IS NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id, v_constraint, v_table, v_cols, v_ref_table, v_ref_cols, v_update_rule, v_delete_rule;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Rebuild "col1`,`col2" style quoted lists from the stored CSV.
        SET v_sql = CONCAT(
            'ALTER TABLE ', fn_quote_identifier(v_table),
            ' ADD CONSTRAINT ', fn_quote_identifier(v_constraint),
            ' FOREIGN KEY (`', REPLACE(v_cols, ',', '`,`'), '`)',
            ' REFERENCES ', fn_quote_identifier(v_ref_table),
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

        UPDATE FkConstraintBackup SET RestoredDate = NOW() WHERE BackupID = v_id;

        CALL sp_log_step(p_run_id, 'sp_restore_user_fk_constraints', 'OK',
            CONCAT('Restored ', v_constraint, ' on ', v_table));
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 7. sp_obfuscate_user_references
--    Updates every column registered in UserReferenceRegistry to its
--    mapped obfuscated value. Batched to avoid huge single transactions.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_obfuscate_user_references(IN p_run_id CHAR(36), IN p_batch_size INT)
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_column VARCHAR(128);
    DECLARE v_sql TEXT;
    DECLARE v_rows_affected BIGINT;

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName FROM UserReferenceRegistry WHERE Enabled = TRUE;
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
                'UPDATE ', fn_quote_identifier(v_table), ' t ',
                'JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(t.', fn_quote_identifier(v_column), ') ',
                'SET t.', fn_quote_identifier(v_column), ' = m.ObfuscatedUserID ',
                'WHERE t.', fn_quote_identifier(v_column), ' <> m.ObfuscatedUserID ',
                'LIMIT ', p_batch_size
            );
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt;
            EXECUTE stmt;
            SET v_rows_affected = ROW_COUNT();
            DEALLOCATE PREPARE stmt;
        END WHILE;

        CALL sp_log_step(p_run_id, 'sp_obfuscate_user_references', 'OK',
            CONCAT(v_table, '.', v_column, ' updated.'));
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 8. sp_obfuscate_user_table
--    Updates dap_User.UserID itself from the mapping. Run only after
--    FKs referencing it have been dropped (see orchestrator).
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_obfuscate_user_table(IN p_run_id CHAR(36))
BEGIN
    UPDATE dap_User u
    JOIN UserObfuscationMapping m ON m.OriginalUserID = LOWER(u.UserID)
    SET u.UserID = m.ObfuscatedUserID
    WHERE u.UserID <> m.ObfuscatedUserID;

    CALL sp_log_step(p_run_id, 'sp_obfuscate_user_table', 'OK',
        CONCAT(ROW_COUNT(), ' dap_User row(s) updated.'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 9. sp_obfuscate_configured_columns
--    Dynamic dispatch over ObfuscationConfig. Each PII column is joined
--    back to dap_User via the same user-reference chain so replacement
--    values are keyed off the OWNING USER, not the raw string value —
--    satisfying "John Smith / John Brown / John Taylor" independence.
--
--    Assumption: every table carrying PII columns also carries a
--    UserID-typed column (itself, or via UserReferenceRegistry) that
--    identifies the owning user, used as the deterministic seed. If a
--    table has no such column, its own primary key is used as the seed
--    instead (still deterministic, just not shared across tables).
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_obfuscate_configured_columns(IN p_run_id CHAR(36), IN p_batch_size INT, IN p_salt VARCHAR(64))
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

    DECLARE cur CURSOR FOR
        SELECT TableName, ColumnName, ObfuscationType, StaticValue
        FROM ObfuscationConfig WHERE Enabled = TRUE;
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
        -- to the table's own primary key column.
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
            SELECT ColumnName FROM UserReferenceRegistry
            WHERE TableName = v_table AND Enabled = TRUE
            ORDER BY (DiscoveryMethod = 'FOREIGN_KEY') DESC, ColumnName
            LIMIT 1
        );

        IF v_pk_col IS NULL THEN
            SET v_pk_col = (
                SELECT kcu.COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE kcu
                JOIN information_schema.TABLE_CONSTRAINTS tc
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE kcu.TABLE_SCHEMA = DATABASE() AND kcu.TABLE_NAME = v_table
                  AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                LIMIT 1
            );
        END IF;

        IF v_pk_col IS NULL THEN
            CALL sp_log_step(p_run_id, 'sp_obfuscate_configured_columns', 'SKIP',
                CONCAT('No usable seed column (user reference or PK) found for ', v_table, '.', v_column));
        ELSE
            SET v_col_len = (
                SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = v_table AND COLUMN_NAME = v_column
            );

            SET v_seed_expr = CONCAT('t.', fn_quote_identifier(v_pk_col));

            SET v_rows_affected = 1;
            WHILE v_rows_affected > 0 DO
                CASE v_type
                    WHEN 'FIRST_NAME' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = fn_synthetic_first_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> fn_synthetic_first_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'LIMIT ', p_batch_size);

                    WHEN 'LAST_NAME' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = fn_synthetic_last_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> fn_synthetic_last_name(CAST(', v_seed_expr, ' AS CHAR)) ',
                            'LIMIT ', p_batch_size);

                    WHEN 'PHONE' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = fn_synthetic_phone(CAST(', v_seed_expr, ' AS CHAR), ', IFNULL(v_col_len, 20), ') ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> fn_synthetic_phone(CAST(', v_seed_expr, ' AS CHAR), ', IFNULL(v_col_len, 20), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'ADDRESS' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = LEFT(fn_synthetic_street_address(CAST(', v_seed_expr, ' AS CHAR)), ', IFNULL(v_col_len, 255), ') ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> LEFT(fn_synthetic_street_address(CAST(', v_seed_expr, ' AS CHAR)), ', IFNULL(v_col_len, 255), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'EMAIL' THEN
                        -- Secondary email columns (not the primary UserID). Deterministic,
                        -- keyed off the row's stable seed + salt via a HASH of the seed --
                        -- never the raw seed value, so we never emit
                        -- "user<an-already-obfuscated-email>@example.invalid". The
                        -- "<> target" guard (not a NOT LIKE) keeps it idempotent even if
                        -- the column is too narrow to hold the full '@example.invalid'.
                        SET v_sql = CONCAT(
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = LEFT(CONCAT(''user_'', LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), 16), ''@example.invalid''), ', IFNULL(v_col_len, 254), ') ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> LEFT(CONCAT(''user_'', LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), 16), ''@example.invalid''), ', IFNULL(v_col_len, 254), ') ',
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
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), ', IFNULL(v_col_len, 64), ') ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> LEFT(SHA2(CONCAT(', QUOTE(p_salt), ', ''|'', CAST(', v_seed_expr, ' AS CHAR)), 256), ', IFNULL(v_col_len, 64), ') ',
                            'LIMIT ', p_batch_size);

                    WHEN 'STATIC' THEN
                        SET v_sql = CONCAT(
                            'UPDATE ', fn_quote_identifier(v_table), ' t SET t.', fn_quote_identifier(v_column),
                            ' = ', QUOTE(LEFT(IFNULL(v_static, ''), IFNULL(v_col_len, 255))), ' ',
                            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL ',
                            'AND t.', fn_quote_identifier(v_column), ' <> ', QUOTE(LEFT(IFNULL(v_static, ''), IFNULL(v_col_len, 255))), ' ',
                            'LIMIT ', p_batch_size);

                    ELSE
                        SET v_sql = NULL;
                END CASE;

                IF v_sql IS NULL THEN
                    CALL sp_log_step(p_run_id, 'sp_obfuscate_configured_columns', 'SKIP',
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

            CALL sp_log_step(p_run_id, 'sp_obfuscate_configured_columns', 'OK',
                CONCAT(v_table, '.', v_column, ' (', v_type, ') processed.'));
        END IF;

        SET v_pk_col = NULL; -- reset for next loop iteration
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 9b. sp_snapshot_row_counts
--     Records COUNT(*) for dap_User and every table named in
--     ObfuscationConfig / UserReferenceRegistry, tagged BEFORE or AFTER,
--     so sp_validate_obfuscation can prove the process neither added nor
--     removed rows. Re-runnable (upserts on RunID+TableName+Phase).
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_snapshot_row_counts(IN p_run_id CHAR(36), IN p_phase VARCHAR(10))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_table VARCHAR(128);
    DECLARE v_sql TEXT;

    DECLARE cur CURSOR FOR
        SELECT 'dap_User' AS t
        UNION SELECT DISTINCT TableName FROM ObfuscationConfig      WHERE Enabled = TRUE
        UNION SELECT DISTINCT TableName FROM UserReferenceRegistry  WHERE Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    rc_loop: LOOP
        FETCH cur INTO v_table;
        IF done THEN LEAVE rc_loop; END IF;

        IF EXISTS (SELECT 1 FROM information_schema.TABLES
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = v_table) THEN
            SET v_sql = CONCAT(
                'INSERT INTO ObfuscationRowCountSnapshot (RunID, TableName, Phase, RowsCounted) ',
                'SELECT ', QUOTE(p_run_id), ', ', QUOTE(v_table), ', ', QUOTE(p_phase), ', COUNT(*) FROM ',
                fn_quote_identifier(v_table),
                ' ON DUPLICATE KEY UPDATE RowsCounted = VALUES(RowsCounted), CapturedAt = NOW()');
            SET @sql_stmt = v_sql;
            PREPARE st FROM @sql_stmt; EXECUTE st; DEALLOCATE PREPARE st;
        END IF;
    END LOOP;
    CLOSE cur;

    CALL sp_log_step(p_run_id, 'sp_snapshot_row_counts', 'OK',
        CONCAT(p_phase, ' row-count snapshot captured for ',
               (SELECT COUNT(*) FROM ObfuscationRowCountSnapshot WHERE RunID = p_run_id AND Phase = p_phase),
               ' table(s).'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 10. sp_validate_obfuscation
--     Post-run checks:
--       10a  orphaned user-reference values (excl. OrphanAction=IGNORE)
--       10b  row-count reconciliation vs the BEFORE snapshot
--       10c  residual-PII spot checks (heuristic)
--       10d  overall status — SIGNAL 45000 if any of the above failed
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_validate_obfuscation(IN p_run_id CHAR(36))
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
        SELECT TableName, ColumnName, OrphanAction FROM UserReferenceRegistry WHERE Enabled = TRUE;
    DECLARE cur_cfg CURSOR FOR
        SELECT TableName, ColumnName, ObfuscationType FROM ObfuscationConfig WHERE Enabled = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- 10a. After a clean run every user-reference value must be either NULL or a
    -- known ObfuscatedUserID. Strays were reported pre-flight and handled by
    -- sp_resolve_orphan_user_references, so a hit here means THIS run left
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
            CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'SKIP',
                CONCAT(v_table, '.', v_column, ' — OrphanAction=IGNORE, not checked for unmatched values.'));
            ITERATE read_loop;
        END IF;

        SET v_sql = CONCAT(
            'SELECT COUNT(*) INTO @cnt FROM ', fn_quote_identifier(v_table), ' t ',
            'LEFT JOIN UserObfuscationMapping m ON m.ObfuscatedUserID = t.', fn_quote_identifier(v_column), ' ',
            'WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL AND m.ObfuscatedUserID IS NULL'
        );
        SET @sql_stmt = v_sql;
        PREPARE stmt FROM @sql_stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
        SET v_cnt = @cnt;

        IF v_cnt > 0 THEN
            SET v_unmapped_refs = v_unmapped_refs + v_cnt;
            CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'ERROR',
                CONCAT(v_cnt, ' row(s) in ', v_table, '.', v_column,
                       ' still hold a value that is not a known obfuscated user.'));
        END IF;
    END LOOP;
    CLOSE cur;

    -- 10b. Row-count reconciliation. No obfuscation step should add or remove
    -- rows; a mismatch means a trigger or a bug did. Compares the AFTER counts
    -- to the BEFORE snapshot sp_obfuscate_database took right after discovery.
    -- Skipped (not failed) when called standalone with a RunID that has no
    -- BEFORE snapshot.
    IF EXISTS (SELECT 1 FROM ObfuscationRowCountSnapshot WHERE RunID = p_run_id AND Phase = 'BEFORE') THEN
        CALL sp_snapshot_row_counts(p_run_id, 'AFTER');

        SELECT COUNT(*) INTO v_rc_mismatch
        FROM ObfuscationRowCountSnapshot b
        JOIN ObfuscationRowCountSnapshot a
          ON a.RunID = b.RunID AND a.TableName = b.TableName AND a.Phase = 'AFTER'
        WHERE b.RunID = p_run_id AND b.Phase = 'BEFORE'
          AND a.RowsCounted <> b.RowsCounted;

        IF v_rc_mismatch > 0 THEN
            INSERT INTO ObfuscationRunLog (RunID, StepName, StepStatus, Message)
            SELECT p_run_id, 'sp_validate_obfuscation', 'ERROR',
                   CONCAT('Row count changed: ', b.TableName,
                          ' before=', b.RowsCounted, ' after=', a.RowsCounted)
            FROM ObfuscationRowCountSnapshot b
            JOIN ObfuscationRowCountSnapshot a
              ON a.RunID = b.RunID AND a.TableName = b.TableName AND a.Phase = 'AFTER'
            WHERE b.RunID = p_run_id AND b.Phase = 'BEFORE'
              AND a.RowsCounted <> b.RowsCounted;
            CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'ERROR',
                CONCAT(v_rc_mismatch, ' table(s) changed row count during obfuscation.'));
        ELSE
            CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'OK',
                'Row-count reconciliation passed (no table gained or lost rows).');
        END IF;
    ELSE
        CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'SKIP',
            'Row-count reconciliation skipped — no BEFORE snapshot for this RunID (standalone call?).');
    END IF;

    -- 10c. Residual-PII spot checks. Heuristic, not exhaustive: catches values
    -- that plainly did not get obfuscated (an email/UserID without the
    -- @example.invalid marker; a name/address not drawn from the Synthetic*
    -- pool; a phone not in the generator's 04######## shape). It cannot detect
    -- a residual value that happens to look like the synthetic domain, and it
    -- says nothing about STATIC/HASH columns (no fixed shape to test).
    SET @cnt = (SELECT COUNT(*) FROM dap_User
                WHERE UserID IS NOT NULL AND UserID NOT LIKE '%@example.invalid');
    IF @cnt > 0 THEN
        SET v_residual = v_residual + @cnt;
        CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'ERROR',
            CONCAT(@cnt, ' dap_User.UserID value(s) are not in the obfuscated form (missing @example.invalid).'));
    END IF;

    SET done = 0;
    OPEN cur_cfg;
    rp_loop: LOOP
        FETCH cur_cfg INTO v_table, v_column, v_type;
        IF done THEN LEAVE rp_loop; END IF;

        SET v_sql = NULL;
        CASE v_type
            WHEN 'EMAIL' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', fn_quote_identifier(v_table),
                    ' WHERE ', fn_quote_identifier(v_column), ' IS NOT NULL AND ',
                    fn_quote_identifier(v_column), ' NOT LIKE ''%@example.invalid''');
            WHEN 'FIRST_NAME' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', fn_quote_identifier(v_table), ' t',
                    ' WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL AND NOT EXISTS (',
                    'SELECT 1 FROM SyntheticFirstName s WHERE s.NameValue = t.', fn_quote_identifier(v_column), ')');
            WHEN 'LAST_NAME' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', fn_quote_identifier(v_table), ' t',
                    ' WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL AND NOT EXISTS (',
                    'SELECT 1 FROM SyntheticLastName s WHERE s.NameValue = t.', fn_quote_identifier(v_column), ')');
            WHEN 'ADDRESS' THEN
                -- ADDRESS is LEFT(synthetic, col_len), so match on equality OR prefix.
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', fn_quote_identifier(v_table), ' t',
                    ' WHERE t.', fn_quote_identifier(v_column), ' IS NOT NULL AND NOT EXISTS (',
                    'SELECT 1 FROM SyntheticStreetAddress s WHERE s.AddressValue = t.', fn_quote_identifier(v_column),
                    ' OR s.AddressValue LIKE CONCAT(t.', fn_quote_identifier(v_column), ', ''%''))');
            WHEN 'PHONE' THEN
                SET v_sql = CONCAT('SELECT COUNT(*) INTO @cnt FROM ', fn_quote_identifier(v_table),
                    ' WHERE ', fn_quote_identifier(v_column), ' IS NOT NULL AND ',
                    fn_quote_identifier(v_column), ' NOT REGEXP ''^04[0-9]{1,8}$''');
            ELSE
                SET v_sql = NULL;  -- STATIC / HASH: nothing reliable to assert
        END CASE;

        IF v_sql IS NOT NULL THEN
            SET @cnt = 0;
            SET @sql_stmt = v_sql;
            PREPARE stmt FROM @sql_stmt; EXECUTE stmt; DEALLOCATE PREPARE stmt;
            IF @cnt > 0 THEN
                SET v_residual = v_residual + @cnt;
                CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'ERROR',
                    CONCAT(@cnt, ' value(s) in ', v_table, '.', v_column, ' (', v_type,
                           ') are not in the obfuscated form — possible residual PII.'));
            END IF;
        END IF;
    END LOOP;
    CLOSE cur_cfg;

    IF v_residual = 0 THEN
        CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'OK',
            'Residual-PII spot checks passed (heuristic).');
    END IF;

    -- 10d. Overall status
    IF v_unmapped_refs > 0 OR v_rc_mismatch > 0 OR v_residual > 0 THEN
        CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'ERROR',
            CONCAT('Post-run validation FAILED — orphaned refs: ', v_unmapped_refs,
                   ', row-count mismatches: ', v_rc_mismatch,
                   ', residual-PII hits: ', v_residual, '. ',
                   'The refresh did not complete cleanly — fix the cause and re-run sp_obfuscate_database (it resumes).'));
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Post-run validation failed — see ObfuscationRunLog for the offending table.column(s).';
    ELSE
        CALL sp_log_step(p_run_id, 'sp_validate_obfuscation', 'OK', 'Validation passed.');
    END IF;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 11. sp_purge_sensitive_staging
--     Optional cleanup: strips real PII (OriginalUserID) out of the
--     mapping table once obfuscation is validated. Only call this once
--     you're sure no further delta-sync re-run against production is
--     planned for this refresh cycle — see design doc §C.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_purge_sensitive_staging(IN p_run_id CHAR(36))
BEGIN
    UPDATE UserObfuscationMapping SET OriginalUserID = CONCAT('purged-', ObfuscatedUserID)
    WHERE OriginalUserID NOT LIKE 'purged-%';
    -- Note: OriginalUserID is the primary key, so it can't be set to NULL;
    -- overwriting with a non-reversible placeholder achieves the same goal
    -- while keeping the table's row identity stable.

    CALL sp_log_step(p_run_id, 'sp_purge_sensitive_staging', 'OK',
        CONCAT(ROW_COUNT(), ' mapping row(s) purged of original PII.'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 11b. sp_obfuscation_status
--      Read-only. Run this BEFORE (re-)running sp_obfuscate_database to
--      see whether a schema is mid-migration: last run outcome, any FK
--      constraints currently dropped, whether the mapping still holds PII.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_obfuscation_status()
BEGIN
    SELECT RunID, Status, Salt, StartedAt, FinishedAt, ErrorSqlState, ErrorText
    FROM ObfuscationRun ORDER BY StartedAt DESC LIMIT 5;

    -- Non-empty => a prior run stopped between FK drop and FK restore.
    SELECT ConstraintName, TableName, ReferencedTableName, DroppedDate
    FROM FkConstraintBackup
    WHERE RestoredDate IS NULL
    ORDER BY DroppedDate, TableName, ConstraintName;

    SELECT
        (SELECT Status FROM ObfuscationRun ORDER BY StartedAt DESC LIMIT 1)                    AS LastRunStatus,
        (SELECT COUNT(*) FROM FkConstraintBackup WHERE RestoredDate IS NULL)                   AS FkConstraintsCurrentlyDropped,
        (SELECT COUNT(*) FROM UserObfuscationMapping WHERE OriginalUserID NOT LIKE 'purged-%') AS MappingRowsHoldingOriginalPII,
        CASE
            WHEN (SELECT COUNT(*) FROM FkConstraintBackup WHERE RestoredDate IS NULL) > 0
                THEN 'HALF-MIGRATED: FK constraints are currently dropped. Re-run sp_obfuscate_database() with the SAME salt to finish.'
            WHEN (SELECT Status FROM ObfuscationRun ORDER BY StartedAt DESC LIMIT 1) = 'RUNNING'
                THEN 'A run is in progress, or one died without recording an outcome. Re-run to resume.'
            WHEN (SELECT Status FROM ObfuscationRun ORDER BY StartedAt DESC LIMIT 1) = 'FAILED'
                THEN 'Last run FAILED (see ErrorText). Fix the cause and re-run with the same salt; it resumes.'
            WHEN (SELECT Status FROM ObfuscationRun ORDER BY StartedAt DESC LIMIT 1) = 'COMPLETED'
                THEN 'Last run COMPLETED cleanly. Safe to open the environment.'
            ELSE 'No obfuscation run has been recorded yet.'
        END AS Assessment;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 11c. sp_obfuscation_prune
--      Optional housekeeping, DBA-invoked. Keeps the most recent
--      p_keep_runs runs' worth of ObfuscationRun / ObfuscationRunLog /
--      ObfuscationRowCountSnapshot history and drops anything older.
--      Never touches a RUNNING run or an un-restored FkConstraintBackup
--      row. (The orchestrator already discards restored FK backups every
--      run, so FkConstraintBackup does not grow on its own.)
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_obfuscation_prune(IN p_keep_runs INT)
BEGIN
    DECLARE v_keep INT;

    IF p_keep_runs IS NULL OR p_keep_runs < 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_obfuscation_prune: p_keep_runs must be >= 1.';
    END IF;
    SET v_keep = p_keep_runs;

    -- Keep the newest v_keep finished runs; drop the rest. (Prune by RunID set,
    -- not by timestamp -- DATETIME is second-precision and several runs can
    -- share a second.)
    DELETE FROM ObfuscationRun
     WHERE Status <> 'RUNNING'
       AND RunID NOT IN (
           SELECT RunID FROM (
               SELECT RunID FROM ObfuscationRun
               ORDER BY StartedAt DESC, RunID DESC
               LIMIT v_keep
           ) keep
       );

    -- Drop child rows that no longer belong to a known run. This also clears
    -- log/snapshot rows from standalone sub-procedure calls (e.g.
    -- CALL sp_validate_obfuscation(UUID())) that never had a header row.
    DELETE FROM ObfuscationRunLog
     WHERE RunID NOT IN (SELECT RunID FROM ObfuscationRun);
    DELETE FROM ObfuscationRowCountSnapshot
     WHERE RunID NOT IN (SELECT RunID FROM ObfuscationRun);
    DELETE FROM FkConstraintBackup
     WHERE RestoredDate IS NOT NULL
       AND (RunID IS NULL OR RunID NOT IN (SELECT RunID FROM ObfuscationRun));

    SELECT CONCAT('Kept the newest ', p_keep_runs, ' run(s); ',
                  (SELECT COUNT(*) FROM ObfuscationRun), ' run row(s) remain.') AS Result;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 12. sp_obfuscate_database
--     Master orchestrator. Single entry point.
--     p_salt        : a secret, run-specific salt (rotate per environment refresh;
--                     a RESUME run must reuse the interrupted run's salt)
--     p_batch_size  : batching for large-table UPDATEs (default 50000)
--     p_purge_after : TRUE to strip OriginalUserID after successful validation
--
--     NOT atomic, by design. sp_drop_user_fk_constraints /
--     sp_restore_user_fk_constraints issue DDL (implicit COMMIT in MariaDB),
--     and the large UPDATEs commit in batches on purpose so they don't hold
--     locks for hours (see design doc, "Large tables / long-running
--     transactions"). A failure therefore leaves the schema PARTLY migrated —
--     but every step is idempotent and dropped FKs are recorded in
--     FkConstraintBackup, so re-running with the SAME salt finishes the job.
--     sp_obfuscation_status() reports whether a schema is mid-migration.
-- ---------------------------------------------------------------------

DELIMITER $$
CREATE OR REPLACE PROCEDURE sp_obfuscate_database(
    IN p_salt VARCHAR(64),
    IN p_batch_size INT,
    IN p_purge_after BOOLEAN
)
BEGIN
    DECLARE v_run_id CHAR(36) DEFAULT UUID();
    DECLARE v_dangling_fk INT DEFAULT 0;
    DECLARE v_prev_status VARCHAR(20);

    -- On any error: record the outcome (so sp_obfuscation_status can report it
    -- and a resume run knows what happened), then re-raise. The schema is not
    -- rolled back -- see the header note -- so the message points at the resume
    -- path rather than claiming a clean abort.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DECLARE v_sqlstate CHAR(5) DEFAULT '00000';
        DECLARE v_msg VARCHAR(512) DEFAULT '';
        GET DIAGNOSTICS CONDITION 1 v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        UPDATE ObfuscationRun
           SET Status = 'FAILED', FinishedAt = NOW(),
               ErrorSqlState = v_sqlstate, ErrorText = LEFT(v_msg, 512)
         WHERE RunID = v_run_id;
        CALL sp_log_step(v_run_id, 'sp_obfuscate_database', 'ERROR',
            CONCAT('Run FAILED (', v_sqlstate, '): ', LEFT(v_msg, 380),
                   ' -- schema may be partly migrated; fix the cause and re-run with the SAME salt to resume.'));
        RESIGNAL;
    END;

    -- Pre-flight run-state. Retire any prior run that never recorded an outcome
    -- (hard crash / killed connection), then note if we are resuming.
    UPDATE ObfuscationRun SET Status = 'SUPERSEDED', FinishedAt = NOW()
     WHERE Status = 'RUNNING';
    -- Discard spent FK backups (constraint already back on the table -- the row
    -- is redundant with information_schema). Un-restored rows are the resume
    -- signal and are kept.
    DELETE FROM FkConstraintBackup WHERE RestoredDate IS NOT NULL;
    SET v_dangling_fk = (SELECT COUNT(*) FROM FkConstraintBackup WHERE RestoredDate IS NULL);
    SET v_prev_status = (SELECT Status FROM ObfuscationRun ORDER BY StartedAt DESC LIMIT 1);

    INSERT INTO ObfuscationRun (RunID, Status, Salt) VALUES (v_run_id, 'RUNNING', p_salt);
    CALL sp_log_step(v_run_id, 'sp_obfuscate_database', 'START', CONCAT('Run started, RunID=', v_run_id));

    IF v_dangling_fk > 0 OR v_prev_status IN ('FAILED', 'SUPERSEDED') THEN
        CALL sp_log_step(v_run_id, 'sp_obfuscate_database', 'WARN',
            CONCAT('Resuming after an interrupted/failed run (previous status: ', IFNULL(v_prev_status, '?'),
                   '; FK constraints currently dropped: ', v_dangling_fk,
                   '). Every step is idempotent; the salt MUST match the interrupted run. See sp_obfuscation_status().'));
    END IF;

    CALL sp_validate_config(v_run_id);
    CALL sp_discover_user_references(v_run_id);

    -- BEFORE row-count snapshot (registry + config tables are known now).
    -- sp_validate_obfuscation compares AFTER counts against this.
    CALL sp_snapshot_row_counts(v_run_id, 'BEFORE');

    CALL sp_create_user_mapping(v_run_id, p_salt);

    -- Pre-flight: surface (don't yet touch) any user-reference value that has
    -- no dap_User match, so it can be eyeballed before destructive steps.
    CALL sp_report_orphan_user_references(v_run_id);
    -- Act on those values per each column's UserReferenceRegistry.OrphanAction
    -- (OBFUSCATE | NULLIFY | IGNORE). Runs before FK drop so mapped values are
    -- then rewritten by sp_obfuscate_user_references like any other reference.
    CALL sp_resolve_orphan_user_references(v_run_id, p_salt);

    CALL sp_drop_user_fk_constraints(v_run_id);
    CALL sp_obfuscate_user_references(v_run_id, p_batch_size);
    CALL sp_obfuscate_user_table(v_run_id);
    CALL sp_restore_user_fk_constraints(v_run_id); -- re-validates FKs as a side effect

    CALL sp_obfuscate_configured_columns(v_run_id, p_batch_size, p_salt);

    CALL sp_validate_obfuscation(v_run_id);

    IF p_purge_after THEN
        CALL sp_purge_sensitive_staging(v_run_id);
    END IF;

    UPDATE ObfuscationRun SET Status = 'COMPLETED', FinishedAt = NOW() WHERE RunID = v_run_id;
    CALL sp_log_step(v_run_id, 'sp_obfuscate_database', 'OK', 'Run completed successfully.');

    SELECT v_run_id AS RunID;
END$$
DELIMITER ;

-- =====================================================================
-- Example configuration inserts (adjust to your real column inventory)
-- =====================================================================
-- INSERT INTO ObfuscationConfig (TableName, ColumnName, ObfuscationType) VALUES
--   ('dap_User',  'FirstName',    'FIRST_NAME'),
--   ('dap_User',  'LastName',     'LAST_NAME'),
--   ('dap_User',  'PhoneNumber',  'PHONE'),
--   ('dap_User',  'Address',      'ADDRESS'),
--   ('dap_Actor', 'FirstName',    'FIRST_NAME'),
--   ('dap_Actor', 'LastName',     'LAST_NAME'),
--   ('dap_Actor', 'PhoneNumber',  'PHONE'),
--   ('dap_Actor', 'Address',      'ADDRESS');

-- =====================================================================
-- Example execution
-- =====================================================================
-- CALL sp_obfuscate_database('CHANGE-THIS-SECRET-SALT-PER-ENVIRONMENT', 50000, FALSE);
-- SELECT * FROM ObfuscationRunLog ORDER BY LogID;
