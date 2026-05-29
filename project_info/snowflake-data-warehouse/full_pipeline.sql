//////////////////////////////////////////////

// SEIS 732 Project — Yes Energy

//////////////////////////////////////////////

-- =========================

-- Initial Setup (Context)

-- =========================

USE ROLE TRAINING_ROLE;

CREATE WAREHOUSE IF NOT EXISTS FLAMINGO_WH;

USE WAREHOUSE FLAMINGO_WH;

CREATE DATABASE IF NOT EXISTS FLAMINGO_DB;

USE DATABASE FLAMINGO_DB;

-- Schemas for logical layers

CREATE SCHEMA IF NOT EXISTS CURATION; -- cleaned/enhanced layer

CREATE SCHEMA IF NOT EXISTS AGGREGATION; -- analytics/aggregation layer

USE SCHEMA CURATION;

-- Tag for semantic governance (apply to all new objects)

CREATE OR REPLACE TAG PROJECT COMMENT = 'Marks curated/agg objects for
SEIS 732';

SET project_tag_value = 'yes_energy';

-- ============================================

-- Source discovery (run these once to confirm)

-- ============================================

SHOW SCHEMAS IN DATABASE YES_ENERGY__SAMPLE_DATA;

SHOW VIEWS IN DATABASE YES_ENERGY__SAMPLE_DATA;

SHOW VIEWS IN SCHEMA YES_ENERGY__SAMPLE_DATA.YES_ENERGY_SAMPLE;

-- ==================================================

-- Parametrize the source (EDIT THESE 2 VARIABLES!)

-- ==================================================

SET SRC_DB = 'YES_ENERGY__SAMPLE_DATA';

SET SRC_SCHEMA = 'YES_ENERGY_SAMPLE';

SET SRC_OBJECT = 'ALL_WEATHER_MV_SAMPLE';

SET SRC_FULL = CONCAT($SRC_DB, '.', $SRC_SCHEMA, '.', $SRC_OBJECT);

-- ==================================================

-- Step 0: Create a local table copy from shared view

-- ==================================================

-- Marketplace data is read-only, so make your own physical table

USE DATABASE FLAMINGO_DB;

USE SCHEMA CURATION;

CREATE OR REPLACE TABLE CUR_T_SOURCE AS

SELECT * FROM IDENTIFIER($SRC_FULL);

ALTER TABLE CUR_T_SOURCE SET TAG PROJECT = $project_tag_value;

-- Quick check

SELECT COUNT(*) AS row_count FROM CUR_T_SOURCE;

-- ================================

-- Worksheet #1: Curation (Views)

-- ================================

-- CUR_ naming, all CREATE OR REPLACE, all tagged

-- Step 1: Passthrough source view (now from your local table)

CREATE OR REPLACE VIEW FLAMINGO_DB.CURATION.CUR_VW_SOURCE AS

SELECT * FROM FLAMINGO_DB.CURATION.CUR_T_SOURCE;

ALTER VIEW FLAMINGO_DB.CURATION.CUR_VW_SOURCE SET TAG PROJECT =
$project_tag_value;

-- Peek at data

SELECT * FROM FLAMINGO_DB.CURATION.CUR_VW_SOURCE LIMIT 5;

-- Step 2: De-duplicate (pick latest per natural key)

CREATE OR REPLACE VIEW FLAMINGO_DB.CURATION.CUR_VW_T1_DEDUP AS

SELECT *

FROM FLAMINGO_DB.CURATION.CUR_VW_SOURCE

QUALIFY ROW_NUMBER() OVER (

PARTITION BY WBAN, DATETIME_UTC

ORDER BY DATETIME_UTC DESC

) = 1;

ALTER VIEW FLAMINGO_DB.CURATION.CUR_VW_T1_DEDUP SET TAG PROJECT =
$project_tag_value;

-- Step 3: Standardize / time conversions / safe trimming

CREATE OR REPLACE VIEW FLAMINGO_DB.CURATION.CUR_VW_T2_STANDARDIZED AS

SELECT

TRIM(WBAN) AS wban,

/* Attach UTC tz info and keep it in UTC */

CONVERT_TIMEZONE('UTC','UTC', DATETIME_UTC)::TIMESTAMP_TZ AS ts_utc,

/* Convert to America/Chicago for local analytics */

