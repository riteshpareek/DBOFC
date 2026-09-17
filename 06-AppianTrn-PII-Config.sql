-- =====================================================================
-- obf_ObfuscationConfig — reference config for TargetSchema 'AppianTrn'
--
-- This is a per-target companion to 02-Implementation.sql, not a generic
-- framework file: it's the exact obf_ObfuscationConfig row set built up,
-- table by table, while obfuscating a real ~395-table Appian schema copy
-- (AppianTrn) during initial rollout. Kept here so that set of decisions
-- is version-controlled and reproducible for the next refresh cycle,
-- instead of only existing as live rows in obf_admin.
--
-- Run this once, after 02-Implementation.sql is loaded and BEFORE calling
-- obf_sp_obfuscate_database('AppianTrn', ...) for the first time on a
-- fresh admin install:
--   SOURCE 06-AppianTrn-PII-Config.sql;
--
-- dap_User.UserID and every registered reference column (CreatedUserID,
-- ModifiedUserID, FK-discovered columns, etc.) are handled automatically
-- by obf_sp_discover_user_references / obf_sp_obfuscate_user_references —
-- they do NOT go through this config table and are not listed here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tier 1 — high-confidence personal-contact tables
-- FirstName/LastName/Phone/Email/Address columns tied to an individual.
-- ---------------------------------------------------------------------
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('AppianTrn','dap_User','FirstName','FIRST_NAME',NULL),
  ('AppianTrn','dap_User','LastName','LAST_NAME',NULL),
  ('AppianTrn','dap_User','Phone1','PHONE',NULL),
  ('AppianTrn','dap_User','AlternatePhone','PHONE',NULL),
  ('AppianTrn','dap_User','Email','EMAIL',NULL),
  ('AppianTrn','dap_User','Address','ADDRESS',NULL),

  ('AppianTrn','cmncontact','firstname','FIRST_NAME',NULL),
  ('AppianTrn','cmncontact','lastname','LAST_NAME',NULL),
  ('AppianTrn','cmncontact','telephone','PHONE',NULL),
  ('AppianTrn','cmncontact','mobile','PHONE',NULL),
  ('AppianTrn','cmncontact','email','EMAIL',NULL),

  ('AppianTrn','cmnstakeholder','firstname','FIRST_NAME',NULL),
  ('AppianTrn','cmnstakeholder','lastname','LAST_NAME',NULL),
  ('AppianTrn','cmnstakeholder','telephone','PHONE',NULL),
  ('AppianTrn','cmnstakeholder','mobile','PHONE',NULL),
  ('AppianTrn','cmnstakeholder','email','EMAIL',NULL),

  ('AppianTrn','luaapplicant','firstname','FIRST_NAME',NULL),
  ('AppianTrn','luaapplicant','lastname','LAST_NAME',NULL),
  ('AppianTrn','luaapplicant','telephone','PHONE',NULL),
  ('AppianTrn','luaapplicant','mobile','PHONE',NULL),
  ('AppianTrn','luaapplicant','email','EMAIL',NULL),

  ('AppianTrn','luacontactperson','firstname','FIRST_NAME',NULL),
  ('AppianTrn','luacontactperson','lastname','LAST_NAME',NULL),
  ('AppianTrn','luacontactperson','telephone','PHONE',NULL),
  ('AppianTrn','luacontactperson','mobile','PHONE',NULL),
  ('AppianTrn','luacontactperson','email','EMAIL',NULL),

  ('AppianTrn','luabuilderorarchitect','firstname','FIRST_NAME',NULL),
  ('AppianTrn','luabuilderorarchitect','lastname','LAST_NAME',NULL),
  ('AppianTrn','luabuilderorarchitect','telephone','PHONE',NULL),
  ('AppianTrn','luabuilderorarchitect','mobile','PHONE',NULL),
  ('AppianTrn','luabuilderorarchitect','email','EMAIL',NULL),

  ('AppianTrn','lualandowner','firstname','FIRST_NAME',NULL),
  ('AppianTrn','lualandowner','lastname','LAST_NAME',NULL),
  ('AppianTrn','lualandowner','telephone','PHONE',NULL),
  ('AppianTrn','lualandowner','mobile','PHONE',NULL),
  ('AppianTrn','lualandowner','email','EMAIL',NULL),

  ('AppianTrn','luainvoicecontact','firstname','FIRST_NAME',NULL),
  ('AppianTrn','luainvoicecontact','lastname','LAST_NAME',NULL),
  ('AppianTrn','luainvoicecontact','telephone','PHONE',NULL),
  ('AppianTrn','luainvoicecontact','mobile','PHONE',NULL),
  ('AppianTrn','luainvoicecontact','email','EMAIL',NULL),

  ('AppianTrn','cas_ContactDetail','Address','ADDRESS',NULL),
  ('AppianTrn','cas_ContactDetail','AlternativePhone','PHONE',NULL),
  ('AppianTrn','cas_ContactDetail','Email','EMAIL',NULL),
  ('AppianTrn','cas_ContactDetail','Phone','PHONE',NULL),
  ('AppianTrn','cas_ContactDetail','PostalAddress','ADDRESS',NULL),

  ('AppianTrn','dap_Partner','Address','ADDRESS',NULL),
  ('AppianTrn','dap_Partner','AlternatePhone','PHONE',NULL),
  ('AppianTrn','dap_Partner','Email','EMAIL',NULL),
  ('AppianTrn','dap_Partner','NotificationEmail','EMAIL',NULL),
  ('AppianTrn','dap_Partner','BuildingNotificationEmail','EMAIL',NULL),
  ('AppianTrn','dap_Partner','Phone','PHONE',NULL),
  ('AppianTrn','dap_Partner','StreetAddress','ADDRESS',NULL),

  ('AppianTrn','dap_DigitalContacts','AlternatePhoneNo','PHONE',NULL),
  ('AppianTrn','dap_DigitalContacts','EmailAddress','EMAIL',NULL),
  ('AppianTrn','dap_DigitalContacts','PhoneNo','PHONE',NULL),

  ('AppianTrn','dap_IndividualContactDetails','GivenName','FIRST_NAME',NULL),
  ('AppianTrn','dap_IndividualContactDetails','BusinessName','STATIC','Business Name Redacted'),

  ('AppianTrn','dap_PublicNotificationStakeholders','Address','ADDRESS',NULL),
  ('AppianTrn','dap_PublicNotificationStakeholders','AlternatePhone','PHONE',NULL),
  ('AppianTrn','dap_PublicNotificationStakeholders','BusinessName','STATIC','Business Name Redacted'),
  ('AppianTrn','dap_PublicNotificationStakeholders','Email','EMAIL',NULL),
  ('AppianTrn','dap_PublicNotificationStakeholders','GivenName','FIRST_NAME',NULL),
  ('AppianTrn','dap_PublicNotificationStakeholders','Phone','PHONE',NULL),

  ('AppianTrn','acp_Referee','Email','EMAIL',NULL),
  ('AppianTrn','acp_Referee','Phone','PHONE',NULL),

  ('AppianTrn','luareferralagency','email','EMAIL',NULL),
  ('AppianTrn','cmnreferralagency','email','EMAIL',NULL),

  ('AppianTrn','luapnrresponse','contactemail','EMAIL',NULL),
  ('AppianTrn','luapnrresponse','contactfirstname','FIRST_NAME',NULL),
  ('AppianTrn','luapnrresponse','contactlastname','LAST_NAME',NULL),
  ('AppianTrn','luapnrresponse','contactphone','PHONE',NULL),
  ('AppianTrn','luapnrresponse','propertyemail','EMAIL',NULL),
  ('AppianTrn','luapnrresponse','propertyownerfirstname','FIRST_NAME',NULL),
  ('AppianTrn','luapnrresponse','propertyownerlastname','LAST_NAME',NULL),
  ('AppianTrn','luapnrresponse','propertyphone','PHONE',NULL);

