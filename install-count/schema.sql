CREATE TABLE IF NOT EXISTS installations (
    id TEXT PRIMARY KEY,
    last_seen TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS installations_last_seen ON installations(last_seen);