CONVERT_TIMEZONE('UTC','America/Chicago', DATETIME_UTC)::TIMESTAMP_TZ AS
ts_ct,

/* Minimal lineage object */

OBJECT_CONSTRUCT_KEEP_NULL(

'WBAN', WBAN,

'DATETIME_UTC', DATETIME_UTC

) AS _src_min

FROM FLAMINGO_DB.CURATION.CUR_VW_T1_DEDUP;

ALTER VIEW FLAMINGO_DB.CURATION.CUR_VW_T2_STANDARDIZED

SET TAG PROJECT = $project_tag_value;

-- Step 4: Enrichments & flags (date parts, weekend, business hour)

CREATE OR REPLACE VIEW FLAMINGO_DB.CURATION.CUR_VW_T3_ENRICHED AS

SELECT

*,

CAST(ts_utc AS DATE) AS date_utc,

CAST(ts_ct AS DATE) AS date_ct,

EXTRACT(HOUR FROM ts_ct) AS hour_ct,

TO_VARCHAR(ts_ct, 'DY') AS weekday_ct_abbr,

IFF(DAYOFWEEKISO(ts_ct) IN (6,7), 'Y','N') AS is_weekend_ct,

IFF(EXTRACT(HOUR FROM ts_ct) BETWEEN 8 AND 17, 'Y','N') AS
is_business_hour_ct,

-- data-quality flags based on minimal fields

IFF(wban IS NULL OR wban = '', 'Y','N') AS flag_missing_wban,

IFF(ts_utc IS NULL, 'Y','N') AS flag_missing_ts,

IFF(ts_utc > CURRENT_TIMESTAMP(), 'Y','N') AS flag_future_ts

FROM FLAMINGO_DB.CURATION.CUR_VW_T2_STANDARDIZED;

ALTER VIEW FLAMINGO_DB.CURATION.CUR_VW_T3_ENRICHED SET TAG PROJECT =
$project_tag_value;

-- Step 5: Conservative filtering (drop missing/future timestamps)

CREATE OR REPLACE VIEW FLAMINGO_DB.CURATION.CUR_VW_T4_FILTERED AS

SELECT *

FROM FLAMINGO_DB.CURATION.CUR_VW_T3_ENRICHED

WHERE flag_missing_ts = 'N'

AND flag_future_ts = 'N';

ALTER VIEW FLAMINGO_DB.CURATION.CUR_VW_T4_FILTERED SET TAG PROJECT =
$project_tag_value;

-- Step 6: Publish curated view with surrogate key

CREATE OR REPLACE VIEW FLAMINGO_DB.CURATION.CUR_VW_CURATED AS

SELECT

SHA2(TO_VARCHAR(wban) || '|' || TO_VARCHAR(ts_utc), 256) AS obs_sk,

wban,

ts_utc,

ts_ct,

date_utc,

date_ct,

hour_ct,

weekday_ct_abbr,

is_weekend_ct,

is_business_hour_ct,

flag_missing_wban

FROM FLAMINGO_DB.CURATION.CUR_VW_T4_FILTERED;

ALTER VIEW FLAMINGO_DB.CURATION.CUR_VW_CURATED SET TAG PROJECT =
$project_tag_value;

-- ================================

-- Verification

-- ================================

-- Confirm record counts

SELECT COUNT(*) AS curated_row_count FROM
FLAMINGO_DB.CURATION.CUR_VW_CURATED;

-- Preview

SELECT * FROM FLAMINGO_DB.CURATION.CUR_VW_CURATED LIMIT 10;

-- ================================

-- Worksheet #2: Stored Procedure -> TRANSIENT TABLES

-- ================================

CREATE OR REPLACE PROCEDURE
FLAMINGO_DB.CURATION.SP_ENHANCE_WEATHER_TO_TRANSIENT()

RETURNS STRING

LANGUAGE SQL

EXECUTE AS CALLER

AS

$$

BEGIN

/* 1) Build FEATURES table with new transforms (distinct from Wk#1):

- gap_minutes between observations (LAG + DATEDIFF)

- obs_count_24h via correlated subquery (no RANGE)

- hour_band bucket

- station_day_seq within station/day

*/

CREATE OR REPLACE TRANSIENT TABLE FLAMINGO_DB.CURATION.CUR_T6_FEATURES
AS

