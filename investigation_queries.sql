-- ============================================================
-- SQL Support Investigation Lab
-- Olist Brazilian E-Commerce Dataset
-- Incident: payment recorded, order status never progressed
-- ============================================================
-- Run against MySQL 8.0. Tables used: olist_orders_dataset,
-- olist_order_payments_dataset.
--
-- Queries are listed in the order they were actually run during
-- the investigation, matching the README narrative. Each query
-- includes the question it answers and what the result showed.
-- ============================================================


-- ============================================================
-- STEP 1: Baseline status distribution
-- ============================================================
-- Question: before treating anything as unusual, what does the
-- overall distribution of order statuses look like, and what
-- share are 'processing' or 'invoiced' specifically?
-- Result: processing + invoiced = 0.62% of all orders (615 of 99,441)

SELECT
    orders.order_status,
    COUNT(DISTINCT orders.order_id) AS total_orders,
    ROUND(
        COUNT(DISTINCT orders.order_id) /
        (
            SELECT COUNT(DISTINCT total_orders.order_id)
            FROM olist_orders_dataset AS total_orders
        ) * 100,
    2) AS percentage
FROM olist_orders_dataset AS orders
GROUP BY orders.order_status;


-- ============================================================
-- STEP 2: Confirm payment-to-order cardinality
-- ============================================================
-- Question: does a single order always have exactly one row in
-- olist_order_payments_dataset, or can it have more (installments)?
-- This needs checking before any later join or SUM against the
-- payments table, since a wrong assumption here would silently
-- corrupt any per-order count built on top of it. Checked across
-- the whole dataset, not scoped to stuck orders, since this is a
-- general fact about the table relationship, established before
-- any incident-specific filtering happens.
-- Result: 2,961 orders have more than one payment row. Verified
-- by running this count both with and without the join to
-- olist_orders_dataset — both return 2,961, since every payment
-- row already implies an existing order.

SELECT COUNT(*) AS count FROM
(SELECT
    payments.order_id,
    COUNT(payments.payment_value) AS num_of_payments
FROM olist_orders_dataset AS orders
LEFT JOIN olist_order_payments_dataset AS payments
    ON payments.order_id = orders.order_id
GROUP BY payments.order_id
HAVING COUNT(payments.order_id) > 1) AS result;


-- ============================================================
-- STEP 3a: Average promised delivery window — stuck orders
-- ============================================================
-- Question: were processing/invoiced orders promised an unusually
-- long delivery window from the start, or were they promised
-- roughly the same thing as orders that did complete?
-- Result: stuck orders averaged 28.24 days

SELECT
    AVG(DATEDIFF(orders.order_estimated_delivery_date, orders.order_purchase_timestamp)) AS avg_diff
FROM olist_orders_dataset AS orders
WHERE orders.order_status = 'invoiced' OR orders.order_status = 'processing';


-- ============================================================
-- STEP 3b: Average promised delivery window — delivered orders
-- ============================================================
-- Same question as 3a, run against delivered orders as the
-- comparison baseline. This baseline (not the stuck orders' own
-- average) is what's used as the threshold in Step 4, to avoid
-- using the stuck group to define its own filter.
-- Result: delivered orders averaged 24.37 days

SELECT
    AVG(DATEDIFF(orders.order_estimated_delivery_date, orders.order_purchase_timestamp)) AS avg_diff
FROM olist_orders_dataset AS orders
WHERE orders.order_status = 'delivered';


-- ============================================================
-- STEP 4: Identify the individual stuck orders
-- ============================================================
-- Question: which specific processing/invoiced orders have been
-- sitting unresolved well past the typical (delivered-order)
-- delivery window, with zero delivery activity recorded?
-- Anchor for "how long" is the dataset's own latest purchase
-- timestamp, since this is frozen historical data with no real
-- "today" to measure against.
-- Result: 615 orders, every one of them with no carrier or
-- customer delivery date recorded, ranging 64 to 743 days old

SELECT
    *,
    DATEDIFF(
        (SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset),
        order_purchase_timestamp
    ) AS diff
FROM olist_orders_dataset
WHERE
    DATEDIFF(
        (SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset),
        order_purchase_timestamp
    ) > 24
    AND (order_status = 'invoiced' OR order_status = 'processing');


-- ============================================================
-- STEP 4b: Confirm 615 is the full population, not a subset
-- ============================================================
-- Question: are there any processing/invoiced orders that fall
-- WITHIN the threshold (i.e. genuinely recent, not yet stuck)?
-- Run as the inverse of Step 4 to check rather than assume.
-- Result: empty set — zero such orders exist