-- ---------------------------------------------------------------------
-- Second batch — property/site address tables confirmed as PII-bearing
-- (owner name/address, not council/government contact info).
--
-- dap_BuildingNotificationResponse_OrphanBackup originally had the same
-- two columns configured here too, but the table itself was later
-- dropped from AppianTrn (outside this framework's control); its config
-- and registry rows were removed accordingly rather than left stale.
-- ---------------------------------------------------------------------
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('AppianTrn','dap_ContactAddress','StreetAddress','ADDRESS',NULL),

  ('AppianTrn','luapublicnotificationdetail','owneraddress1','ADDRESS',NULL),
  ('AppianTrn','luapublicnotificationdetail','owneraddress2','ADDRESS',NULL),
  ('AppianTrn','luapublicnotificationdetail','owneraddress3','ADDRESS',NULL),

  ('AppianTrn','lapblicnotificationresponse','owneraddress1','ADDRESS',NULL),
  ('AppianTrn','lapblicnotificationresponse','owneraddress2','ADDRESS',NULL),
  ('AppianTrn','lapblicnotificationresponse','owneraddress3','ADDRESS',NULL),

  ('AppianTrn','dap_BuildingNotificationResponse','BuilderAddress','ADDRESS',NULL),
  ('AppianTrn','dap_BuildingNotificationResponse','BuilderPhoneNumber','PHONE',NULL),

  ('AppianTrn','dap_ESP','BuildingOwnerAddress','ADDRESS',NULL),
  ('AppianTrn','dap_ESP','BuildingOwnerEmail','EMAIL',NULL);

-- ---------------------------------------------------------------------
-- dap_Actor — a real PII-bearing table (82k rows) that did not exist at
-- initial scan time (created mid-refresh while fixing a broken trigger's
-- missing dependency); discovered and configured in a follow-up pass.
-- ---------------------------------------------------------------------
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('AppianTrn','dap_Actor','GivenName','FIRST_NAME',NULL),
  ('AppianTrn','dap_Actor','FamilyName','LAST_NAME',NULL),
  ('AppianTrn','dap_Actor','Phone','PHONE',NULL),
  ('AppianTrn','dap_Actor','AlternatePhone','PHONE',NULL),
  ('AppianTrn','dap_Actor','Email','EMAIL',NULL),
  ('AppianTrn','dap_Actor','Address','ADDRESS',NULL),
  ('AppianTrn','dap_Actor','BusinessName','STATIC','Business Name Redacted'),
  ('AppianTrn','dap_Actor','MainContactPerson','STATIC','Contact Redacted'),
  ('AppianTrn','dap_Actor','RepresentedBy','STATIC','Representative Redacted'),
  ('AppianTrn','dap_Actor','City','STATIC','Adelaide'),
  ('AppianTrn','dap_Actor','CountryState','STATIC','South Australia'),
  ('AppianTrn','dap_Actor','Postcode','STATIC','5000');

-- Deferred/excluded on dap_Actor: CrownAgency, CouncilName, Country,
-- ContactMethodCode, TitleTypeCode, StateTypeCode, BuilderLicenseNo
-- (organisation names / codes / credentials, not personal PII).

-- ---------------------------------------------------------------------
-- "Tier A" full re-scan follow-up — name-shaped columns the original
-- pattern-based scan missed (e.g. "FamilyName" doesn't match a
-- "%Last%Name%" search; a plain "Name" field wasn't matched by any
-- First/Last-name pattern at all). Found by cross-referencing every text
-- column on every already-configured table against obf_ObfuscationConfig.
-- ---------------------------------------------------------------------
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('AppianTrn','dap_IndividualContactDetails','FamilyName','LAST_NAME',NULL),
  ('AppianTrn','dap_IndividualContactDetails','MainContactPerson','STATIC','Contact Redacted'),

  ('AppianTrn','dap_PublicNotificationStakeholders','FamilyName','LAST_NAME',NULL),

  ('AppianTrn','acp_Referee','Name','STATIC','Name Redacted'),
  ('AppianTrn','cas_ContactDetail','Name','STATIC','Name Redacted'),
  ('AppianTrn','dap_ESP','BuildingOwnerName','STATIC','Name Redacted'),
  ('AppianTrn','luapnrresponse','representedby','STATIC','Representative Redacted'),
  ('AppianTrn','lapblicnotificationresponse','owners','STATIC','Owner Redacted'),
  ('AppianTrn','luapublicnotificationdetail','owners','STATIC','Owner Redacted');

-- Deferred/excluded from this same re-scan pass ("Tier B" / "Tier C"):
-- ~100 structured-address-component columns (houseorlotnumber, streetname,
-- streetsuffix, streettype, unitnumber, unittype, locality, postcode,
-- state, country, deliverynumber, postaltype, City, CountryState,
-- StateTypeCode, Suburb, ...) across cmncontact/cmnstakeholder/
-- luaapplicant/luabuilderorarchitect/luacontactperson/luainvoicecontact/
-- lualandowner/luapnrresponse/dap_ContactAddress/dap_Partner/dap_User/
-- dap_PublicNotificationStakeholders/dap_Actor, plus organisation-name /
-- username-shaped columns (orgname, title, dap_Partner.PartnerName/
-- PartnerNameShort, acp_Referee.Organisation, cmnreferralagency/
-- luareferralagency.name/landusename/username). See conversation history
-- for the full column-by-column breakdown if revisiting this scope.

-- ---------------------------------------------------------------------
-- "Tier D" — dap_Partner financial/business identifiers. Not personal
-- PII of an individual, but sensitive business data worth obfuscating.
-- HASH for opaque identifier-style codes; STATIC for the one name field.
-- ---------------------------------------------------------------------
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue) VALUES
  ('AppianTrn','dap_Partner','ABN','HASH',NULL),
  ('AppianTrn','dap_Partner','AccountBSB','HASH',NULL),
  ('AppianTrn','dap_Partner','AccountNumber','HASH',NULL),
  ('AppianTrn','dap_Partner','AccountName','STATIC','Account Name Redacted'),
  ('AppianTrn','dap_Partner','AgentCode','HASH',NULL),
  ('AppianTrn','dap_Partner','AuthorisationCode','HASH',NULL),
  ('AppianTrn','dap_Partner','MasterpieceVendorId','HASH',NULL);

