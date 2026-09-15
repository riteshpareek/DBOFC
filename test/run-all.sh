#!/usr/bin/env bash
# Drives 02-Implementation.sql through the full 03-Test-Plan.sql. Prints PASS/FAIL.
# Rehearsal tool: it DROPs and recreates BOTH the admin schema and the DBOBF_DB
# target database each run — point DBOBF_DB at a throwaway schema, never at
# data you care about. The admin schema name is a fixed constant baked into
# 02-Implementation.sql (`obf_admin`) -- DBOBF_ADMIN_DB below must match it.
#
# Overridable (defaults target the dev container on the native docker engine):
#   DBOBF_CTX=default|desktop-linux   docker context
#   DBOBF_CONTAINER=dbobf-mariadb     container name
#   DBOBF_USER=root  DBOBF_PW=obftest  DBOBF_DB=AppianTest
# Example against a Docker Desktop container named "mariadb":
#   DBOBF_CTX=desktop-linux DBOBF_CONTAINER=mariadb DBOBF_USER=root DBOBF_PW=secret \
#     bash test/run-all.sh
set -u
: "${DBOBF_CTX:=default}"
: "${DBOBF_CONTAINER:=dbobf-mariadb}"
: "${DBOBF_USER:=root}"
: "${DBOBF_PW:=obftest}"
: "${DBOBF_DB:=AppianTest}"
DBOBF_ADMIN_DB="obf_admin"   # must match the hardcoded schema name in 02-Implementation.sql
DC="docker --context $DBOBF_CTX"
MYSQL="$DC exec -i $DBOBF_CONTAINER mariadb -u$DBOBF_USER -p$DBOBF_PW"
DB="$MYSQL $DBOBF_DB -N"          # target-schema connection (dap_User, dap_Actor, ...)
DBA="$MYSQL $DBOBF_ADMIN_DB -N"   # admin-schema connection (obf_* objects)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0

chk() { # chk "label" "actual" "expected"
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  (got [$2] want [$3])"; fail=$((fail+1)); fi
}
q()  { $DB  2>/dev/null <<<"$1" | tr -d '\r'; }   # query the target schema
qa() { $DBA 2>/dev/null <<<"$1" | tr -d '\r'; }   # query the admin schema

reset() {
  $MYSQL $DBOBF_DB < "$ROOT/test/reset.sql" >/dev/null 2>&1
  # Admin-schema state is scoped by TargetSchema -- delete only this
  # target's rows (never TRUNCATE, since obf_admin could hold other
  # targets' data too) and re-seed the base PII config.
  $DBA >/dev/null 2>&1 <<SQL
DELETE FROM obf_UserObfuscationMapping    WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_UserReferenceRegistry     WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_TableSeedOverride         WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_FkConstraintBackup        WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_ObfuscationRunLog         WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_ObfuscationConfig         WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_ObfuscationRun            WHERE TargetSchema='$DBOBF_DB';
DELETE FROM obf_ObfuscationRowCountSnapshot WHERE TargetSchema='$DBOBF_DB';
INSERT INTO obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType) VALUES
  ('$DBOBF_DB','dap_User',  'FirstName',  'FIRST_NAME'),
  ('$DBOBF_DB','dap_User',  'LastName',   'LAST_NAME'),
  ('$DBOBF_DB','dap_User',  'PhoneNumber','PHONE'),
  ('$DBOBF_DB','dap_User',  'Address',    'ADDRESS'),
  ('$DBOBF_DB','dap_Actor', 'FirstName',  'FIRST_NAME'),
  ('$DBOBF_DB','dap_Actor', 'LastName',   'LAST_NAME');
SQL
}

