-- =====================================================================
-- Backup, drop and later restore every trigger in a schema (MySQL).
--
-- Unlike utils_drop_triggers.sql (a hard-coded DROP list with no way back),
-- this captures each trigger's full definition from information_schema
-- into obf_admin.utils_TriggerBackup first, so the same triggers can be
-- recreated afterwards.
--
-- Usage:
--   SOURCE utils_backup_drop_restore_triggers.sql;      -- once, creates objects
--
--   CALL obf_admin.utils_sp_drop_triggers('AppianTrn');    -- backs up, verifies, drops
--   (backup alone: CALL obf_admin.utils_sp_backup_triggers('AppianTrn', @n); SELECT @n;)
--   ... run the obfuscation / whatever needed the triggers gone ...
--   CALL obf_admin.utils_sp_restore_triggers('AppianTrn'); -- recreates them
--
-- Safety:
--   * Backup refuses to overwrite an existing backup for the schema, so a
--     second drop call after the triggers are already gone cannot wipe the
--     only copy of the definitions.
--   * Nothing is dropped unless every live trigger is present in the backup.
--   * Restore skips triggers that already exist and removes a backup row
--     only after its trigger was recreated successfully.
--   * Requires TRIGGER privilege on the schema; recreating with the original
--     DEFINER also needs SET_USER_ID/SUPER if that account isn't yours.
-- =====================================================================

CREATE TABLE IF NOT EXISTS obf_admin.utils_TriggerBackup (
  TargetSchema      VARCHAR(64)   NOT NULL,
  -- Binary collation: trigger/table names are case-sensitive on Linux, so
  -- D_deletionSync_dp_S and D_deletionSync_dp_s are distinct triggers.
  TriggerName       VARCHAR(64)   CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  TableName         VARCHAR(64)   CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  ActionTiming      VARCHAR(6)    NOT NULL,   -- BEFORE / AFTER
  EventManipulation VARCHAR(6)    NOT NULL,   -- INSERT / UPDATE / DELETE
  ActionOrder       BIGINT        NOT NULL,   -- order among triggers on the same table/event
  Definer           VARCHAR(400)  NOT NULL,   -- pre-quoted `user`@`host`
  SqlMode           TEXT          NOT NULL,
  ActionStatement   LONGTEXT      NOT NULL,
  BackedUpAt        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (TargetSchema, TriggerName)
);

-- Fix up a table created by an earlier version of this script (case-insensitive key).
ALTER TABLE obf_admin.utils_TriggerBackup
  MODIFY TriggerName VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  MODIFY TableName   VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL;

DROP PROCEDURE IF EXISTS obf_admin.utils_sp_backup_triggers;
DROP PROCEDURE IF EXISTS obf_admin.utils_sp_drop_triggers;
DROP PROCEDURE IF EXISTS obf_admin.utils_sp_restore_triggers;

DELIMITER $$

CREATE PROCEDURE obf_admin.utils_sp_backup_triggers(IN p_schema VARCHAR(64), OUT p_count INT)
BEGIN
    IF EXISTS (SELECT 1 FROM obf_admin.utils_TriggerBackup WHERE TargetSchema = p_schema) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A trigger backup already exists for this schema; restore it (or delete its rows from obf_admin.utils_TriggerBackup) before backing up again.';
    END IF;

    INSERT INTO obf_admin.utils_TriggerBackup
        (TargetSchema, TriggerName, TableName, ActionTiming, EventManipulation,
         ActionOrder, Definer, SqlMode, ActionStatement)
    SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION,
           ACTION_ORDER,
           CONCAT('`', REPLACE(LEFT(DEFINER, CHAR_LENGTH(DEFINER) - CHAR_LENGTH(SUBSTRING_INDEX(DEFINER, '@', -1)) - 1), '`', '``'),
                  '`@`', REPLACE(SUBSTRING_INDEX(DEFINER, '@', -1), '`', '``'), '`'),
           SQL_MODE, ACTION_STATEMENT
    FROM information_schema.TRIGGERS
    WHERE TRIGGER_SCHEMA = p_schema;

    SET p_count = ROW_COUNT();
END$$

