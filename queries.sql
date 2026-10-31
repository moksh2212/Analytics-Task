-- 1. distinct users of table X in a period
SELECT COUNT(DISTINCT user_name) AS distinct_users
FROM fact_query_table
WHERE full_name = 'lake.sales.orders'
  AND query_date BETWEEN DATE '2026-10-01' AND DATE '2026-10-31';

-- 2. resources used by team Y in a period (join on team valid at query_date)
SELECT SUM(f.cpu_ms) AS total_cpu_ms, SUM(f.bytes_scanned) AS total_bytes_scanned
FROM fact_query_table f
JOIN dim_user_team u ON f.user_name = u.user_name
 AND f.query_date >= u.valid_from AND (u.valid_to IS NULL OR f.query_date <= u.valid_to)
WHERE u.team = 'Finance'
  AND f.query_date BETWEEN DATE '2026-10-01' AND DATE '2026-10-31';

-- 3. dead tables: no queries in 90 days, biggest first
SELECT h.full_name, h.storage_bytes
FROM table_health h
WHERE h.date = CURRENT_DATE
  AND h.full_name NOT IN (
    SELECT full_name FROM fact_query_table WHERE query_date >= CURRENT_DATE - INTERVAL '90' DAY
  )
ORDER BY h.storage_bytes DESC;

-- 4. co-usage pairs for one day
SELECT table_a, table_b, queries_together
FROM table_pairs
WHERE query_date = DATE '2026-10-31'
ORDER BY queries_together DESC;

-- 5. trend: weekly usage of one table over time
-- note: distinct_users is not summed here, see README ("distinct users don't add up")
SELECT date_trunc('week', query_date) AS week,
       SUM(queries) AS queries, SUM(cpu_ms) AS cpu_ms
FROM daily_table_usage
WHERE full_name = 'lake.sales.orders'
  AND query_date BETWEEN DATE '2026-09-01' AND DATE '2026-10-31'
GROUP BY 1
ORDER BY 1;
