-- 01_semantic_model.sql : builds the analytical (semantic) layer as tables in schema "semantic".
-- Portable between PostgreSQL and DuckDB. Source tables: schema "kaggle".
--   PostgreSQL: psql -h localhost -p 5432 -U <user> -d asb_oltp -f sql/01_semantic_model.sql
--   DuckDB:     duckdb /asb_materials/setup/03_duckdb_databases/asb_oltp.duckdb < sql/01_semantic_model.sql
--
-- GRAINS
--   stg_orders / fact_orders   1 row per order        (orders, order value, delivery, reviews)
--   agg_order_*                1 row per order        (children pre-aggregated BEFORE joining)
--   fact_order_items           1 row per order item   (sales by category / seller)
--   dim_customer               1 row per customer_unique_id (a person; customer_id is per order)
--   dim_product / dim_seller   1 row per product_id / seller_id
--   dim_date                   1 row per calendar date

-- Rebuilt from scratch on every run. Physical tables (not views) so queries and Power BI stay fast.
DROP SCHEMA IF EXISTS semantic CASCADE;
CREATE SCHEMA semantic;

-- ------------------------------------------------------------ staging
CREATE TABLE semantic.stg_orders AS
SELECT
  order_id, customer_id, order_status,
  CAST(NULLIF(CAST(order_purchase_timestamp      AS VARCHAR), '') AS TIMESTAMP) AS purchase_ts,
  CAST(NULLIF(CAST(order_approved_at             AS VARCHAR), '') AS TIMESTAMP) AS approved_ts,
  CAST(NULLIF(CAST(order_delivered_carrier_date  AS VARCHAR), '') AS TIMESTAMP) AS carrier_ts,
  CAST(NULLIF(CAST(order_delivered_customer_date AS VARCHAR), '') AS TIMESTAMP) AS delivered_ts,
  CAST(NULLIF(CAST(order_estimated_delivery_date AS VARCHAR), '') AS TIMESTAMP) AS estimated_ts
FROM kaggle.olist_orders_dataset;

-- ------------------------------------- pre-aggregations to order grain
CREATE TABLE semantic.agg_order_items AS
SELECT order_id,
       COUNT(*)                  AS items_count,
       COUNT(DISTINCT seller_id) AS sellers_count,
       SUM(price)                AS items_value,
       SUM(freight_value)        AS freight_value
FROM kaggle.olist_order_items_dataset
GROUP BY order_id;

-- payment_type_primary = the payment type with the largest value in the order
CREATE TABLE semantic.agg_order_payments AS
WITH ranked AS (
  SELECT order_id, payment_type, payment_value, payment_installments,
         ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY payment_value DESC, payment_sequential) AS rn
  FROM kaggle.olist_order_payments_dataset
)
SELECT order_id,
       SUM(payment_value)                              AS payment_value,
       MAX(payment_installments)                       AS installments_max,
       COUNT(*)                                        AS payment_records,
       MAX(CASE WHEN rn = 1 THEN payment_type END)     AS payment_type_primary
FROM ranked
GROUP BY order_id;

-- Some orders have several reviews: keep the most recent so each order counts once.
CREATE TABLE semantic.agg_order_reviews AS
SELECT order_id, review_score
FROM (
  SELECT order_id, review_score,
         ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_answer_timestamp DESC, review_id) AS rn
  FROM kaggle.olist_order_reviews_dataset
) r
WHERE rn = 1;