-- Two Tier D columns are deliberately NOT enabled -- both broke the run
-- for structural reasons unrelated to sensitivity, discovered live:
--   - appianReferenceCode: sits under a single-column UNIQUE index
--     (UQ_dap_partner_appianReferenceCode). dap_Partner's seed column
--     (CreatedUserID) isn't unique per row, so ANY deterministic
--     obfuscation type collides across partner rows sharing a creator --
--     not fixable by choosing a different ObfuscationType without a
--     framework change (per-column seed override, which doesn't exist
--     yet). Confirmed to be a system/integration reference key, not
--     personally-identifying data, so excluded rather than built around.
--   - GisServiceCode: turned out to be a genuine FOREIGN KEY to
--     dap_GISServiceCodeType.GISServiceCode -- a lookup/category code,
--     not a sensitive identifier at all.
-- Row kept here (Enabled=FALSE) rather than omitted, so the decision and
-- its reason are preserved for the next person who edits this file.
INSERT INTO obf_admin.obf_ObfuscationConfig (TargetSchema, TableName, ColumnName, ObfuscationType, StaticValue, Enabled) VALUES
  ('AppianTrn','dap_Partner','appianReferenceCode','HASH',NULL,FALSE),
  ('AppianTrn','dap_Partner','GisServiceCode','HASH',NULL,FALSE)