WITH base AS (

SELECT

c.*,

LAG(c.ts_utc) OVER (PARTITION BY c.wban ORDER BY c.ts_utc) AS
prev_ts_utc

FROM FLAMINGO_DB.CURATION.CUR_VW_CURATED c

),

gaps AS (

SELECT

base.*,

DATEDIFF('minute', prev_ts_utc, ts_utc) AS gap_minutes

FROM base

)

SELECT

gaps.*,

/* Robust 24h rolling count without RANGE:

count all observations for same station in [ts_utc-24h, ts_utc] */

(

SELECT COUNT(1)

FROM FLAMINGO_DB.CURATION.CUR_VW_CURATED s2

WHERE s2.wban = gaps.wban

AND s2.ts_utc BETWEEN DATEADD(hour, -24, gaps.ts_utc) AND gaps.ts_utc

) AS obs_count_24h,

CASE

WHEN hour_ct BETWEEN 0 AND 5 THEN 'Night'

WHEN hour_ct BETWEEN 6 AND 11 THEN 'Morning'

WHEN hour_ct BETWEEN 12 AND 17 THEN 'Afternoon'

ELSE 'Evening'

END AS hour_band,

ROW_NUMBER() OVER (PARTITION BY wban, date_ct ORDER BY ts_utc) AS
station_day_seq

FROM gaps;

/* Tag + optional clustering key */

ALTER TABLE FLAMINGO_DB.CURATION.CUR_T6_FEATURES

SET TAG FLAMINGO_DB.CURATION.PROJECT = 'yes_energy';

ALTER TABLE FLAMINGO_DB.CURATION.CUR_T6_FEATURES

CLUSTER BY (WBAN, DATE_CT);

/* 2) Consumer table: curated subset + new features */

CREATE OR REPLACE TRANSIENT TABLE FLAMINGO_DB.CURATION.CUR_T6_ENHANCED
AS

SELECT

obs_sk, wban, ts_utc, ts_ct, date_utc, date_ct, hour_ct,

weekday_ct_abbr, is_weekend_ct, is_business_hour_ct, flag_missing_wban,

gap_minutes, obs_count_24h, hour_band, station_day_seq

FROM FLAMINGO_DB.CURATION.CUR_T6_FEATURES;

ALTER TABLE FLAMINGO_DB.CURATION.CUR_T6_ENHANCED

SET TAG FLAMINGO_DB.CURATION.PROJECT = 'yes_energy';

RETURN 'OK: CUR_T6_FEATURES & CUR_T6_ENHANCED (transient) created with
new transforms.';

END;

$$;

-- Run it:

CALL FLAMINGO_DB.CURATION.SP_ENHANCE_WEATHER_TO_TRANSIENT();

-- Quick checks:

SELECT COUNT(*) FROM FLAMINGO_DB.CURATION.CUR_T6_FEATURES;

SELECT COUNT(*) FROM FLAMINGO_DB.CURATION.CUR_T6_ENHANCED;

SELECT * FROM FLAMINGO_DB.CURATION.CUR_T6_ENHANCED LIMIT 10;

-- ================================

-- Worksheet #3: Aggregation Layer

-- ================================

USE ROLE TRAINING_ROLE;

USE WAREHOUSE FLAMINGO_WH;

USE DATABASE FLAMINGO_DB;

-- Put aggregation objects in a DIFFERENT schema than curation

CREATE SCHEMA IF NOT EXISTS AGGREGATION;

USE SCHEMA AGGREGATION;

-- NOTE: Assumes CURATION.CUR_T6_ENHANCED exists (from Wk #2).

-- If not, swap source to CURATION.CUR_VW_ENHANCED (view).

-- ------------- Step 1: Four different aggregated objects -------------

-- 1) Daily station summary → **TABLE** (COUNT, MIN, MAX, AVG, SUM)

CREATE OR REPLACE TRANSIENT TABLE AGG_T_STATION_DAILY AS

SELECT

e.wban,

e.date_ct,

COUNT(*) AS obs_count,

MIN(e.ts_ct) AS first_obs_ct,

MAX(e.ts_ct) AS last_obs_ct,

AVG(e.gap_minutes) AS avg_gap_minutes,

MAX(e.gap_minutes) AS max_gap_minutes,

SUM(IFF(e.flag_missing_wban = 'Y', 1, 0)) AS rows_with_missing_wban