echo "### reload implementation"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_ADMIN_DB\`; DROP DATABASE IF EXISTS \`$DBOBF_DB\`; CREATE DATABASE \`$DBOBF_DB\`;" >/dev/null 2>&1
$MYSQL < "$ROOT/02-Implementation.sql" >/dev/null 2>&1 && echo "  loaded"

echo "### TEST 1  deterministic user id generation"
reset
chk "same input -> same output" "$(qa "SELECT obf_fn_generate_obfuscated_user_id('john@test.com','test-salt',0,40)=obf_fn_generate_obfuscated_user_id('john@test.com','test-salt',0,40);")" "1"
chk "different input -> different output" "$(qa "SELECT obf_fn_generate_obfuscated_user_id('john@test.com','test-salt',0,40)<>obf_fn_generate_obfuscated_user_id('jane@test.com','test-salt',0,40);")" "1"

echo "### TEST 2  full run + referential integrity"
reset
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "no orphaned dap_Actor rows" "$(q "SELECT COUNT(*) FROM dap_Actor a LEFT JOIN dap_User u ON u.UserID=a.UserID WHERE a.UserID IS NOT NULL AND u.UserID IS NULL;")" "0"
chk "FK_Actor_User restored" "$(q "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME='dap_Actor' AND CONSTRAINT_NAME='FK_Actor_User' AND CONSTRAINT_TYPE='FOREIGN KEY';")" "1"

echo "### TEST 3  consistent mapping across tables"
chk "every CreatedBy that joined equals its UserID row" "$(q "SELECT COALESCE(MIN(u.UserID=a.CreatedBy),1) FROM dap_User u JOIN dap_Actor a ON a.CreatedBy=u.UserID;")" "1"

echo "### TEST 4  no original PII remains"
chk "no real first/last names" "$(q "SELECT COUNT(*) FROM dap_User WHERE FirstName IN ('John','Jane','Mark') OR LastName='Smith';")" "0"
chk "no real phone numbers" "$(q "SELECT COUNT(*) FROM dap_User WHERE PhoneNumber IN ('0412345678','0498765432','0411112222');")" "0"

echo "### TEST 5  shared real name -> independent synthetic identities"
chk "3 users -> 3 distinct (first,last) pairs" "$(q "SELECT COUNT(DISTINCT FirstName,LastName) FROM dap_User;")" "3"

echo "### TEST 6  idempotency"
S1=$(q "SELECT SHA2(GROUP_CONCAT(UserID,FirstName,LastName,PhoneNumber,Address ORDER BY UserID),256) FROM dap_User;")
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
S2=$(q "SELECT SHA2(GROUP_CONCAT(UserID,FirstName,LastName,PhoneNumber,Address ORDER BY UserID),256) FROM dap_User;")
chk "second run is a no-op" "$([ "$S1" = "$S2" ] && echo 1 || echo 0)" "1"
chk "mapping row count stable at 3" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB';")" "3"

echo "### TEST 7  collision handling"
reset
qa "SET @c:=obf_fn_generate_obfuscated_user_id('newuser@test.com','test-salt-001',0,238);
   INSERT INTO obf_UserObfuscationMapping (TargetSchema,OriginalUserID,ObfuscatedUserID,CreatedDate) VALUES('$DBOBF_DB','someone-else@test.com',@c,NOW());
   CALL obf_admin.obf_sp_create_user_mapping('$DBOBF_DB', UUID(),'test-salt-001');" >/dev/null 2>&1
q "INSERT INTO dap_User(UserID,FirstName,LastName) VALUES('newuser@test.com','New','User');" >/dev/null
qa "CALL obf_admin.obf_sp_create_user_mapping('$DBOBF_DB', UUID(),'test-salt-001');" >/dev/null
chk "newuser mapped despite attempt-0 collision" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB' AND OriginalUserID='newuser@test.com';")" "1"
chk "and NOT to the colliding value" "$(qa "SET @c:=obf_fn_generate_obfuscated_user_id('newuser@test.com','test-salt-001',0,238); SELECT ObfuscatedUserID<>@c FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB' AND OriginalUserID='newuser@test.com';")" "1"

echo "### TEST 8  bad config rejected before mutation"
reset
B=$(q "SELECT SHA2(GROUP_CONCAT(UserID,FirstName ORDER BY UserID),256) FROM dap_User;")
qa "INSERT INTO obf_ObfuscationConfig(TargetSchema,TableName,ColumnName,ObfuscationType) VALUES('$DBOBF_DB','dap_User','NoSuchColumn','STATIC');" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-002',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "orchestrator errors out" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"
A=$(q "SELECT SHA2(GROUP_CONCAT(UserID,FirstName ORDER BY UserID),256) FROM dap_User;")
chk "no data mutated" "$([ "$B" = "$A" ] && echo 1 || echo 0)" "1"
chk "obf_ObfuscationRun row = FAILED" "$(qa "SELECT Status FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")" "FAILED"

echo "### TEST 9  validation catches a deliberately broken state"
reset
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
q "SET FOREIGN_KEY_CHECKS=0; INSERT INTO dap_Actor (UserID,CreatedBy,FirstName,LastName) VALUES ('nonexistent-obfuscated-value',NULL,'X','Y'); SET FOREIGN_KEY_CHECKS=1;" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_validate_obfuscation('$DBOBF_DB', UUID());" >/dev/null 2>&1; echo $?)
chk "obf_sp_validate_obfuscation raises" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"

echo "### TEST 10  orphan user-reference handling"
reset
q "UPDATE dap_Actor SET CreatedBy='ghost-user@test.com' WHERE ActorID=1;" >/dev/null
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "10a OBFUSCATE: run succeeds, ghost value gone" "$(q "SELECT COUNT(*) FROM dap_Actor WHERE CreatedBy='ghost-user@test.com';")" "0"
chk "10a: CreatedBy now all known obfuscated ids" "$(qa "SELECT COUNT(*)=SUM(m.ObfuscatedUserID IS NOT NULL) FROM ${DBOBF_DB}.dap_Actor a LEFT JOIN obf_UserObfuscationMapping m ON m.TargetSchema='$DBOBF_DB' AND m.ObfuscatedUserID=CONVERT(a.CreatedBy USING utf8mb4) COLLATE utf8mb4_general_ci WHERE a.CreatedBy IS NOT NULL;")" "1"
reset
q "UPDATE dap_Actor SET CreatedBy='ghost-user@test.com' WHERE ActorID=1;" >/dev/null
qa "CALL obf_admin.obf_sp_discover_user_references('$DBOBF_DB', UUID());
   UPDATE obf_UserReferenceRegistry SET OrphanAction='NULLIFY' WHERE TargetSchema='$DBOBF_DB' AND TableName='dap_Actor' AND ColumnName='CreatedBy';
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "10b NULLIFY: stray -> NULL" "$(q "SELECT CreatedBy IS NULL FROM dap_Actor WHERE ActorID=1;")" "1"
reset
q "UPDATE dap_Actor SET CreatedBy='SYSTEM' WHERE ActorID=1;" >/dev/null
qa "CALL obf_admin.obf_sp_discover_user_references('$DBOBF_DB', UUID());
   UPDATE obf_UserReferenceRegistry SET OrphanAction='IGNORE' WHERE TargetSchema='$DBOBF_DB' AND TableName='dap_Actor' AND ColumnName='CreatedBy';
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "10c IGNORE: sentinel kept, run ok" "$(q "SELECT COUNT(*) FROM dap_Actor WHERE CreatedBy='SYSTEM';")" "1"
chk "10c: last run COMPLETED" "$(qa "SELECT Status FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")" "COMPLETED"

echo "### TEST 11  obf_sp_validate_config UNIQUE + type checks"
reset
q "ALTER TABLE dap_User ADD CONSTRAINT UQ_User_Phone UNIQUE (PhoneNumber);" >/dev/null
qa "CALL obf_admin.obf_sp_validate_config('$DBOBF_DB', UUID());" >/dev/null
chk "11a UNIQUE on PHONE -> WARN, no error" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND StepName='obf_sp_validate_config' AND StepStatus='WARN';")" "1"
reset
q "ALTER TABLE dap_User ADD COLUMN ExternalRef VARCHAR(64);
   UPDATE dap_User SET ExternalRef=SUBSTRING_INDEX(UserID,'@',1);
   ALTER TABLE dap_User ADD CONSTRAINT UQ_User_ExtRef UNIQUE (ExternalRef);" >/dev/null
qa "INSERT INTO obf_ObfuscationConfig(TargetSchema,TableName,ColumnName,ObfuscationType,StaticValue) VALUES('$DBOBF_DB','dap_User','ExternalRef','STATIC','X');" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','t',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "11b STATIC on sole unique idx + >1 row -> fatal" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"
chk "11b: ExternalRef untouched" "$(q "SELECT COUNT(*) FROM dap_User WHERE ExternalRef IN ('john','jane','mark');")" "3"
reset
q "CREATE TABLE dap_Widget (WidgetID BIGINT PRIMARY KEY AUTO_INCREMENT, CreatedBy BIGINT);
   INSERT INTO dap_Widget (CreatedBy) VALUES (101),(102);" >/dev/null
qa "CALL obf_admin.obf_sp_discover_user_references('$DBOBF_DB', UUID());" >/dev/null
chk "11c numeric CreatedBy -> discovery WARN" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND StepName='obf_sp_discover_user_references' AND StepStatus='WARN';")" "1"
q "DROP TABLE dap_Widget;" >/dev/null

echo "### TEST 12  reconciliation + residual-PII"
reset
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "12a reconciliation passed" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND Message LIKE 'Row-count reconciliation passed%';")" "1"
chk "12a residual checks passed" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND Message LIKE 'Residual-PII spot checks passed%';")" "1"
RID=$(qa "SELECT RunID FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")
q "DELETE FROM dap_Actor WHERE ActorID=2;" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_validate_obfuscation('$DBOBF_DB', '$RID');" >/dev/null 2>&1; echo $?)
chk "12b row-count change -> raises" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"
reset
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
RID=$(qa "SELECT RunID FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")
q "UPDATE dap_User SET FirstName='Zoltan'
   WHERE CONVERT(UserID USING utf8mb4) COLLATE utf8mb4_general_ci IN (SELECT ObfuscatedUserID FROM obf_admin.obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB') LIMIT 1;" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_validate_obfuscation('$DBOBF_DB', '$RID');" >/dev/null 2>&1; echo $?)
chk "12c residual name -> raises" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"

echo "### TEST 13  run-state tracking & resume"
reset
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "13a run recorded COMPLETED" "$(qa "SELECT Status FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")" "COMPLETED"
reset
qa "CALL obf_admin.obf_sp_discover_user_references('$DBOBF_DB', UUID());
   UPDATE obf_UserReferenceRegistry SET OrphanAction='IGNORE' WHERE TargetSchema='$DBOBF_DB' AND TableName='dap_Actor' AND ColumnName='UserID';" >/dev/null
q "SET FOREIGN_KEY_CHECKS=0;
   INSERT INTO dap_Actor (UserID,CreatedBy,FirstName,LastName) VALUES ('orphan-no-parent@x.com',NULL,'A','B');
   SET FOREIGN_KEY_CHECKS=1;" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "13b restore failure -> run FAILED" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"
chk "13b: obf_ObfuscationRun FAILED w/ sqlstate" "$(qa "SELECT ErrorSqlState FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")" "23000"
chk "13b: FK currently dropped" "$(q "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() AND CONSTRAINT_NAME='FK_Actor_User';")" "0"
chk "13b: status proc says HALF-MIGRATED" "$($MYSQL $DBOBF_ADMIN_DB -N -e "CALL obf_admin.obf_sp_obfuscation_status('$DBOBF_DB');" 2>/dev/null | grep -c 'HALF-MIGRATED')" "1"
q "DELETE FROM dap_Actor WHERE UserID='orphan-no-parent@x.com';" >/dev/null
qa "UPDATE obf_UserReferenceRegistry SET OrphanAction='OBFUSCATE' WHERE TargetSchema='$DBOBF_DB' AND TableName='dap_Actor' AND ColumnName='UserID';" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "13c resume run returns success" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "1"
chk "13c resume recorded COMPLETED" "$(qa "SELECT Status FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB' ORDER BY StartedAt DESC LIMIT 1;")" "COMPLETED"
chk "13c: FK restored" "$(q "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() AND CONSTRAINT_NAME='FK_Actor_User';")" "1"
chk "13c: resume WARN logged" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND StepName='obf_sp_obfuscate_database' AND StepStatus='WARN' AND Message LIKE 'Resuming%';")" "1"

echo "### TEST 14  F7/F8/F9 robustness"
reset
qa "DELETE FROM obf_SyntheticFirstName; INSERT INTO obf_SyntheticFirstName (SeedID,NameValue) VALUES (10,'Alta'),(25,'Bruno'),(500,'Dara'),(9999,'Cleo');
   DELETE FROM obf_SyntheticLastName;  INSERT INTO obf_SyntheticLastName  (SeedID,NameValue) VALUES (3,'Kade'),(77,'Loom'),(1201,'Mira');
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "14a F7: no NULL names with gappy SeedID" "$(q "SELECT COUNT(*) FROM dap_User WHERE FirstName IS NULL OR LastName IS NULL;")" "0"
chk "14a F7: all names from the pool" "$(qa "SELECT COUNT(*) FROM ${DBOBF_DB}.dap_User d WHERE EXISTS(SELECT 1 FROM obf_SyntheticFirstName s WHERE s.NameValue=CONVERT(d.FirstName USING utf8mb4) COLLATE utf8mb4_general_ci) AND EXISTS(SELECT 1 FROM obf_SyntheticLastName s WHERE s.NameValue=CONVERT(d.LastName USING utf8mb4) COLLATE utf8mb4_general_ci);")" "3"
reset
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','a',10000,FALSE);
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','b',10000,FALSE);
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','c',10000,FALSE);" >/dev/null
chk "14b F8: obf_FkConstraintBackup bounded (=1)" "$(qa "SELECT COUNT(*) FROM obf_FkConstraintBackup WHERE TargetSchema='$DBOBF_DB';")" "1"
qa "CALL obf_admin.obf_sp_obfuscation_prune('$DBOBF_DB', 1);" >/dev/null
chk "14b F8: prune(1) keeps one run" "$(qa "SELECT COUNT(*) FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB';")" "1"
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscation_prune('$DBOBF_DB', 0);" >/dev/null 2>&1; echo $?)
chk "14b F8: prune(0) rejected" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"
reset
q "ALTER TABLE dap_User ADD COLUMN AltEmail VARCHAR(254);
   UPDATE dap_User SET AltEmail=CONCAT('alt.',SUBSTRING_INDEX(UserID,'@',1),'@corp.example');" >/dev/null
qa "INSERT INTO obf_ObfuscationConfig(TargetSchema,TableName,ColumnName,ObfuscationType) VALUES('$DBOBF_DB','dap_User','AltEmail','EMAIL');
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "14c F9: no double @example.invalid" "$(q "SELECT COUNT(*) FROM dap_User WHERE AltEmail LIKE '%@example.invalid@example.invalid%';")" "0"
chk "14c F9: all AltEmail well-formed" "$(q "SELECT COUNT(*) FROM dap_User WHERE AltEmail RLIKE '^user_[0-9a-f]{16}@example\\\\.invalid\$';")" "3"

echo "### TEST 15  collation-agnostic reference joins (#3 hardening)"
reset
q "UPDATE dap_Actor SET CreatedBy='JOHN@TEST.COM' WHERE ActorID=1;" >/dev/null   # same user, upper case
qa "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "15a mapping stores OriginalUserID lower-cased" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB' AND OriginalUserID <> LOWER(OriginalUserID);")" "0"
chk "15a no spurious extra mapping row for the case variant" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB';")" "3"
chk "15a case-variant CreatedBy resolved to john's obfuscated id" "$(qa "SELECT (CONVERT(a.CreatedBy USING utf8mb4) COLLATE utf8mb4_general_ci = m.ObfuscatedUserID) FROM ${DBOBF_DB}.dap_Actor a JOIN obf_UserObfuscationMapping m ON m.TargetSchema='$DBOBF_DB' AND m.OriginalUserID='john@test.com' WHERE a.ActorID=1;")" "1"
# 15b: under a case-sensitive collation, case-only duplicates in dap_User are a hard stop
reset
q "ALTER TABLE dap_Actor DROP FOREIGN KEY FK_Actor_User;
   ALTER TABLE dap_User MODIFY UserID VARCHAR(255) COLLATE utf8mb4_bin;
   INSERT INTO dap_User (UserID,FirstName,LastName) VALUES ('John@dup.com','J','D');
   INSERT INTO dap_User (UserID,FirstName,LastName) VALUES ('john@dup.com','j','d');" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_create_user_mapping('$DBOBF_DB', UUID(),'test-salt-001');" >/dev/null 2>&1; echo $?)
chk "15b case-only duplicate UserIDs -> obf_sp_create_user_mapping raises" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"

echo "### TEST 16  reference column too narrow -> caught pre-flight"
reset
q "ALTER TABLE dap_Actor MODIFY CreatedBy VARCHAR(20);" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "16a narrow ref column -> orchestrator errors out" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "1"
chk "16b: FK not yet dropped (caught before any destructive step)" "$(q "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() AND CONSTRAINT_NAME='FK_Actor_User';")" "1"
chk "16c: log names the offending column" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND StepName='obf_sp_validate_reference_column_lengths' AND Message LIKE '%dap_Actor.CreatedBy%';")" "1"

echo "### TEST 17  obfuscated user id never crosses 34 chars -> VARCHAR(34) needs no schema change"
reset
q "ALTER TABLE dap_Actor MODIFY CreatedBy VARCHAR(34);" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "17a VARCHAR(34) ref column -> run succeeds" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "1"
chk "17b: obfuscated CreatedBy fits in 34 chars" "$(q "SELECT MAX(LENGTH(CreatedBy))<=34 FROM dap_Actor;")" "1"

echo "### TEST 18  obf_TableSeedOverride unblocks a table with no PRIMARY KEY"
reset
q "CREATE TABLE dap_NoPkContact (id INT NOT NULL, FirstName VARCHAR(50));
   INSERT INTO dap_NoPkContact (id, FirstName) VALUES (1,'John'),(2,'Jane');" >/dev/null
qa "INSERT INTO obf_ObfuscationConfig (TargetSchema,TableName,ColumnName,ObfuscationType) VALUES ('$DBOBF_DB','dap_NoPkContact','FirstName','FIRST_NAME');
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "18a no PK, no override -> left untouched" "$(q "SELECT COUNT(*) FROM dap_NoPkContact WHERE FirstName IN ('John','Jane');")" "2"
chk "18a: SKIP logged" "$(qa "SELECT COUNT(*)>0 FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB' AND StepName='obf_sp_obfuscate_configured_columns' AND StepStatus='SKIP' AND Message LIKE '%dap_NoPkContact%';")" "1"
qa "INSERT INTO obf_TableSeedOverride (TargetSchema,TableName,ColumnName) VALUES ('$DBOBF_DB','dap_NoPkContact','id');
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB','test-salt-001',10000,FALSE);" >/dev/null
chk "18b override registered -> now obfuscated" "$(q "SELECT COUNT(*) FROM dap_NoPkContact WHERE FirstName IN ('John','Jane');")" "0"
chk "18b: values drawn from the synthetic pool" "$(qa "SELECT COUNT(*) FROM ${DBOBF_DB}.dap_NoPkContact d WHERE EXISTS(SELECT 1 FROM obf_SyntheticFirstName s WHERE s.NameValue=CONVERT(d.FirstName USING utf8mb4) COLLATE utf8mb4_general_ci);")" "2"

echo "### TEST 19  multi-target isolation (two targets, one admin install)"
DBOBF_DB2="${DBOBF_DB}_2"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_DB2\`; CREATE DATABASE \`$DBOBF_DB2\`;" >/dev/null 2>&1
$MYSQL $DBOBF_DB2 < "$ROOT/test/reset.sql" >/dev/null 2>&1
qa "INSERT INTO obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType) VALUES
     ('$DBOBF_DB2','dap_User','FirstName','FIRST_NAME'),('$DBOBF_DB2','dap_User','LastName','LAST_NAME');
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB', 'salt-target-1', 10000, FALSE);
   CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB2','salt-target-2', 10000, FALSE);" >/dev/null
chk "19a target 1 obfuscated" "$(qa "SELECT COUNT(*) FROM ${DBOBF_DB}.dap_User u JOIN obf_UserObfuscationMapping m ON m.TargetSchema='$DBOBF_DB' AND m.ObfuscatedUserID=CONVERT(u.UserID USING utf8mb4) COLLATE utf8mb4_general_ci;")" "3"
chk "19b target 2 obfuscated independently" "$(qa "SELECT COUNT(*) FROM ${DBOBF_DB2}.dap_User u JOIN obf_UserObfuscationMapping m ON m.TargetSchema='$DBOBF_DB2' AND m.ObfuscatedUserID=CONVERT(u.UserID USING utf8mb4) COLLATE utf8mb4_general_ci;")" "3"
chk "19c mapping rows fully isolated per target" "$(qa "SELECT COUNT(DISTINCT TargetSchema) FROM obf_UserObfuscationMapping WHERE TargetSchema IN ('$DBOBF_DB','$DBOBF_DB2');")" "2"
chk "19d target 1's ObfuscatedUserID differs from target 2's for the same email" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping m1 JOIN obf_UserObfuscationMapping m2 ON m1.OriginalUserID=m2.OriginalUserID WHERE m1.TargetSchema='$DBOBF_DB' AND m2.TargetSchema='$DBOBF_DB2' AND m1.ObfuscatedUserID=m2.ObfuscatedUserID;")" "0"
chk "19e target 2 run status independent COMPLETED" "$(qa "SELECT Status FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB2' ORDER BY StartedAt DESC LIMIT 1;")" "COMPLETED"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_DB2\`;" >/dev/null 2>&1
qa "DELETE FROM obf_ObfuscationConfig WHERE TargetSchema='$DBOBF_DB2';
   DELETE FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB2';
   DELETE FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB2';
   DELETE FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB2';
   DELETE FROM obf_ObfuscationRowCountSnapshot WHERE TargetSchema='$DBOBF_DB2';
   DELETE FROM obf_UserReferenceRegistry WHERE TargetSchema='$DBOBF_DB2';" >/dev/null 2>&1

echo "### TEST 20  target schema on a different collation than obf_admin (e.g. legacy utf8mb4_general_ci vs a newer server default) doesn't hit 'Illegal mix of collations'"
DBOBF_DB3="${DBOBF_DB}_ci"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_DB3\`; CREATE DATABASE \`$DBOBF_DB3\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" >/dev/null 2>&1
$MYSQL $DBOBF_DB3 < "$ROOT/test/reset.sql" >/dev/null 2>&1
qa "INSERT INTO obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType) VALUES
     ('$DBOBF_DB3','dap_User','FirstName','FIRST_NAME'),('$DBOBF_DB3','dap_User','LastName','LAST_NAME'),
     ('$DBOBF_DB3','dap_User','PhoneNumber','PHONE'),('$DBOBF_DB3','dap_User','Address','ADDRESS'),
     ('$DBOBF_DB3','dap_Actor','FirstName','FIRST_NAME'),('$DBOBF_DB3','dap_Actor','LastName','LAST_NAME');" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB3','test-salt-ci',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "20a run against a differently-collated target succeeds" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "1"
S1=$($MYSQL $DBOBF_DB3 -N -e "SELECT SHA2(GROUP_CONCAT(UserID,FirstName,LastName,PhoneNumber,Address ORDER BY UserID),256) FROM dap_User;")
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB3','test-salt-ci',10000,FALSE);" >/dev/null 2>&1; echo $?)
S2=$($MYSQL $DBOBF_DB3 -N -e "SELECT SHA2(GROUP_CONCAT(UserID,FirstName,LastName,PhoneNumber,Address ORDER BY UserID),256) FROM dap_User;")
chk "20b second run against it is still idempotent" "$([ "$RC" -eq 0 ] && [ "$S1" = "$S2" ] && echo 1 || echo 0)" "1"
chk "20c mapping row count stable at 3 (no spurious re-mapping)" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB3';")" "3"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_DB3\`;" >/dev/null 2>&1
qa "DELETE FROM obf_ObfuscationConfig WHERE TargetSchema='$DBOBF_DB3';
   DELETE FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB3';
   DELETE FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB3';
   DELETE FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB3';
   DELETE FROM obf_ObfuscationRowCountSnapshot WHERE TargetSchema='$DBOBF_DB3';
   DELETE FROM obf_UserReferenceRegistry WHERE TargetSchema='$DBOBF_DB3';" >/dev/null 2>&1

echo "### TEST 21  target schema on a different CHARACTER SET than obf_admin (e.g. legacy utf8mb3 vs obf_admin's utf8mb4) doesn't hit 'COLLATION ... is not valid for CHARACTER SET ...'"
DBOBF_DB4="${DBOBF_DB}_mb3"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_DB4\`; CREATE DATABASE \`$DBOBF_DB4\` CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;" >/dev/null 2>&1
$MYSQL $DBOBF_DB4 < "$ROOT/test/reset.sql" >/dev/null 2>&1
qa "INSERT INTO obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType) VALUES
     ('$DBOBF_DB4','dap_User','FirstName','FIRST_NAME'),('$DBOBF_DB4','dap_User','LastName','LAST_NAME'),
     ('$DBOBF_DB4','dap_User','PhoneNumber','PHONE'),('$DBOBF_DB4','dap_User','Address','ADDRESS'),
     ('$DBOBF_DB4','dap_Actor','FirstName','FIRST_NAME'),('$DBOBF_DB4','dap_Actor','LastName','LAST_NAME');" >/dev/null
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB4','test-salt-mb3',10000,FALSE);" >/dev/null 2>&1; echo $?)
chk "21a run against a utf8mb3 target succeeds" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)" "1"
S1=$($MYSQL $DBOBF_DB4 -N -e "SELECT SHA2(GROUP_CONCAT(UserID,FirstName,LastName,PhoneNumber,Address ORDER BY UserID),256) FROM dap_User;")
RC=$($MYSQL $DBOBF_ADMIN_DB -e "CALL obf_admin.obf_sp_obfuscate_database('$DBOBF_DB4','test-salt-mb3',10000,FALSE);" >/dev/null 2>&1; echo $?)
S2=$($MYSQL $DBOBF_DB4 -N -e "SELECT SHA2(GROUP_CONCAT(UserID,FirstName,LastName,PhoneNumber,Address ORDER BY UserID),256) FROM dap_User;")
chk "21b second run against it is still idempotent" "$([ "$RC" -eq 0 ] && [ "$S1" = "$S2" ] && echo 1 || echo 0)" "1"
chk "21c mapping row count stable at 3 (no spurious re-mapping)" "$(qa "SELECT COUNT(*) FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB4';")" "3"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DBOBF_DB4\`;" >/dev/null 2>&1
qa "DELETE FROM obf_ObfuscationConfig WHERE TargetSchema='$DBOBF_DB4';
   DELETE FROM obf_UserObfuscationMapping WHERE TargetSchema='$DBOBF_DB4';
   DELETE FROM obf_ObfuscationRun WHERE TargetSchema='$DBOBF_DB4';
   DELETE FROM obf_ObfuscationRunLog WHERE TargetSchema='$DBOBF_DB4';
   DELETE FROM obf_ObfuscationRowCountSnapshot WHERE TargetSchema='$DBOBF_DB4';
   DELETE FROM obf_UserReferenceRegistry WHERE TargetSchema='$DBOBF_DB4';" >/dev/null 2>&1

echo
echo "======================================"
echo "  PASS: $pass   FAIL: $fail"
echo "======================================"
[ "$fail" -eq 0 ]
