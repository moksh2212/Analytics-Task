-- Meta DWH tables. Trino + Iceberg on S3, partitioned by day.
-- Raw input (assumed to exist already, not created here):
-- raw.trino_query_events(query_id, user_name, query_start_ts, query_state,
--   cpu_time_ms, accessed_tables array(row(full_name varchar, bytes_scanned bigint)))
--
-- No surrogate keys: full_name (catalog.schema.table) is already unique,
-- so it's used directly as the key everywhere instead of a hashed id.

-- one row per table in the lake
CREATE TABLE dim_table (
  full_name  varchar,   -- catalog.schema.table, primary key
  is_active  boolean
) WITH (format = 'PARQUET');

-- one row per user per team, for a time range (teams change, so SCD2)
CREATE TABLE dim_user_team (
  user_name  varchar,
  team       varchar,
  user_type  varchar,   -- human or service
  valid_from date,
  valid_to   date       -- null = still valid
) WITH (format = 'PARQUET');

-- one row per query x table it touched
CREATE TABLE fact_query_table (
  query_id      varchar,
  full_name     varchar,  -- which table, see dim_table
  user_name     varchar,
  query_date    date,
  cpu_ms        bigint,  -- query's cpu time split across tables by bytes scanned
  bytes_scanned bigint
) WITH (
  format = 'PARQUET',
  partitioning = ARRAY['day(query_date)'],
  sorted_by = ARRAY['full_name']
);

-- one row per table per day: usage summary, read by dashboards
CREATE TABLE daily_table_usage (
  full_name      varchar,
  query_date     date,
  queries        bigint,
  distinct_users bigint,
  cpu_ms         bigint,
  bytes_scanned  bigint
) WITH (format = 'PARQUET', partitioning = ARRAY['day(query_date)']);

-- one row per table per day: storage size + usage, for the dead-table report
CREATE TABLE table_health (
  full_name     varchar,
  date          date,
  storage_bytes bigint,  -- from iceberg "table$files" metadata, snapshotted daily
  queries       bigint
) WITH (format = 'PARQUET', partitioning = ARRAY['day(date)']);

-- one row per pair of tables used together in the same query (table_a < table_b)
CREATE TABLE table_pairs (
  table_a          varchar,
  table_b          varchar,
  query_date       date,
  queries_together bigint
) WITH (format = 'PARQUET', partitioning = ARRAY['day(query_date)']);

-- small view for dashboards and for AI agents looking for tables to use
CREATE VIEW table_usage_summary AS
SELECT
  t.full_name,
  SUM(u.queries)       AS queries_last_30d,
  MAX(u.query_date)    AS last_used_date,
  MAX(h.storage_bytes) AS storage_bytes
FROM dim_table t
LEFT JOIN daily_table_usage u
  ON u.full_name = t.full_name AND u.query_date >= CURRENT_DATE - INTERVAL '30' DAY
LEFT JOIN table_health h ON h.full_name = t.full_name
WHERE t.is_active
GROUP BY t.full_name;