FROM FLAMINGO_DB.CURATION.CUR_T6_ENHANCED e

GROUP BY e.wban, e.date_ct;

ALTER TABLE AGG_T_STATION_DAILY

SET TAG FLAMINGO_DB.CURATION.PROJECT = 'yes_energy';

-- 2) Hour-of-day profile per station (COUNT, AVG) → VIEW

CREATE OR REPLACE VIEW AGG_VW_STATION_HOURLY_PROFILE AS

SELECT

e.wban,

e.hour_ct,

COUNT(*) AS obs_count,

AVG(e.obs_count_24h) AS avg_obs_count_24h

FROM FLAMINGO_DB.CURATION.CUR_T6_ENHANCED e

GROUP BY e.wban, e.hour_ct;

ALTER VIEW AGG_VW_STATION_HOURLY_PROFILE

SET TAG FLAMINGO_DB.CURATION.PROJECT = 'yes_energy';

-- 3) Weekend vs Weekday comparison (COUNT, AVG, MIN, MAX) → VIEW

CREATE OR REPLACE VIEW AGG_VW_WEEKEND_VS_WEEKDAY AS

SELECT

e.wban,

e.is_weekend_ct,

COUNT(*) AS obs_count,

AVG(e.gap_minutes) AS avg_gap_minutes,

MIN(e.gap_minutes) AS min_gap_minutes,

MAX(e.gap_minutes) AS max_gap_minutes

FROM FLAMINGO_DB.CURATION.CUR_T6_ENHANCED e

GROUP BY e.wban, e.is_weekend_ct;

ALTER VIEW AGG_VW_WEEKEND_VS_WEEKDAY

SET TAG FLAMINGO_DB.CURATION.PROJECT = 'yes_energy';

-- 4) Hour-band summary (Night/Morning/Afternoon/Evening) (COUNT, AVG) →
VIEW

CREATE OR REPLACE VIEW AGG_VW_HOUR_BAND_SUMMARY AS

SELECT

e.wban,

e.hour_band,

COUNT(*) AS obs_count,

AVG(e.obs_count_24h) AS avg_obs_count_24h

FROM FLAMINGO_DB.CURATION.CUR_T6_ENHANCED e

GROUP BY e.wban, e.hour_band;

ALTER VIEW AGG_VW_HOUR_BAND_SUMMARY

SET TAG FLAMINGO_DB.CURATION.PROJECT = 'yes_energy';

-- ------------- Step 2: Materialized view (must use a TABLE as source)
-------------

CREATE OR REPLACE MATERIALIZED VIEW AGG_MV_STATION_WEEK AS

SELECT

d.wban,

DATE_TRUNC('week', d.date_ct) AS week_start,

SUM(d.obs_count) AS week_obs_count,

MIN(d.first_obs_ct) AS week_first_obs_ct,

MAX(d.last_obs_ct) AS week_last_obs_ct,

AVG(d.avg_gap_minutes) AS week_avg_gap_minutes,

MAX(d.max_gap_minutes) AS week_max_gap_minutes

FROM AGG_T_STATION_DAILY d

GROUP BY d.wban, DATE_TRUNC('week', d.date_ct);

SHOW OBJECTS LIKE 'AGG_MV_STATION_WEEK' IN SCHEMA
FLAMINGO_DB.AGGREGATION;

-- Create a wrapper VIEW over the MV (this is what you will tag)

CREATE OR REPLACE VIEW FLAMINGO_DB.AGGREGATION.AGG_VW_STATION_WEEK AS

SELECT *

FROM FLAMINGO_DB.AGGREGATION.AGG_MV_STATION_WEEK;

-- Switch context to where your tag 'PROJECT' lives so short name
resolves

USE DATABASE FLAMINGO_DB;

USE SCHEMA CURATION;

-- Tag the *wrapper view* (regular views tag cleanly)

ALTER VIEW FLAMINGO_DB.AGGREGATION.AGG_VW_STATION_WEEK

SET TAG PROJECT = 'yes_energy';

-- With context set to FLAMINGO_DB.CURATION:

ALTER TABLE FLAMINGO_DB.AGGREGATION.AGG_T_STATION_DAILY SET TAG PROJECT
= 'yes_energy';

