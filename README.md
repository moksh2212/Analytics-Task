# Meta DWH: Trino table-usage data model

Tracks who queries which lake tables and how much it costs, built from one
fact table per (query, table) pair. A daily job fills one day's data at a
time and can be safely rerun, so backfilling history is just running it
again for old dates.

On top of the two required questions, the model also gives us a dead-table
report (storage cost vs. last used) and a co-usage report (which tables get
queried together).

## Assumptions

1. Raw data is one table `raw.trino_query_events`: one row per finished
   query, with `query_id, user_name, query_start_ts, query_state,
   cpu_time_ms, accessed_tables` (a list of `catalog.schema.table`, with
   bytes scanned per table if the engine reports it).
2. Only `FINISHED` queries are counted. Failed queries are dropped (could
   add this back later with a flag).
3. A query can touch several tables. We split its `cpu_ms` across the
   tables by bytes scanned (equal split if bytes aren't known). A user who
   touched a table counts once per table, no matter how many queries.
4. User-to-team mapping comes from an outside source (HR/LDAP export) into
   `dim_user_team`. It's SCD2 because people change teams: we store
   `valid_from`/`valid_to` and join on the query's date, so old queries
   stay attributed to the team the user was on back then. No mapping =
   team `UNKNOWN`.
5. For co-usage pairs, we skip any query touching more than 10 tables —
   past that the number of pairs explodes (11 tables = 55 pairs) and the
   report gets noisy.
6. Table size for the dead-table report comes from Iceberg file metadata
   (`"table$files"`), snapshotted once a day into `table_health`.

## Tables

| Table | One row = |
|---|---|
| `dim_table` | one lake table |
| `dim_user_team` (SCD2) | one user in one team, for a time range |
| `fact_query_table` | one query x one table it touched |
| `daily_table_usage` | one table x one day |
| `table_health` | one table x one day (storage size + usage) |
| `table_pairs` | one pair of tables x one day |

```
raw.trino_query_events
        |  (split cpu_ms across tables by bytes scanned)
        v
fact_query_table  --> daily_table_usage   (trend per table)
                  --> table_health         (dead-table report)
                  --> table_pairs          (co-usage report)

dim_table, dim_user_team -- joined in for names and teams
```

`table_usage_summary` is a small view on top (see `ddl.sql`): one row per
table with recent query count, last-used date, and storage size. It's meant
to be the first place a dashboard, a new engineer, or an AI agent doing
data discovery looks before touching a table.

## Design notes

**Resource metrics**: we track `cpu_ms` and `bytes_scanned`, the two main
cost drivers in Trino. Peak memory and wall time could be added the same
way later if needed.

**How data updates**: one job, `load_daily.sql`, run once per day for
`:run_date`. Every step deletes and reinserts that day's data, so rerunning
a date is safe. Backfill or recalculation is just looping the job over a
date range. The fact table is partitioned by `query_date` and sorted by
`full_name`, since most reads are "history for one table." Reports read the
small `daily_table_usage` / `table_health` / `table_pairs` tables, not the
big fact table.

