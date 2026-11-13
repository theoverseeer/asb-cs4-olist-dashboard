-- 02_validation_and_insights.sql : run AFTER 01_semantic_model.sql (PostgreSQL or DuckDB).
-- Part A reconciles the semantic layer to the raw tables. Part B returns the numbers for the README insights.
-- Run each statement separately in your SQL client and copy the figures into README.md.

-- ===================================================== A. RECONCILIATION (expected = actual)
SELECT 'orders: raw vs fact_orders' AS check_name,
       CAST((SELECT COUNT(*) FROM kaggle.olist_orders_dataset) AS NUMERIC) AS expected,
       CAST((SELECT COUNT(*) FROM semantic.fact_orders) AS NUMERIC)        AS actual
UNION ALL SELECT 'items: raw vs fact_order_items',
       CAST((SELECT COUNT(*) FROM kaggle.olist_order_items_dataset) AS NUMERIC),
       CAST((SELECT COUNT(*) FROM semantic.fact_order_items) AS NUMERIC)
UNION ALL SELECT 'sum(price): raw vs fact_orders.items_value',
       CAST((SELECT SUM(price) FROM kaggle.olist_order_items_dataset) AS NUMERIC(16,2)),
       CAST((SELECT SUM(items_value) FROM semantic.fact_orders) AS NUMERIC(16,2))
UNION ALL SELECT 'sum(price): raw vs fact_order_items.price',
       CAST((SELECT SUM(price) FROM kaggle.olist_order_items_dataset) AS NUMERIC(16,2)),
       CAST((SELECT SUM(price) FROM semantic.fact_order_items) AS NUMERIC(16,2))
UNION ALL SELECT 'sum(payment_value): raw vs fact_orders',
       CAST((SELECT SUM(payment_value) FROM kaggle.olist_order_payments_dataset) AS NUMERIC(16,2)),
       CAST((SELECT SUM(payment_value) FROM semantic.fact_orders) AS NUMERIC(16,2))
UNION ALL SELECT 'orders with a review: raw distinct vs fact_orders',
       CAST((SELECT COUNT(DISTINCT order_id) FROM kaggle.olist_order_reviews_dataset) AS NUMERIC),
       CAST((SELECT SUM(has_review) FROM semantic.fact_orders) AS NUMERIC)
UNION ALL SELECT 'sum(order_weight) = number of orders with items',
       CAST((SELECT COUNT(DISTINCT order_id) FROM kaggle.olist_order_items_dataset) AS NUMERIC),
       CAST((SELECT ROUND(CAST(SUM(order_weight) AS NUMERIC), 0) FROM semantic.fact_order_items) AS NUMERIC);

-- Payment vs order value gap (vouchers, rounding). Document the share, do not "fix" it.
SELECT CAST(100.0 * SUM(CASE WHEN ABS(payment_value - order_value) > 1 THEN 1 ELSE 0 END) / COUNT(*) AS NUMERIC(5,2)) AS pct_orders_payment_differs_from_order_value
FROM semantic.fact_orders WHERE is_valid_order = 1 AND items_count > 0 AND payment_value IS NOT NULL;

-- ===================================================== B1. OVERALL PERFORMANCE
-- 5.1.1 / 5.1.2  Orders and sales by month (check which months are complete before trending)
SELECT purchase_month,
       SUM(is_valid_order)                                                        AS valid_orders,
       CAST(SUM(CASE WHEN is_valid_order = 1 THEN items_value END) AS NUMERIC(14,2)) AS sales,
       CAST(SUM(CASE WHEN is_valid_order = 1 THEN order_value END) / NULLIF(SUM(is_valid_order), 0) AS NUMERIC(10,2)) AS aov
FROM semantic.fact_orders
GROUP BY purchase_month ORDER BY purchase_month;

-- 5.1.3 / 5.1.4  Average order value and unique customers (valid orders)
SELECT SUM(is_valid_order) AS valid_orders,
       COUNT(DISTINCT CASE WHEN is_valid_order = 1 THEN customer_unique_id END) AS unique_customers,
       CAST(SUM(CASE WHEN is_valid_order = 1 THEN order_value END) / SUM(is_valid_order) AS NUMERIC(10,2)) AS aov,
       CAST(SUM(CASE WHEN is_valid_order = 1 THEN items_value END) AS NUMERIC(14,2)) AS total_sales
FROM semantic.fact_orders;

-- 5.1.5  Status mix is in 00_profile.sql

-- ===================================================== B2. CUSTOMERS
-- 5.2.3 / 5.2.4  Repeat vs one-time customers
SELECT customer_type,
       COUNT(*) AS customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS NUMERIC(5,2)) AS pct_customers,
       CAST(AVG(valid_orders) AS NUMERIC(5,2)) AS avg_orders