ALTER VIEW FLAMINGO_DB.AGGREGATION.AGG_VW_STATION_HOURLY_PROFILE SET TAG
PROJECT = 'yes_energy';

ALTER VIEW FLAMINGO_DB.AGGREGATION.AGG_VW_WEEKEND_VS_WEEKDAY SET TAG
PROJECT = 'yes_energy';

ALTER VIEW FLAMINGO_DB.AGGREGATION.AGG_VW_HOUR_BAND_SUMMARY SET TAG
PROJECT = 'yes_energy';

-- and now the wrapper over the MV:

ALTER VIEW FLAMINGO_DB.AGGREGATION.AGG_VW_STATION_WEEK SET TAG PROJECT =
'yes_energy';

-- ------------- Quick sanity checks (optional) -------------

-- SELECT * FROM AGG_T_STATION_DAILY LIMIT 10;

-- SELECT * FROM AGG_VW_STATION_HOURLY_PROFILE LIMIT 10;

-- SELECT * FROM AGG_VW_WEEKEND_VS_WEEKDAY LIMIT 10;

-- SELECT * FROM AGG_VW_HOUR_BAND_SUMMARY LIMIT 10;

-- SELECT * FROM AGG_MV_STATION_WEEK LIMIT 10;

-- =========================================

-- Worksheet #4: Table Function

-- =========================================

USE ROLE TRAINING_ROLE;

USE WAREHOUSE FLAMINGO_WH;

USE DATABASE FLAMINGO_DB;

USE SCHEMA AGGREGATION;

CREATE OR REPLACE FUNCTION
FLAMINGO_DB.AGGREGATION.FN_STATION_DAILY_STATS(

p_wban STRING,

p_start_date DATE,

p_end_date DATE

)

RETURNS TABLE (

wban STRING,

date_ct DATE,

obs_count NUMBER,

first_obs_ct TIMESTAMP_TZ,

last_obs_ct TIMESTAMP_TZ,

avg_gap_minutes NUMBER(36,6),

max_gap_minutes NUMBER(36,6),

rows_with_missing_wban NUMBER

)

LANGUAGE SQL

AS

$$

SELECT

d.wban,

d.date_ct,

d.obs_count,

d.first_obs_ct,

d.last_obs_ct,

d.avg_gap_minutes,

d.max_gap_minutes,

d.rows_with_missing_wban

FROM FLAMINGO_DB.AGGREGATION.AGG_T_STATION_DAILY d

WHERE d.wban = p_wban

AND (p_start_date IS NULL OR d.date_ct >= p_start_date)

AND (p_end_date IS NULL OR d.date_ct <= p_end_date)

ORDER BY d.date_ct

$$;

SELECT *

FROM TABLE(FLAMINGO_DB.AGGREGATION.FN_STATION_DAILY_STATS(

'03011'::STRING,

NULL::DATE,

NULL::DATE

));

-- Using SQL DATE literals:

SELECT *

FROM TABLE(FLAMINGO_DB.AGGREGATION.FN_STATION_DAILY_STATS(

'03011'::STRING,

DATE '2023-01-01',

DATE '2023-02-01'

));

-- OR using TO_DATE:

SELECT *

FROM TABLE(FLAMINGO_DB.AGGREGATION.FN_STATION_DAILY_STATS(

'03011'::STRING,

TO_DATE('2023-01-01'),

TO_DATE('2023-02-01')

));

SHOW FUNCTIONS LIKE 'FN_STATION_DAILY_STATS' IN SCHEMA
FLAMINGO_DB.AGGREGATION;

-- ===================================================

-- Worksheet #5: Data Sharing (Being SKIPPED via professor announcement)

-- ===================================================

-- ===================================================

-- Worksheet #6: Task to run SP_ENHANCE_WEATHER_TO_TRANSIENT weekly

-- ===================================================

USE ROLE TRAINING_ROLE;

USE WAREHOUSE FLAMINGO_WH;

USE DATABASE FLAMINGO_DB;

USE SCHEMA CURATION;

-- Step 1: Create or replace the task

CREATE OR REPLACE TASK FLAMINGO_DB.CURATION.TSK_WEEKLY_ENHANCE_WEATHER

WAREHOUSE = FLAMINGO_WH

SCHEDULE = 'USING CRON 0 4 * * SUN America/Chicago'

