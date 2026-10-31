-- Daily load job. Parameter: :run_date (DATE).
-- Safe to rerun: each step deletes and reinserts that day's data,
-- so backfill is just looping this script over a range of dates.

-- 0. stage today's events, one row per query x table it touched
DROP TABLE IF EXISTS today_access;
CREATE TABLE today_access AS
SELECT
  e.query_id, e.user_name, e.cpu_time_ms, date(e.query_start_ts) AS query_date,
  at.full_name,
  COALESCE(at.bytes_scanned, 1) AS bytes_scanned
FROM raw.trino_query_events e, UNNEST(e.accessed_tables) AS at(full_name, bytes_scanned)
WHERE e.query_state = 'FINISHED' AND date(e.query_start_ts) = :run_date;

-- 1. add any new tables seen today that aren't in dim_table yet
INSERT INTO dim_table (full_name, is_active)
SELECT DISTINCT full_name, true
FROM today_access
WHERE full_name NOT IN (SELECT full_name FROM dim_table);

-- 2. fact_query_table: rebuild today's partition
-- split each query's cpu time across its tables, by share of bytes scanned
DELETE FROM fact_query_table WHERE query_date = :run_date;

INSERT INTO fact_query_table
SELECT
  a.query_id, a.full_name, a.user_name, a.query_date,
  CAST(a.cpu_time_ms * a.bytes_scanned / totals.total_bytes AS bigint) AS cpu_ms,
  a.bytes_scanned
FROM today_access a
JOIN (SELECT query_id, SUM(bytes_scanned) AS total_bytes FROM today_access GROUP BY query_id) totals
  ON totals.query_id = a.query_id;

-- 3. daily_table_usage: rebuild today's partition
DELETE FROM daily_table_usage WHERE query_date = :run_date;

INSERT INTO daily_table_usage
SELECT full_name, query_date,
       COUNT(DISTINCT query_id)  AS queries,
       COUNT(DISTINCT user_name) AS distinct_users,
       SUM(cpu_ms)               AS cpu_ms,
       SUM(bytes_scanned)        AS bytes_scanned
FROM fact_query_table
WHERE query_date = :run_date
GROUP BY full_name, query_date;

-- 4. table_health: rebuild today's snapshot (usage + storage size)
-- storage_bytes comes from a separate daily Iceberg metadata snapshot (table_storage_snapshot)
DELETE FROM table_health WHERE date = :run_date;

INSERT INTO table_health
SELECT t.full_name, :run_date AS date,
       COALESCE(m.storage_bytes, 0) AS storage_bytes,
       COALESCE(u.queries, 0)       AS queries
FROM dim_table t
LEFT JOIN daily_table_usage u ON u.full_name = t.full_name AND u.query_date = :run_date
LEFT JOIN table_storage_snapshot m ON m.full_name = t.full_name AND m.date = :run_date
WHERE t.is_active;

-- 5. table_pairs: rebuild today's pairs
-- skip queries touching more than 10 tables (pairs explode: 11 tables = 55 pairs)
DELETE FROM table_pairs WHERE query_date = :run_date;

INSERT INTO table_pairs
SELECT a.full_name, b.full_name, a.query_date, COUNT(DISTINCT a.query_id)
FROM fact_query_table a
JOIN fact_query_table b ON a.query_id = b.query_id AND a.full_name < b.full_name
WHERE a.query_date = :run_date
  AND a.query_id NOT IN (
    SELECT query_id FROM fact_query_table
    WHERE query_date = :run_date
    GROUP BY query_id HAVING COUNT(DISTINCT full_name) > 10
  )
GROUP BY a.full_name, b.full_name, a.query_date;

-- 6. data quality check: fact row count must match today's staged row count
SELECT
  (SELECT COUNT(*) FROM fact_query_table WHERE query_date = :run_date) AS fact_rows,
  (SELECT COUNT(*) FROM today_access) AS expected_rows;
