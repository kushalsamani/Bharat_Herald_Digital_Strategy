-- ======================================================================
-- Bharat Herald | Final SQL Script (MySQL 8+)
-- Author: Kushal Samani
-- Notes:
--   - Run once per session: sets default schema.
--   - Each section answers one Business Request.
--   - The files used here come after Data Cleaning process in Jupyter Notebook. 
--   - Upon importing those csv files, I have removed the word "cleaned" from all the tables.
--   - None of the added dimension tables are imported here. Those files are exclusively used in Power BI.
-- ======================================================================

USE bharat_herald;

-- ======================================================================
-- Business Request 1: Top 3 months with sharpest MoM decline in net_circulation (2019–2024)
-- Fields: city_name, month (YYYY-MM), net_circulation
-- Logic: compute MoM change per city, keep largest negative drops
-- ======================================================================

WITH city_month AS (
  SELECT
    fps.city_id,
    fps.month,                                
    SUM(fps.net_circulation) AS net_circulation
  FROM fact_print_sales AS fps
  WHERE fps.month BETWEEN '2019-01-01' AND '2024-12-31'
  GROUP BY fps.city_id, fps.month
),
city_diffs AS (
  SELECT
    dc.city        AS city_name,
    cm.month,
    cm.net_circulation,
    cm.net_circulation
      - LAG(cm.net_circulation) OVER (
          PARTITION BY cm.city_id
          ORDER BY cm.month
        ) AS mom_change
  FROM city_month AS cm
  JOIN dim_city AS dc
    ON dc.city_id = cm.city_id
)
SELECT
  city_name,
  DATE_FORMAT(month, '%Y-%m') AS month,
  net_circulation
FROM city_diffs
WHERE mom_change IS NOT NULL
  AND mom_change < 0                          -- only declines
ORDER BY mom_change ASC                       -- biggest drop first (most negative)
LIMIT 3;

-- ============================ End of BR-1 =============================



-- ======================================================================
-- Business Request 2: Yearly Revenue Concentration by Category
-- Goal: Identify ad categories contributing > 50% of yearly ad revenue
-- Fields: year, category_name, category_revenue, total_revenue_year, pct_of_year_total
-- ======================================================================

SELECT
  cy.year,
  dac.standard_ad_category AS category_name,
  cy.category_revenue,
  ty.total_revenue_year,
  ROUND((cy.category_revenue / ty.total_revenue_year) * 100, 2) AS pct_of_year_total
FROM
  (
    SELECT
      far.year,
      far.ad_category AS ad_category_id,
      SUM(far.ad_revenue_inr) AS category_revenue
    FROM fact_ad_revenue AS far
    GROUP BY far.year, far.ad_category
  ) AS cy
JOIN (
    SELECT
      far.year,
      SUM(far.ad_revenue_inr) AS total_revenue_year
    FROM fact_ad_revenue AS far
    GROUP BY far.year
) AS ty
  ON ty.year = cy.year
JOIN dim_ad_category AS dac
  ON dac.ad_category_id = cy.ad_category_id
WHERE (cy.category_revenue / ty.total_revenue_year) > 0.5
ORDER BY cy.year, pct_of_year_total DESC;

-- This query will return 0 rows, and I have double checked on Power BI, no single ad category contributes to more than 50% of total ad revenue for that particular year.

-- ============================ End of BR-2 =============================



-- ======================================================================
-- Business Request 3: 2024 Print Efficiency Leaderboard (Top 5)
-- Definitions:
--   copies_printed_2024 = SUM(copies_sold)
--   net_circulation_2024 = SUM(net_circulation)  -- equals SUM(copies_sold - copies_returned)
-- Efficiency = net_circulation_2024 / copies_printed_2024
-- Fields: city_name, copies_printed_2024, net_circulation_2024, efficiency_ratio, efficiency_rank_2024
-- ======================================================================

SELECT
  dc.city AS city_name,
  ce.copies_printed_2024,
  ce.net_circulation_2024,
  ROUND(ce.efficiency_ratio, 4) AS efficiency_ratio,
  (1 + COUNT(ce2.city_id)) AS efficiency_rank_2024
FROM
  (
    SELECT
      fps.city_id,
      SUM(fps.copies_sold) AS copies_printed_2024,
      SUM(fps.net_circulation) AS net_circulation_2024,
      SUM(fps.net_circulation) / NULLIF(SUM(fps.copies_sold), 0) AS efficiency_ratio
    FROM fact_print_sales AS fps
    WHERE fps.month BETWEEN '2024-01-01' AND '2024-12-31'
    GROUP BY fps.city_id
  ) AS ce