COMMENT = 'Runs every Sunday at 4 AM to refresh transient curated
tables'

AS

CALL FLAMINGO_DB.CURATION.SP_ENHANCE_WEATHER_TO_TRANSIENT();

-- Step 2: Enable the task (for testing)

ALTER TASK FLAMINGO_DB.CURATION.TSK_WEEKLY_ENHANCE_WEATHER RESUME;

-- Optional: Manually test run

EXECUTE TASK FLAMINGO_DB.CURATION.TSK_WEEKLY_ENHANCE_WEATHER;

-- Step 3: Verify the status

SHOW TASKS IN SCHEMA FLAMINGO_DB.CURATION;

-- Step 4: Suspend the task after verifying

ALTER TASK FLAMINGO_DB.CURATION.TSK_WEEKLY_ENHANCE_WEATHER SUSPEND;

-- ===================================================

-- Worksheet #6: Task to run SP_ENHANCE_WEATHER_TO_TRANSIENT weekly

-- ===================================================

Dataset name & description

Dataset: Yes Energy — Sample Data (Snowflake Marketplace)

What it is: A free public version you used in this project contains a
smaller sample — about two years of data for Texas (ERCOT). Yes Energy
collects and organizes detailed data about the energy market — like
electricity prices, demand, and renewable generation — from the time
each regional energy operator (ISO) started. They’ve built one of the
most complete and accurate databases for studying how energy markets
behave. This dataset helps analysts and researchers understand and model
how energy prices change, what factors influence them (like weather or
renewable energy), and how to make better decisions for trading or
managing energy assets.

Where to find my work (schemas & naming)

-   Database: FLAMINGO_DB

-   Schemas:

    -   CURATION → cleaned/enhanced pass-through and curated views, plus
          transient feature tables

    -   AGGREGATION → rollups, profile views, and a weekly materialized
          view

-   Naming convention:

    -   CUR_VW_* = curation views (pipeline steps)

    -   CUR_T* = curated/feature tables (transient when appropriate)

    -   AGG_VW_* = aggregated views

    -   AGG_T_* = aggregated tables (materialized rollups)

    -   AGG_MV_* = materialized views in aggregation

    -   Tagging: All new tables/views tagged with PROJECT='yes_energy'
          for easy discovery.

Mini data catalog (custom fields & curation logic)

Source ingestion

-   CUR_T_SOURCE (table): Local copy of Marketplace view
      YES_ENERGY__SAMPLE_DATA.YES_ENERGY_SAMPLE.ALL_WEATHER_MV_SAMPLE
      for write/compute flexibility.
      Tag: PROJECT='yes_energy'.

Curation pipeline (views)

1.  CUR_VW_SOURCE

    -   Pass-through of CUR_T_SOURCE to begin view-based
          transformations.

2.  CUR_VW_T1_DEDUP

    -   De-duplication: ROW_NUMBER() OVER (PARTITION BY WBAN,
          DATETIME_UTC ORDER BY DATETIME_UTC DESC)=1 keeps the most
          recent record per (station, timestamp).

3.  CUR_VW_T2_STANDARDIZED

    -   wban = TRIM(WBAN) (key hygiene).

    -   ts_utc = CONVERT_TIMEZONE('UTC','UTC',
          DATETIME_UTC)::TIMESTAMP_TZ (typed UTC).

    -   ts_ct = CONVERT_TIMEZONE('UTC','America/Chicago', DATETIME_UTC)
          (local analytics clock).

    -   _src_min =
          OBJECT_CONSTRUCT_KEEP_NULL('WBAN',WBAN,'DATETIME_UTC',DATETIME_UTC)
          (minimal lineage object).

4.  CUR_VW_T3_ENRICHED

    -   Date parts: date_utc, date_ct, hour_ct, weekday_ct_abbr.

    -   Operational flags:

        -   is_weekend_ct = IFF(DAYOFWEEKISO(ts_ct) IN (6,7),'Y','N')

        -   is_business_hour_ct = IFF(EXTRACT(HOUR FROM ts_ct) BETWEEN 8
              AND 17,'Y','N')

    -   Data quality flags:

        -   flag_missing_wban = IFF(wban IS NULL OR wban='','Y','N')

        -   flag_missing_ts = IFF(ts_utc IS NULL,'Y','N')

        -   flag_future_ts = IFF(ts_utc > CURRENT_TIMESTAMP(),'Y','N').

