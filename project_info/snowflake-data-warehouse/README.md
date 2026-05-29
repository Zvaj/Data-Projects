# Yes Energy Data Warehouse — Snowflake

A production-style dimensional data warehouse built in Snowflake using Yes Energy sample data from the Snowflake Marketplace. This project demonstrates a full data warehousing pipeline: from raw ingestion through a six-step curation layer, feature engineering via stored procedures, an aggregation layer with materialized views, and scheduled automation.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        FLAMINGO_DB                              │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  CURATION SCHEMA                                        │    │
│  │                                                         │    │
│  │  CUR_T_SOURCE (table)                                   │    │
│  │       │                                                 │    │
│  │       ▼                                                 │    │
│  │  Step 1: CUR_VW_SOURCE ──── Passthrough view            │    │
│  │       │                                                 │    │
│  │       ▼                                                 │    │
│  │  Step 2: CUR_VW_T1_DEDUP ── ROW_NUMBER() dedup          │    │
│  │       │                                                 │    │
│  │       ▼                                                 │    │
│  │  Step 3: CUR_VW_T2_STANDARDIZED ── TRIM, timezone       │    │
│  │       │                             conversion, lineage  │    │
│  │       ▼                                                 │    │
│  │  Step 4: CUR_VW_T3_ENRICHED ── Date parts, weekend/     │    │
│  │       │                        business hour flags,      │    │
│  │       ▼                        data quality flags        │    │
│  │  Step 5: CUR_VW_T4_FILTERED ── Remove bad records       │    │
│  │       │                                                 │    │
│  │       ▼                                                 │    │
│  │  Step 6: CUR_VW_CURATED ──── SHA2 surrogate key,        │    │
│  │       │                      publish-ready view          │    │
│  │       ▼                                                 │    │
│  │  SP_ENHANCE_WEATHER_TO_TRANSIENT() ── Stored procedure   │    │
│  │       │                                                 │    │
│  │       ├── CUR_T6_FEATURES ── LAG, gap_minutes,          │    │
│  │       │                      obs_count_24h, hour_band    │    │
│  │       └── CUR_T6_ENHANCED ── Analyst-friendly subset     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  AGGREGATION SCHEMA                                     │    │
│  │                                                         │    │
│  │  AGG_T_STATION_DAILY ────── Daily rollups (table)       │    │
│  │  AGG_VW_STATION_HOURLY ──── Hourly profile (view)       │    │
│  │  AGG_VW_WEEKEND_VS_WEEKDAY  Weekend comparison (view)   │    │
│  │  AGG_VW_HOUR_BAND_SUMMARY   Time-of-day summary (view)  │    │
│  │  AGG_MV_STATION_WEEK ────── Weekly rollup (mat. view)   │    │
│  │  FN_STATION_DAILY_STATS ─── Table function (on-demand)  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  AUTOMATION                                             │    │
│  │  TSK_WEEKLY_ENHANCE_WEATHER ── Runs every Sunday 4 AM   │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Dataset

**Yes Energy — Sample Data** (Snowflake Marketplace)

A free sample containing approximately two years of weather and energy data for Texas (ERCOT). Yes Energy collects detailed data about the energy market including electricity prices, demand, and renewable generation from regional energy operators.

## Key Technical Features

- **Six-step curation pipeline** using chained views for modular, maintainable transformations
- **Deduplication** using `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` to keep the most recent record per natural key
- **Timezone handling** with `CONVERT_TIMEZONE()` for UTC and Central Time analytics
- **Data quality flags** (`flag_missing_wban`, `flag_missing_ts`, `flag_future_ts`) for transparent data validation
- **Surrogate keys** using `SHA2()` for stable downstream joins
- **Stored procedure** (`SP_ENHANCE_WEATHER_TO_TRANSIENT`) for feature engineering including LAG-based gap analysis, rolling 24-hour observation counts, and hour-band bucketing
- **Materialized view** (`AGG_MV_STATION_WEEK`) for pre-computed weekly rollups
- **Table function** (`FN_STATION_DAILY_STATS`) for parameterized on-demand station reports
- **Scheduled task** with CRON expression for automated weekly refresh
- **Semantic tagging** with `PROJECT = 'yes_energy'` for governance and discoverability

## Naming Conventions

| Prefix | Meaning |
|--------|---------|
| `CUR_VW_*` | Curation views (pipeline steps) |
| `CUR_T_*` | Curated/feature tables |
| `AGG_VW_*` | Aggregated views |
| `AGG_T_*` | Aggregated tables |
| `AGG_MV_*` | Materialized views |
| `FN_*` | Table functions |
| `SP_*` | Stored procedures |
| `TSK_*` | Scheduled tasks |

## Quick Start

```sql
-- Explore cleaned weather data
SELECT * FROM FLAMINGO_DB.CURATION.CUR_VW_CURATED LIMIT 50;

-- Daily station stats
SELECT * FROM FLAMINGO_DB.AGGREGATION.AGG_T_STATION_DAILY
WHERE WBAN = '03011' ORDER BY DATE_CT;

-- On-demand station report (table function)
SELECT * FROM TABLE(FLAMINGO_DB.AGGREGATION.FN_STATION_DAILY_STATS(
  '03011', DATE '2023-01-01', DATE '2023-02-01'
));

-- Weekly summaries
SELECT * FROM FLAMINGO_DB.AGGREGATION.AGG_VW_STATION_WEEK
WHERE WBAN = '03011';
```

## Files

| File | Description |
|------|-------------|
| `curation_pipeline.sql` | Six-step curation pipeline (views) |
| `stored_procedure.sql` | Feature engineering stored procedure |
| `aggregation_layer.sql` | Aggregated views, tables, and materialized views |
| `table_function.sql` | Parameterized on-demand reporting function |
| `scheduled_task.sql` | Weekly automation task |
| `data_catalog.md` | Mini data catalog with field descriptions |

## Tools & Technologies

- Snowflake (SQL, stored procedures, materialized views, tasks)
- Yes Energy Sample Data (Snowflake Marketplace)

## Reflections

This project taught me how to design a maintainable, production-style data warehouse from scratch. If I were to redo it, I would choose a dataset that allows for more meaningful analytical visualizations. However, the core skills — pipeline design, data quality management, automation, and documentation — translate directly to any data warehousing environment.

## Author

**Cheng Vang** — M.S. Data Science, University of St. Thomas (May 2026)
