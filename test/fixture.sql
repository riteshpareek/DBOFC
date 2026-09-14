-- Disposable fixture for exercising the obfuscation framework.
USE Appian;

DROP TABLE IF EXISTS dap_Actor;
DROP TABLE IF EXISTS dap_User;

CREATE TABLE dap_User (
    UserID      VARCHAR(255) PRIMARY KEY,
    FirstName   VARCHAR(50),
    LastName    VARCHAR(50),
    PhoneNumber VARCHAR(20),
    Address     VARCHAR(255)
) ENGINE=InnoDB;

CREATE TABLE dap_Actor (
    ActorID     BIGINT PRIMARY KEY AUTO_INCREMENT,
    UserID      VARCHAR(255),
    CreatedBy   VARCHAR(255),
    FirstName   VARCHAR(50),
    LastName    VARCHAR(50),
    CONSTRAINT FK_Actor_User FOREIGN KEY (UserID) REFERENCES dap_User(UserID)
) ENGINE=InnoDB;

INSERT INTO dap_User (UserID, FirstName, LastName, PhoneNumber, Address) VALUES
  ('john@test.com',  'John',  'Smith',  '0412345678', '1 Real Street'),
  ('jane@test.com',  'Jane',  'Smith',  '0498765432', '2 Real Street'),
  ('mark@test.com',  'Mark',  'Smith',  '0411112222', '3 Real Street');

INSERT INTO dap_Actor (UserID, CreatedBy, FirstName, LastName) VALUES
  ('john@test.com', 'john@test.com', 'John', 'Smith'),
  ('jane@test.com', 'john@test.com', 'Jane', 'Smith');

DELETE FROM obf_ObfuscationConfig;
INSERT INTO obf_ObfuscationConfig (TableName, ColumnName, ObfuscationType) VALUES
  ('dap_User',  'FirstName',  'FIRST_NAME'),
  ('dap_User',  'LastName',   'LAST_NAME'),
  ('dap_User',  'PhoneNumber','PHONE'),
  ('dap_User',  'Address',    'ADDRESS'),
  ('dap_Actor', 'FirstName',  'FIRST_NAME'),
  ('dap_Actor', 'LastName',   'LAST_NAME');