-- ------------------------------------------------------- dimensions
-- Repeat customer = 2+ valid orders (not canceled / unavailable) by the same customer_unique_id.
CREATE TABLE semantic.dim_customer AS
WITH c_orders AS (
  SELECT c.customer_unique_id, o.order_id, o.purchase_ts, o.order_status, c.customer_state, c.customer_city
  FROM semantic.stg_orders o
  JOIN kaggle.olist_customers_dataset c ON c.customer_id = o.customer_id
),
latest AS (
  SELECT customer_unique_id, customer_state, customer_city,
         ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts DESC, order_id) AS rn
  FROM c_orders
),
cnt AS (
  SELECT customer_unique_id,
         COUNT(*) AS orders_total,
         SUM(CASE WHEN order_status NOT IN ('canceled', 'unavailable') THEN 1 ELSE 0 END) AS valid_orders,
         MIN(purchase_ts) AS first_purchase_ts,
         MAX(purchase_ts) AS last_purchase_ts
  FROM c_orders
  GROUP BY customer_unique_id
)
SELECT cnt.customer_unique_id,
       l.customer_state AS state,
       l.customer_city  AS city,
       cnt.orders_total, cnt.valid_orders, cnt.first_purchase_ts, cnt.last_purchase_ts,
       CASE WHEN cnt.valid_orders >= 2 THEN 'Repeat'
            WHEN cnt.valid_orders = 1  THEN 'One-time'
            ELSE 'No valid order' END AS customer_type
FROM cnt
JOIN latest l ON l.customer_unique_id = cnt.customer_unique_id AND l.rn = 1;

CREATE TABLE semantic.dim_product AS
SELECT p.product_id,
       p.product_category_name AS category_pt,
       COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category_en
FROM kaggle.olist_products_dataset p
LEFT JOIN kaggle.product_category_name_translation t ON t.product_category_name = p.product_category_name;

CREATE TABLE semantic.dim_seller AS
SELECT seller_id, seller_city, seller_state FROM kaggle.olist_sellers_dataset;

CREATE TABLE semantic.dim_date AS
SELECT
  CAST(d AS DATE)                          AS date_key,
  CAST(EXTRACT(YEAR  FROM d) AS INTEGER)   AS year,
  CAST(EXTRACT(MONTH FROM d) AS INTEGER)   AS month_num,
  CASE CAST(EXTRACT(MONTH FROM d) AS INTEGER)
    WHEN 1 THEN 'Jan' WHEN 2 THEN 'Feb' WHEN 3 THEN 'Mar' WHEN 4 THEN 'Apr'
    WHEN 5 THEN 'May' WHEN 6 THEN 'Jun' WHEN 7 THEN 'Jul' WHEN 8 THEN 'Aug'
    WHEN 9 THEN 'Sep' WHEN 10 THEN 'Oct' WHEN 11 THEN 'Nov' ELSE 'Dec' END AS month_name,
  CAST(EXTRACT(YEAR FROM d) AS VARCHAR) || '-' || LPAD(CAST(EXTRACT(MONTH FROM d) AS VARCHAR), 2, '0') AS year_month,
  CAST(DATE_TRUNC('month', d) AS DATE)     AS month_start,
  CAST(EXTRACT(QUARTER FROM d) AS INTEGER) AS quarter,
  CAST(EXTRACT(DOW FROM d) AS INTEGER)     AS day_of_week_num      -- 0 = Sunday
FROM generate_series(DATE '2016-09-01', DATE '2018-12-31', INTERVAL '1 day') AS t(d);