CREATE PROCEDURE obf_admin.utils_sp_drop_triggers(IN p_schema VARCHAR(64))
BEGIN
    DECLARE v_done  INT DEFAULT 0;
    DECLARE v_name  VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_backed_up INT DEFAULT 0;
    DECLARE cur CURSOR FOR
        SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = p_schema;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Take the backup unless one from an earlier (interrupted) run is already there.
    IF NOT EXISTS (SELECT 1 FROM obf_admin.utils_TriggerBackup WHERE TargetSchema = p_schema) THEN
        CALL obf_admin.utils_sp_backup_triggers(p_schema, v_backed_up);
    END IF;

    -- Never drop a trigger that isn't safely backed up.
    IF EXISTS (
        SELECT 1 FROM information_schema.TRIGGERS t
        LEFT JOIN obf_admin.utils_TriggerBackup b
               ON b.TargetSchema = t.TRIGGER_SCHEMA AND b.TriggerName = CONVERT(t.TRIGGER_NAME USING utf8mb4) COLLATE utf8mb4_bin
        WHERE t.TRIGGER_SCHEMA = p_schema AND b.TriggerName IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Live trigger(s) missing from the backup (created since it was taken?); aborting before dropping anything.';
    END IF;

    OPEN cur;
    drop_loop: LOOP
        FETCH cur INTO v_name;
        IF v_done THEN LEAVE drop_loop; END IF;
        SET @sql_stmt = CONCAT('DROP TRIGGER `', REPLACE(p_schema, '`', '``'), '`.`', REPLACE(v_name, '`', '``'), '`');
        PREPARE stmt FROM @sql_stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
        SET v_count = v_count + 1;
    END LOOP;
    CLOSE cur;

    -- Single result set only: phpMyAdmin fails with 2014 on multiple.
    SELECT v_backed_up AS triggers_backed_up, v_count AS triggers_dropped;
END$$

CREATE PROCEDURE obf_admin.utils_sp_restore_triggers(IN p_schema VARCHAR(64))
BEGIN
    DECLARE v_done   INT DEFAULT 0;
    DECLARE v_name   VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
    DECLARE v_table  VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
    DECLARE v_timing VARCHAR(6);
    DECLARE v_event  VARCHAR(6);
    DECLARE v_definer VARCHAR(400);
    DECLARE v_mode   TEXT;
    DECLARE v_body   LONGTEXT;
    DECLARE v_count  INT DEFAULT 0;
    DECLARE v_saved_mode TEXT DEFAULT @@SESSION.sql_mode;
    -- Recreate in original firing order on each table/event.
    DECLARE cur CURSOR FOR
        SELECT TriggerName, TableName, ActionTiming, EventManipulation, Definer, SqlMode, ActionStatement
        FROM obf_admin.utils_TriggerBackup
        WHERE TargetSchema = p_schema
        ORDER BY TableName, ActionTiming, EventManipulation, ActionOrder;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur;
    restore_loop: LOOP
        FETCH cur INTO v_name, v_table, v_timing, v_event, v_definer, v_mode, v_body;
        IF v_done THEN LEAVE restore_loop; END IF;

        IF NOT EXISTS (SELECT 1 FROM information_schema.TRIGGERS
                       WHERE TRIGGER_SCHEMA = p_schema AND CONVERT(TRIGGER_NAME USING utf8mb4) COLLATE utf8mb4_bin = v_name) THEN
            -- Bodies were compiled under their original sql_mode.
            SET @sql_mode_stmt = CONCAT('SET SESSION sql_mode = ', QUOTE(v_mode));
            PREPARE stmt FROM @sql_mode_stmt;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;

            SET @sql_stmt = CONCAT(
                'CREATE DEFINER=', v_definer,
                ' TRIGGER `', REPLACE(p_schema, '`', '``'), '`.`', REPLACE(v_name, '`', '``'), '`',
                ' ', v_timing, ' ', v_event,
                ' ON `', REPLACE(p_schema, '`', '``'), '`.`', REPLACE(v_table, '`', '``'), '`',
                ' FOR EACH ROW ', v_body);
            PREPARE stmt FROM @sql_stmt;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;

            SET @sql_mode_stmt = CONCAT('SET SESSION sql_mode = ', QUOTE(v_saved_mode));
            PREPARE stmt FROM @sql_mode_stmt;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;

            SET v_count = v_count + 1;
        END IF;

        -- Trigger now exists (just created, or already there): backup row is spent.
        DELETE FROM obf_admin.utils_TriggerBackup
        WHERE TargetSchema = p_schema AND TriggerName = v_name;
    END LOOP;
    CLOSE cur;

    SELECT v_count AS triggers_restored;
END$$

DELIMITER ;
