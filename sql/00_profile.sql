-- 00_profile.sql : data profiling and key validation (PostgreSQL or DuckDB).
-- Connect to the asb_oltp database; source tables are in schema "kaggle".
-- Each row is one check. Review any n_issues > 0 and document it in the README.

SELECT 'rows: orders' AS check_name, COUNT(*) AS n_issues FROM kaggle.olist_orders_dataset
UNION ALL SELECT 'rows: order_items', COUNT(*) FROM kaggle.olist_order_items_dataset
UNION ALL SELECT 'rows: payments', COUNT(*) FROM kaggle.olist_order_payments_dataset
UNION ALL SELECT 'rows: reviews', COUNT(*) FROM kaggle.olist_order_reviews_dataset
UNION ALL SELECT 'rows: customers', COUNT(*) FROM kaggle.olist_customers_dataset
UNION ALL SELECT 'rows: products', COUNT(*) FROM kaggle.olist_products_dataset
UNION ALL SELECT 'rows: sellers', COUNT(*) FROM kaggle.olist_sellers_dataset

-- Key uniqueness
UNION ALL SELECT 'dup: order_id in orders',
  COUNT(*) FROM (SELECT order_id FROM kaggle.olist_orders_dataset GROUP BY order_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'dup: customer_id in customers',
  COUNT(*) FROM (SELECT customer_id FROM kaggle.olist_customers_dataset GROUP BY customer_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'dup: product_id in products',
  COUNT(*) FROM (SELECT product_id FROM kaggle.olist_products_dataset GROUP BY product_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'dup: seller_id in sellers',
  COUNT(*) FROM (SELECT seller_id FROM kaggle.olist_sellers_dataset GROUP BY seller_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'dup: (order_id, order_item_id) in order_items',
  COUNT(*) FROM (SELECT order_id, order_item_id FROM kaggle.olist_order_items_dataset GROUP BY order_id, order_item_id HAVING COUNT(*) > 1) d

-- Grain traps: several rows per order
UNION ALL SELECT 'orders with >1 item (item grain is NOT order grain)',
  COUNT(*) FROM (SELECT order_id FROM kaggle.olist_order_items_dataset GROUP BY order_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'orders with >1 payment record',
  COUNT(*) FROM (SELECT order_id FROM kaggle.olist_order_payments_dataset GROUP BY order_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'orders with >1 review',
  COUNT(*) FROM (SELECT order_id FROM kaggle.olist_order_reviews_dataset GROUP BY order_id HAVING COUNT(*) > 1) d
UNION ALL SELECT 'duplicate review_id values',
  COUNT(*) FROM (SELECT review_id FROM kaggle.olist_order_reviews_dataset GROUP BY review_id HAVING COUNT(*) > 1) d

-- Referential integrity (orphans)
UNION ALL SELECT 'orders without a customer',
  COUNT(*) FROM kaggle.olist_orders_dataset o LEFT JOIN kaggle.olist_customers_dataset c ON c.customer_id = o.customer_id WHERE c.customer_id IS NULL
UNION ALL SELECT 'order_items without an order',
  COUNT(*) FROM kaggle.olist_order_items_dataset i LEFT JOIN kaggle.olist_orders_dataset o ON o.order_id = i.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'order_items without a product',
  COUNT(*) FROM kaggle.olist_order_items_dataset i LEFT JOIN kaggle.olist_products_dataset p ON p.product_id = i.product_id WHERE p.product_id IS NULL
UNION ALL SELECT 'order_items without a seller',
  COUNT(*) FROM kaggle.olist_order_items_dataset i LEFT JOIN kaggle.olist_sellers_dataset s ON s.seller_id = i.seller_id WHERE s.seller_id IS NULL
UNION ALL SELECT 'payments without an order',
  COUNT(*) FROM kaggle.olist_order_payments_dataset p LEFT JOIN kaggle.olist_orders_dataset o ON o.order_id = p.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'reviews without an order',
  COUNT(*) FROM kaggle.olist_order_reviews_dataset r LEFT JOIN kaggle.olist_orders_dataset o ON o.order_id = r.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'orders without any item',
  COUNT(*) FROM kaggle.olist_orders_dataset o LEFT JOIN (SELECT DISTINCT order_id FROM kaggle.olist_order_items_dataset) i ON i.order_id = o.order_id WHERE i.order_id IS NULL

-- Missing values and logical checks
UNION ALL SELECT 'delivered orders with missing delivered date',
  COUNT(*) FROM kaggle.olist_orders_dataset WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL
UNION ALL SELECT 'non-delivered orders that have a delivered date',
  COUNT(*) FROM kaggle.olist_orders_dataset WHERE order_status <> 'delivered' AND order_delivered_customer_date IS NOT NULL
UNION ALL SELECT 'products without a category',
  COUNT(*) FROM kaggle.olist_products_dataset WHERE product_category_name IS NULL
UNION ALL SELECT 'categories without an English translation',
  COUNT(*) FROM (SELECT DISTINCT p.product_category_name FROM kaggle.olist_products_dataset p
                 LEFT JOIN kaggle.product_category_name_translation t ON t.product_category_name = p.product_category_name
                 WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL) d
UNION ALL SELECT 'items with price <= 0',
  COUNT(*) FROM kaggle.olist_order_items_dataset WHERE price <= 0
UNION ALL SELECT 'payments with value <= 0',
  COUNT(*) FROM kaggle.olist_order_payments_dataset WHERE payment_value <= 0
UNION ALL SELECT 'reviews with score outside 1-5',
  COUNT(*) FROM kaggle.olist_order_reviews_dataset WHERE review_score NOT BETWEEN 1 AND 5;

-- Order status distribution (business question 5.1.5)
SELECT order_status, COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders
FROM kaggle.olist_orders_dataset
GROUP BY order_status
ORDER BY orders DESC;
