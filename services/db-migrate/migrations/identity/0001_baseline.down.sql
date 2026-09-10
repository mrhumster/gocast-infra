-- Down migration: drop identity tables (dev reset only).

DROP TABLE IF EXISTS casbin_rule;
DROP TABLE IF EXISTS users;