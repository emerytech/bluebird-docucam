SELECT count(*) AS active_installations_last_30_utc_days
FROM installations
WHERE last_seen >= date('now', '-29 days');