-- ----------------------------------------------------- fact: orders
-- Delivery metrics only for status = 'delivered' with a delivered date.
-- delay_days > 0 means the order arrived AFTER the estimated date.
CREATE TABLE semantic.fact_orders AS
WITH base AS (
  SELECT
    o.order_id, c.customer_unique_id, c.customer_state, c.customer_city, o.order_status,
    o.purchase_ts,
    CAST(o.purchase_ts AS DATE)                      AS purchase_date,
    CAST(DATE_TRUNC('month', o.purchase_ts) AS DATE) AS purchase_month,
    CASE WHEN o.order_status NOT IN ('canceled', 'unavailable') THEN 1 ELSE 0 END AS is_valid_order,
    CASE WHEN o.order_status = 'delivered' THEN 1 ELSE 0 END                      AS is_delivered,
    COALESCE(i.items_count, 0)   AS items_count,
    COALESCE(i.sellers_count, 0) AS sellers_count,
    COALESCE(i.items_value, 0)   AS items_value,
    COALESCE(i.freight_value, 0) AS freight_value,
    COALESCE(i.items_value, 0) + COALESCE(i.freight_value, 0) AS order_value,
    p.payment_value, p.payment_type_primary, p.installments_max,
    CASE WHEN o.order_status = 'delivered' AND o.delivered_ts IS NOT NULL
         THEN CAST(o.delivered_ts AS DATE) END       AS delivered_date,
    CAST(o.estimated_ts AS DATE)                     AS estimated_date,
    r.review_score,
    CASE WHEN r.review_score IS NULL THEN 0 ELSE 1 END AS has_review,
    cu.customer_type
  FROM semantic.stg_orders o
  JOIN kaggle.olist_customers_dataset c   ON c.customer_id = o.customer_id
  LEFT JOIN semantic.agg_order_items i    ON i.order_id = o.order_id
  LEFT JOIN semantic.agg_order_payments p ON p.order_id = o.order_id
  LEFT JOIN semantic.agg_order_reviews r  ON r.order_id = o.order_id
  LEFT JOIN semantic.dim_customer cu      ON cu.customer_unique_id = c.customer_unique_id
)
SELECT
  b.*,
  CASE WHEN b.delivered_date IS NOT NULL THEN 1 ELSE 0 END AS has_delivery,  -- 1 = delivered with a date
  CAST(EXTRACT(YEAR  FROM b.purchase_ts) AS INTEGER) AS order_year,
  CAST(EXTRACT(MONTH FROM b.purchase_ts) AS INTEGER) AS order_month,
  CASE WHEN b.delivered_date IS NOT NULL THEN b.delivered_date - CAST(b.purchase_ts AS DATE) END AS delivery_days,
  b.estimated_date - CAST(b.purchase_ts AS DATE)                                                 AS estimated_days,
  CASE WHEN b.delivered_date IS NOT NULL THEN b.delivered_date - b.estimated_date END            AS delay_days,
  CASE WHEN b.delivered_date IS NULL THEN NULL
       WHEN b.delivered_date > b.estimated_date THEN 1 ELSE 0 END                                AS is_late,
  CASE WHEN b.delivered_date IS NULL THEN NULL
       WHEN b.delivered_date <= b.estimated_date THEN '1 On time'
       WHEN b.delivered_date - b.estimated_date <= 3 THEN '2 Late 1-3 days'
       WHEN b.delivered_date - b.estimated_date <= 7 THEN '3 Late 4-7 days'
       ELSE '4 Late 8+ days' END                                                                 AS delay_bucket,
  CASE WHEN b.review_score IS NULL THEN NULL
       WHEN b.review_score >= 4 THEN 'Positive (4-5)'
       WHEN b.review_score = 3  THEN 'Neutral (3)'
       ELSE 'Negative (1-2)' END                                                                 AS review_group
FROM base b;

-- ------------------------------------------------ fact: order items
-- Carries order-level attributes so category/seller diagnostics need no extra joins.
-- order_weight = 1 / items in the order: use it ONLY for averages/rates of order-level fields
-- (review score, late flag) so multi-item orders are not over-counted.
-- NEVER sum order_value or payment_value from this table; use price / freight_value here.
CREATE TABLE semantic.fact_order_items AS
SELECT
  it.order_id, it.order_item_id, it.product_id, it.seller_id,
  it.price, it.freight_value,
  it.price + it.freight_value                    AS item_value,
  1.0 / COUNT(*) OVER (PARTITION BY it.order_id) AS order_weight,
  fo.purchase_date, fo.purchase_month, fo.order_status, fo.is_valid_order, fo.is_delivered,
  fo.has_delivery, fo.is_late, fo.delay_days, fo.delivery_days, fo.review_score, fo.has_review, fo.customer_state,
  pr.category_en
FROM kaggle.olist_order_items_dataset it
JOIN semantic.fact_orders fo       ON fo.order_id = it.order_id
LEFT JOIN semantic.dim_product pr  ON pr.product_id = it.product_id;

-- refresh planner statistics so joins are fast
ANALYZE;
