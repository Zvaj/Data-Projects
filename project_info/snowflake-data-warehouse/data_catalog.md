# Data Catalog — Yes Energy Weather Data Warehouse

## Source

| Object | Type | Description |
|--------|------|-------------|
| `CUR_T_SOURCE` | Table | Local copy of Marketplace view `YES_ENERGY__SAMPLE_DATA.YES_ENERGY_SAMPLE.ALL_WEATHER_MV_SAMPLE` |

## Curation Pipeline

| Step | Object | Logic |
|------|--------|-------|
| 1 | `CUR_VW_SOURCE` | Passthrough view of source table |
| 2 | `CUR_VW_T1_DEDUP` | `ROW_NUMBER() OVER (PARTITION BY WBAN, DATETIME_UTC ORDER BY DATETIME_UTC DESC) = 1` |
| 3 | `CUR_VW_T2_STANDARDIZED` | `TRIM(WBAN)`, UTC/Central timezone conversion, minimal lineage object |
| 4 | `CUR_VW_T3_ENRICHED` | Date parts, `is_weekend_ct`, `is_business_hour_ct`, quality flags (`flag_missing_wban`, `flag_missing_ts`, `flag_future_ts`) |
| 5 | `CUR_VW_T4_FILTERED` | `WHERE flag_missing_ts = 'N' AND flag_future_ts = 'N'` |
| 6 | `CUR_VW_CURATED` | Surrogate key `SHA2(wban + ts_utc)`, publish-ready view |

## Feature Engineering (Stored Procedure)

| Object | Type | Fields Added |
|--------|------|-------------|
| `CUR_T6_FEATURES` | Transient table | `prev_ts_utc` (LAG), `gap_minutes` (DATEDIFF), `obs_count_24h` (rolling count), `hour_band` (Night/Morning/Afternoon/Evening), `station_day_seq` (ROW_NUMBER per station/day) |
| `CUR_T6_ENHANCED` | Transient table | Analyst-friendly subset combining curated fields + new features |

## Aggregation Layer

| Object | Type | Description |
|--------|------|-------------|
| `AGG_T_STATION_DAILY` | Transient table | Daily rollups: COUNT, MIN, MAX, AVG, SUM per station |
| `AGG_VW_STATION_HOURLY_PROFILE` | View | Hourly observation count and averages per station |
| `AGG_VW_WEEKEND_VS_WEEKDAY` | View | Weekend vs weekday comparison: COUNT, AVG, MIN, MAX |
| `AGG_VW_HOUR_BAND_SUMMARY` | View | Night/Morning/Afternoon/Evening aggregates |
| `AGG_MV_STATION_WEEK` | Materialized view | Weekly rollup from daily station data |
| `FN_STATION_DAILY_STATS` | Table function | Parameterized: `(wban, start_date, end_date)` → filtered daily stats |

## Automation

| Object | Type | Schedule |
|--------|------|----------|
| `TSK_WEEKLY_ENHANCE_WEATHER` | Task | Every Sunday 4:00 AM Central — calls `SP_ENHANCE_WEATHER_TO_TRANSIENT()` |