JOIN dim_city AS dc
  ON dc.city_id = ce.city_id
LEFT JOIN
  (
    SELECT
      fps.city_id,
      SUM(fps.net_circulation) / NULLIF(SUM(fps.copies_sold), 0) AS efficiency_ratio
    FROM fact_print_sales AS fps
    WHERE fps.month BETWEEN '2024-01-01' AND '2024-12-31'
    GROUP BY fps.city_id
  ) AS ce2
  ON ce2.efficiency_ratio > ce.efficiency_ratio
GROUP BY
  dc.city,
  ce.copies_printed_2024,
  ce.net_circulation_2024,
  ce.efficiency_ratio
ORDER BY
  efficiency_rank_2024 ASC,
  efficiency_ratio DESC
LIMIT 5;

-- ============================ End of BR-3 =============================



-- ======================================================================
-- Business Request 4: Internet Readiness Growth (2021)
-- Goal: City with highest increase from Q1-2021 to Q4-2021 (internet_penetration)
-- Fields: city_name, internet_rate_q1_2021, internet_rate_q4_2021, delta_internet_rate
-- ======================================================================

SELECT
  dc.city AS city_name,
  ROUND(q1.internet_rate_q1_2021, 2) AS internet_rate_q1_2021,
  ROUND(q4.internet_rate_q4_2021, 2) AS internet_rate_q4_2021,
  ROUND(q4.internet_rate_q4_2021 - q1.internet_rate_q1_2021, 2) AS delta_internet_rate
FROM
(
  SELECT
    fcr.city_id,
    fcr.internet_penetration AS internet_rate_q1_2021
  FROM fact_city_readiness AS fcr
  WHERE fcr.year = 2021
    AND fcr.quarter = 'Q1'
) AS q1
JOIN
(
  SELECT
    fcr.city_id,
    fcr.internet_penetration AS internet_rate_q4_2021
  FROM fact_city_readiness AS fcr
  WHERE fcr.year = 2021
    AND fcr.quarter = 'Q4'
) AS q4
  ON q4.city_id = q1.city_id
JOIN dim_city AS dc
  ON dc.city_id = q1.city_id
ORDER BY delta_internet_rate DESC
LIMIT 1;

-- ============================ End of BR-4 =============================



-- ======================================================================
-- Business Request 5: Consistent Multi-Year Decline (2019→2024)
-- Goal: Per city & year: show totals and row-wise flags; add is_declining_both
-- Fields:
--   city_name, year, yearly_net_circulation, yearly_ad_revenue,
--   is_declining_print, is_declining_ad_revenue, is_declining_both
-- Notes:
--   - Flags compare CURRENT year vs PREVIOUS year only (per row).
-- ======================================================================

WITH
years AS (
  SELECT 2019 AS year UNION ALL SELECT 2020 UNION ALL SELECT 2021
  UNION ALL SELECT 2022 UNION ALL SELECT 2023 UNION ALL SELECT 2024
),
edition_to_city AS (
  SELECT fps.edition_id, MIN(fps.city_id) AS city_id
  FROM fact_print_sales AS fps
  GROUP BY fps.edition_id
),
print_year AS (
  SELECT
    fps.city_id,
    YEAR(fps.month) AS year,
    SUM(fps.net_circulation) AS yearly_net_circulation
  FROM fact_print_sales AS fps
  WHERE fps.month BETWEEN '2019-01-01' AND '2024-12-31'
  GROUP BY fps.city_id, YEAR(fps.month)
),
ad_year AS (
  SELECT
    etc.city_id,
    far.year,
    SUM(far.ad_revenue_inr) AS yearly_ad_revenue
  FROM fact_ad_revenue AS far
  JOIN edition_to_city AS etc
    ON etc.edition_id = far.edition_id
  WHERE far.year BETWEEN 2019 AND 2024
  GROUP BY etc.city_id, far.year
),
base AS (
  SELECT
    dc.city AS city_name,
    y.year,
    py.yearly_net_circulation,
    ay.yearly_ad_revenue,
    CASE
      WHEN prev_py.yearly_net_circulation IS NULL OR py.yearly_net_circulation IS NULL THEN 'No'
      WHEN py.yearly_net_circulation < prev_py.yearly_net_circulation THEN 'Yes'
      ELSE 'No'
    END AS is_declining_print,
    CASE
      WHEN prev_ay.yearly_ad_revenue IS NULL OR ay.yearly_ad_revenue IS NULL THEN 'No'
      WHEN ay.yearly_ad_revenue < prev_ay.yearly_ad_revenue THEN 'Yes'
      ELSE 'No'
    END AS is_declining_ad_revenue
  FROM dim_city AS dc
  CROSS JOIN years AS y
  LEFT JOIN print_year AS py
    ON py.city_id = dc.city_id AND py.year = y.year
  LEFT JOIN print_year AS prev_py
    ON prev_py.city_id = dc.city_id AND prev_py.year = y.year - 1
  LEFT JOIN ad_year AS ay
    ON ay.city_id = dc.city_id AND ay.year = y.year
  LEFT JOIN ad_year AS prev_ay
    ON prev_ay.city_id = dc.city_id AND prev_ay.year = y.year - 1
)
SELECT
  base.*,
  CASE
    WHEN base.is_declining_print = 'Yes' AND base.is_declining_ad_revenue = 'Yes' THEN 'Yes'
    ELSE 'No'
  END AS is_declining_both