SELECT
    *,
    DATEDIFF(
        (SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset),
        order_purchase_timestamp
    ) AS diff
FROM olist_orders_dataset
WHERE
    DATEDIFF(
        (SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset),
        order_purchase_timestamp
    ) <= 24
    AND (order_status = 'invoiced' OR order_status = 'processing');


-- ============================================================
-- STEP 5: Total payment value tied to the 615 stuck orders
-- ============================================================
-- Question: how much recorded payment value sits behind these
-- 615 orders? This is the figure finance's reconciliation
-- actually needs.
-- Note: joining brings in 644 payment rows for 615 orders, not
-- 1:1, because of the installment structure confirmed in Step 2.
-- This is fine for SUM (every installment should be added in)
-- but would NOT be fine for counting orders without DISTINCT.
-- Result: R$138,532.10

SELECT
    ROUND(SUM(payments.payment_value), 2) AS total_amount
FROM olist_orders_dataset AS orders
LEFT JOIN olist_order_payments_dataset AS payments
    ON payments.order_id = orders.order_id
WHERE
    DATEDIFF((SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset), orders.order_purchase_timestamp) > 24
    AND (order_status = 'invoiced' OR order_status = 'processing')
    AND payments.order_id IS NOT NULL;


-- ============================================================
-- STEP 5b: Verify the 644 vs 615 gap is fully explained by installments
-- ============================================================
-- Question: orders LEFT JOIN payments alone can produce more rows
-- than distinct orders, since a single order can have multiple
-- rows in olist_order_payments_dataset (installments, confirmed
-- in Step 2). Is that the full explanation for the 644 vs 615
-- gap, or is something else going on?
-- Run total row count and distinct order count side by side in
-- one query for a direct, unambiguous comparison.
-- Result: 644 total rows, 615 distinct orders — gap fully
-- consistent with a handful of orders having multiple
-- installment payments

SELECT
    COUNT(payments.order_id) AS total_orders_stuck,
    COUNT(DISTINCT payments.order_id) AS unique_orders_stuck
FROM olist_order_payments_dataset AS payments
RIGHT JOIN olist_orders_dataset AS orders
    ON payments.order_id = orders.order_id
WHERE
    DATEDIFF((SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset), orders.order_purchase_timestamp) > 24
    AND (order_status = 'invoiced' OR order_status = 'processing')
    AND payments.order_id IS NOT NULL;


-- ============================================================
-- STEP 6: Payment type breakdown among the 615 stuck orders
-- ============================================================
-- Question: do the stuck orders cluster around a specific
-- payment type? (Seller was tried first and abandoned — order_id
-- doesn't map 1:1 to seller_id in this dataset, 1,278 orders span
-- multiple sellers, so a per-seller breakdown would need a design
-- decision outside the scope of this check. Payment type has no
-- such complication, one clean value per payment row.)
-- Result: credit_card 463, boleto 137, voucher 36, debit_card 8

SELECT
    payments.payment_type,
    COUNT(payments.payment_type) AS total_payments
FROM olist_orders_dataset AS orders
LEFT JOIN olist_order_payments_dataset AS payments
    ON payments.order_id = orders.order_id
WHERE
    DATEDIFF((SELECT MAX(order_purchase_timestamp) FROM olist_orders_dataset), order_purchase_timestamp) > 24
    AND (order_status = 'invoiced' OR order_status = 'processing')
    AND payments.order_id IS NOT NULL
GROUP BY payments.payment_type
ORDER BY COUNT(payments.payment_type) DESC;


-- ============================================================
-- STEP 6b: Payment type breakdown — all orders (baseline)
-- ============================================================
-- Same breakdown with no status filter, to compare against Step 6.
-- A type being common among stuck orders means nothing unless
-- it's also disproportionately more common than its general rate.
-- Result: credit_card 76,795 | boleto 19,784 | voucher 5,775 |
-- debit_card 1,529 | not_defined 3
-- Comparison: every type's share among stuck orders is within
-- ~2 percentage points of its overall share — no clustering found.

SELECT
    payments.payment_type,
    COUNT(payments.payment_type) AS total_payments
FROM olist_orders_dataset AS orders
LEFT JOIN olist_order_payments_dataset AS payments
    ON payments.order_id = orders.order_id
GROUP BY payments.payment_type
ORDER BY COUNT(payments.payment_type) DESC;