ON DUPLICATE KEY UPDATE Enabled = FALSE;

-- ======================================================================

-- Deferred/excluded from this same batch (property/site address tier, not
-- personal PII of an individual, or council/government contact info):
-- cmncouncildetail, luacouncildetail (council office address/email),
-- dap_Location, lualocation, cmnplbaddress, dap_ChildTitleLocation,
-- pllocation, luaipospaymentadvice, cas_CodeAmendmentSpatial.
--
-- dap_rpt_* (reporting snapshot tables) and dap_mv_* (materialized-view
-- tables) are no longer deferred here -- they're truncated outright by
-- obf_sp_truncate_reporting_snapshots() instead of being config-scrubbed
-- column-by-column. dap_mv_InspectionDetails is registered below as an
-- exclusion from that truncation, since it's kept live by triggers.
INSERT INTO obf_admin.obf_ReportingSnapshotExclusion (TargetSchema, TableName, Reason) VALUES
  ('AppianTrn','dap_mv_InspectionDetails','Kept continuously in sync by live AFTER INSERT/UPDATE/DELETE triggers on dap_InspectionDetails (see utils_drop_triggers.sql), not an inert snapshot dump -- handled like any other live table instead of truncated.');

-- dap_rpt_EntityProcessModel / dap_rpt_EntityColumnProcessModelMap /
-- dap_rpt_ref_EntityName form an FK chain among themselves
-- (dap_rpt_EntityColumnProcessModelMap -> dap_rpt_EntityProcessModel,
-- and others -> dap_rpt_ref_EntityName); obf_sp_truncate_reporting_snapshots
-- truncates dap_rpt_* tables in no particular order, so TRUNCATE fails with
-- "Cannot truncate a table referenced in a foreign key constraint" on
-- whichever of these is still an FK target when its turn comes. Excluded
-- until the truncation step accounts for FK ordering between dap_rpt_* tables.
INSERT INTO obf_admin.obf_ReportingSnapshotExclusion (TargetSchema, TableName, Reason) VALUES
  ('AppianTrn','dap_rpt_ref_EntityName','FK target of other dap_rpt_* tables -- TRUNCATE fails on the FK chain; excluded until truncation handles FK ordering between dap_rpt_* tables.'),
  ('AppianTrn','dap_rpt_EntityColumnProcessModelMap','FK target of another dap_rpt_* table -- TRUNCATE fails on the FK chain; excluded until truncation handles FK ordering between dap_rpt_* tables.'),
  ('AppianTrn','dap_rpt_EntityProcessModel','FK target of dap_rpt_EntityColumnProcessModelMap -- TRUNCATE fails on the FK chain; excluded until truncation handles FK ordering between dap_rpt_* tables.');