5.  CUR_VW_T4_FILTERED

    -   Conservative filtering: WHERE flag_missing_ts='N' AND
          flag_future_ts='N' removes obviously bad rows.

6.  CUR_VW_CURATED (publish)

    -   Surrogate key obs_sk =
          SHA2(TO_VARCHAR(wban)||'|'||TO_VARCHAR(ts_utc),256) for stable
          joins.

    -   Carries forward useful analysis fields: timestamps, date parts,
          weekend/business-hour flags, and core DQ flags.

New transformations packaged as transient tables (stored procedure
output, Worksheet #2)

-   CUR_T6_FEATURES (transient):

    -   prev_ts_utc via LAG(ts_utc) per station.

    -   gap_minutes = DATEDIFF('minute', prev_ts_utc, ts_utc)
          (observation spacing).

    -   obs_count_24h = correlated count in [ts_utc-24h, ts_utc] per
          station (robust rolling volume).

    -   hour_band bucket (Night/Morning/Afternoon/Evening) from hour_ct.

    -   station_day_seq = ROW_NUMBER() per (wban, date_ct) (intra-day
          ordering).

-   CUR_T6_ENHANCED (transient): Analyst-friendly subset = CURATED + the
      features above.

-   Procedure: SP_ENHANCE_WEATHER_TO_TRANSIENT() creates/refreshes both,
      CREATE OR REPLACE, tagged.

Aggregation layer (examples)

-   AGG_T_STATION_DAILY (transient table): Daily station rollups with
      COUNT, MIN, MAX, AVG, SUM on curated/enhanced fields.

-   Views:

    -   AGG_VW_STATION_HOURLY_PROFILE (COUNT, AVG by hour).

    -   AGG_VW_WEEKEND_VS_WEEKDAY (COUNT, AVG, MIN, MAX split by
          weekend).

    -   AGG_VW_HOUR_BAND_SUMMARY (COUNT, AVG by hour_band).

-   Materialized view: AGG_MV_STATION_WEEK (weekly rollup from
      AGG_T_STATION_DAILY).

-   Wrapper view for tagging: AGG_VW_STATION_WEEK selects from the MV.

Table function (Worksheet #4)

-   FN_STATION_DAILY_STATS(wban, start_date, end_date) → returns rows
      from AGG_T_STATION_DAILY filtered by station/date, with daily
      counts and gap stats; called via SELECT * FROM TABLE(…);.

Scheduling (Worksheet #6)

-   Task: TSK_WEEKLY_ENHANCE_WEATHER runs
      SP_ENHANCE_WEATHER_TO_TRANSIENT() every Sunday 4:00 AM
      America/Chicago (USING CRON 0 4 * * SUN America/Chicago); tested
      with EXECUTE TASK, then suspended.

How colleagues can use it (quick pointers)

-   Explore cleaned weather rows: SELECT * FROM
      FLAMINGO_DB.CURATION.CUR_VW_CURATED LIMIT 50;

-   Daily station stats: SELECT * FROM
      FLAMINGO_DB.AGGREGATION.AGG_T_STATION_DAILY WHERE WBAN='03011'
      ORDER BY DATE_CT;

-   On-demand station report (table function):
      SELECT * FROM
      TABLE(FLAMINGO_DB.AGGREGATION.FN_STATION_DAILY_STATS('03011', DATE
      '2023-01-01', DATE '2023-02-01'));

-   Weekly summaries: SELECT * FROM
      FLAMINGO_DB.AGGREGATION.AGG_VW_STATION_WEEK WHERE WBAN='03011';

Final Thoughts:

When creating my tiles, I was hoping for some meaningful graphs that can
derive some insightful data such as understanding how energy prices
change, what factors influence them (like weather or renewable energy),
and how to make better decisions for trading or managing energy assets,
but it was difficult to achieve. This may have been caused by the data
itself or just when I was making my aggregated and curated views/tables.
Then again, it might be because I am used to making graphs in
python/RStudio.

If I was to redo this final project, it would be to pick a dataset where
I can derive more meaningful insights and create “better” graphs.
Besides that, this final project has taught me how to do everything else
decently. Not to the point where I would consider myself an expert, but
better than someone who has no idea what data warehousing is, especially
with the use of Snowflake.