FROM semantic.dim_customer GROUP BY customer_type ORDER BY customers DESC;

SELECT customer_type,
       CAST(AVG(order_value) AS NUMERIC(10,2))  AS avg_order_value,
       CAST(AVG(review_score) AS NUMERIC(4,2))  AS avg_review,
       CAST(100.0 * AVG(is_late) AS NUMERIC(5,2)) AS pct_late
FROM semantic.fact_orders WHERE is_valid_order = 1 GROUP BY customer_type;

-- 5.2.1 / 5.2.2  Top states by customers, orders, sales
SELECT customer_state,
       COUNT(DISTINCT customer_unique_id) AS customers,
       SUM(is_valid_order) AS orders,
       CAST(SUM(CASE WHEN is_valid_order = 1 THEN items_value END) AS NUMERIC(14,2)) AS sales,
       CAST(100.0 * SUM(CASE WHEN is_valid_order = 1 THEN items_value END) / SUM(SUM(CASE WHEN is_valid_order = 1 THEN items_value END)) OVER () AS NUMERIC(5,2)) AS pct_of_sales
FROM semantic.fact_orders GROUP BY customer_state ORDER BY sales DESC LIMIT 10;

-- ===================================================== B3. PRODUCTS AND SELLERS
-- 5.3.1 / 5.3.2  Category sales, orders and average order value (category-level)
SELECT category_en,
       CAST(SUM(price) AS NUMERIC(14,2)) AS sales,
       CAST(SUM(order_weight) AS NUMERIC(10,1)) AS orders_weighted,
       CAST(SUM(item_value) / SUM(order_weight) AS NUMERIC(10,2)) AS avg_order_value_in_category
FROM semantic.fact_order_items WHERE is_valid_order = 1
GROUP BY category_en ORDER BY sales DESC LIMIT 15;

-- 5.3.4  Concentration: share of sales from the top 10% and top 20% of sellers
WITH s AS (
  SELECT seller_id, SUM(price) AS sales FROM semantic.fact_order_items WHERE is_valid_order = 1 GROUP BY seller_id
), r AS (
  SELECT sales, ROW_NUMBER() OVER (ORDER BY sales DESC) AS rn, COUNT(*) OVER () AS n, SUM(sales) OVER () AS tot FROM s
)
SELECT MAX(n) AS sellers,
       CAST(100.0 * SUM(CASE WHEN rn <= n * 0.10 THEN sales END) / MAX(tot) AS NUMERIC(5,1)) AS top10pct_sellers_share,
       CAST(100.0 * SUM(CASE WHEN rn <= n * 0.20 THEN sales END) / MAX(tot) AS NUMERIC(5,1)) AS top20pct_sellers_share
FROM r;

-- Same concentration test for categories (top 5 share)
WITH c AS (SELECT category_en, SUM(price) AS sales FROM semantic.fact_order_items WHERE is_valid_order = 1 GROUP BY category_en),
     r AS (SELECT sales, ROW_NUMBER() OVER (ORDER BY sales DESC) AS rn, SUM(sales) OVER () AS tot FROM c)
SELECT CAST(100.0 * SUM(CASE WHEN rn <= 5 THEN sales END) / MAX(tot) AS NUMERIC(5,1)) AS top5_categories_share FROM r;

-- ===================================================== B4. DELIVERY
-- 5.4.1 / 5.4.2  Delivery time and late rate (delivered orders with dates)
SELECT COUNT(*) AS delivered_orders,
       CAST(AVG(delivery_days) AS NUMERIC(5,1))  AS avg_delivery_days,
       CAST(AVG(estimated_days) AS NUMERIC(5,1)) AS avg_estimated_days,
       CAST(100.0 * AVG(is_late) AS NUMERIC(5,2)) AS pct_late
FROM semantic.fact_orders WHERE has_delivery = 1;

-- 5.4.3  Where delays concentrate: customer state (min 300 delivered orders)
SELECT customer_state, COUNT(*) AS delivered_orders,
       CAST(AVG(delivery_days) AS NUMERIC(5,1)) AS avg_delivery_days,
       CAST(100.0 * AVG(is_late) AS NUMERIC(5,2)) AS pct_late
FROM semantic.fact_orders WHERE has_delivery = 1
GROUP BY customer_state HAVING COUNT(*) >= 300 ORDER BY pct_late DESC LIMIT 10;