FROM base
ORDER BY base.city_name, base.year;

-- ============================ End of BR-5 =============================



-- ======================================================================
-- Business Request 6: 2021 Readiness vs Pilot Engagement Outlier
-- Definitions:
--   readiness_score = AVG( (smartphone_penetration + internet_penetration + literacy_rate) / 3 ) * 100
--   users_engaged = downloads_or_accesses * (1 - avg_bounce_rate)  -- assumes bounce is 0..1
--   engagement_rate_pct = (SUM(users_engaged) / SUM(users_reached)) * 100
-- Logic:
--   Rank readiness DESC (1 = highest), engagement ASC (1 = lowest).
--   is_outlier = Yes when readiness_rank_desc = 1 AND engagement_rank_asc <= 3
-- ======================================================================

WITH
readiness AS (
  SELECT
    fcr.city_id,
    AVG( (fcr.smartphone_penetration + fcr.internet_penetration + fcr.literacy_rate) / 3 ) * 100 AS readiness_score
  FROM fact_city_readiness AS fcr
  WHERE fcr.year = 2021
  GROUP BY fcr.city_id
),
engagement AS (
  SELECT
    fdp.city_id,
    COALESCE(
      ( SUM( fdp.downloads_or_accesses * (1 - (fdp.avg_bounce_rate)) )
        / NULLIF(SUM(fdp.users_reached), 0) ) * 100
    , 0) AS engagement_rate_pct
  FROM fact_digital_pilot AS fdp
  WHERE fdp.launch_month BETWEEN '2021-01-01' AND '2021-12-31'
  GROUP BY fdp.city_id
),
rank_ready AS (
  SELECT
    r.city_id,
    r.readiness_score,
    (1 + COUNT(r2.city_id)) AS readiness_rank_desc
  FROM readiness AS r
  LEFT JOIN readiness AS r2
    ON r2.readiness_score > r.readiness_score
  GROUP BY r.city_id, r.readiness_score
),
rank_engage AS (
  SELECT
    e.city_id,
    e.engagement_rate_pct,
    (1 + COUNT(e2.city_id)) AS engagement_rank_asc
  FROM engagement AS e
  LEFT JOIN engagement AS e2
    ON e2.engagement_rate_pct < e.engagement_rate_pct
  GROUP BY e.city_id, e.engagement_rate_pct
)
SELECT
  dc.city AS city_name,
  ROUND(rr.readiness_score, 2) AS readiness_score,
  ROUND(re.engagement_rate_pct, 2) AS engagement_rate_pct,
  rr.readiness_rank_desc,           -- 1 = highest readiness
  re.engagement_rank_asc,           -- 1 = lowest engagement
  CASE
    WHEN rr.readiness_rank_desc = 1 AND re.engagement_rank_asc <= 3 THEN 'Yes'
    ELSE 'No'
  END AS is_outlier
FROM dim_city AS dc
JOIN rank_ready  AS rr ON rr.city_id = dc.city_id
JOIN rank_engage AS re ON re.city_id = dc.city_id

WHERE rr.readiness_rank_desc = 1
  AND re.engagement_rank_asc <= 3
ORDER BY re.engagement_rank_asc ASC, dc.city;

-- ============================ End of BR-6 =============================