-- 5.4.3  Categories with the highest late rate (min 300 items, order-weighted)
SELECT category_en,
       CAST(SUM(order_weight) AS NUMERIC(10,1)) AS delivered_orders_weighted,
       CAST(100.0 * SUM(CASE WHEN is_late = 1 THEN order_weight END) / SUM(order_weight) AS NUMERIC(5,2)) AS pct_late
FROM semantic.fact_order_items WHERE has_delivery = 1
GROUP BY category_en HAVING COUNT(*) >= 300 ORDER BY pct_late DESC LIMIT 10;

-- 5.4.4  Delivery performance by month
SELECT purchase_month, COUNT(*) AS delivered_orders,
       CAST(AVG(delivery_days) AS NUMERIC(5,1)) AS avg_delivery_days,
       CAST(100.0 * AVG(is_late) AS NUMERIC(5,2)) AS pct_late
FROM semantic.fact_orders WHERE has_delivery = 1
GROUP BY purchase_month ORDER BY purchase_month;

-- ===================================================== B5. CUSTOMER EXPERIENCE
-- 5.5.1  Review score distribution
SELECT review_score, COUNT(*) AS orders,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS NUMERIC(5,2)) AS pct
FROM semantic.fact_orders WHERE has_review = 1 GROUP BY review_score ORDER BY review_score;

-- 5.5.3  Late vs on-time, and by size of delay
SELECT delay_bucket, COUNT(*) AS orders, CAST(AVG(review_score) AS NUMERIC(4,2)) AS avg_review,
       CAST(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1.0 ELSE 0.0 END) AS NUMERIC(5,2)) AS pct_negative
FROM semantic.fact_orders WHERE has_delivery = 1 AND has_review = 1
GROUP BY delay_bucket ORDER BY delay_bucket;

-- 5.5.2  Lowest-rated categories (min 300 items, order-weighted)
SELECT category_en,
       CAST(SUM(order_weight) AS NUMERIC(10,1)) AS reviewed_orders_weighted,
       CAST(SUM(review_score * order_weight) / SUM(CASE WHEN has_review = 1 THEN order_weight END) AS NUMERIC(4,2)) AS avg_review
FROM semantic.fact_order_items
GROUP BY category_en HAVING COUNT(*) >= 300 ORDER BY avg_review ASC LIMIT 10;

-- 5.5.2  Lowest-rated sellers (min 50 items)
SELECT seller_id, COUNT(*) AS items,
       CAST(SUM(review_score * order_weight) / SUM(CASE WHEN has_review = 1 THEN order_weight END) AS NUMERIC(4,2)) AS avg_review,
       CAST(100.0 * SUM(CASE WHEN is_late = 1 THEN order_weight END) / NULLIF(SUM(CASE WHEN has_delivery = 1 THEN order_weight END), 0) AS NUMERIC(5,2)) AS pct_late
FROM semantic.fact_order_items GROUP BY seller_id HAVING COUNT(*) >= 50 ORDER BY avg_review ASC LIMIT 10;

-- 5.5.4  Other factors associated with low scores
-- (a) delivery duration
SELECT CAST(CORR(delivery_days, review_score) AS NUMERIC(5,3)) AS corr_delivery_days_vs_review
FROM semantic.fact_orders WHERE has_delivery = 1 AND has_review = 1;
-- (b) freight burden
SELECT CASE WHEN freight_value / NULLIF(order_value, 0) < 0.10 THEN '1 freight < 10% of order'
            WHEN freight_value / NULLIF(order_value, 0) < 0.25 THEN '2 freight 10-25%'
            WHEN freight_value / NULLIF(order_value, 0) < 0.40 THEN '3 freight 25-40%'
            ELSE '4 freight 40%+' END AS freight_share, COUNT(*) AS orders,
       CAST(AVG(review_score) AS NUMERIC(4,2)) AS avg_review
FROM semantic.fact_orders WHERE has_review = 1 AND items_count > 0 AND order_value > 0
GROUP BY 1 ORDER BY 1;
-- (c) number of items and sellers in the order
SELECT CASE WHEN items_count >= 3 THEN '3+' ELSE CAST(items_count AS VARCHAR) END AS items_in_order,
       COUNT(*) AS orders, CAST(AVG(review_score) AS NUMERIC(4,2)) AS avg_review
FROM semantic.fact_orders WHERE has_review = 1 AND items_count > 0 GROUP BY 1 ORDER BY 1;
-- (d) payment type
SELECT payment_type_primary, COUNT(*) AS orders, CAST(AVG(review_score) AS NUMERIC(4,2)) AS avg_review
FROM semantic.fact_orders WHERE has_review = 1 AND payment_type_primary IS NOT NULL GROUP BY 1 ORDER BY orders DESC;
