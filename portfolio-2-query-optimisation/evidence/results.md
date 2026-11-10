# Portfolio 2 – benchmark results (PostgreSQL 18.3, median of 5 warm runs)

| Query | Concept | Baseline ms | Indexed ms | Speed-up | Baseline cost → Indexed cost | Buffers (logical+physical I/O) | Est. rows / actual rows (indexed) | Access path after indexing |
|---|---|---:|---:|---:|---|---|---|---|
| Q1 | equality search on a FK column | 98.370 | 0.127 | 774.6× | 5,415 → 35 | 2,576 → 25 | 8 / 22.0 | Bitmap Heap Scan on customer_order; Bitmap Index Scan (idx_order_customer_date) |
| Q2 | multi-column (composite) index + joins | 123.456 | 52.927 | 2.3× | 6,585 → 1,387 | 18,160 → 15,820 | 83 / 2,596.0 | Index Scan on customer_order (idx_order_status_date); Index Scan on customer (customer_pkey); Index Scan on address (uq_address_owner); Index Scan on state (state_pkey) |
| Q3 | join order + aggregation (GROUP BY / HAVING) | 1239.319 | 1470.204 | 0.8× | 29,543 → 25,988 | 5,114 → 3,500 | 31,992 / 60.0 | Seq Scan on order_item; Index Scan on customer_order (idx_order_date); Seq Scan on product_variant; Seq Scan on product; Seq Scan on category |
| Q4 | exact-match search (hash vs B-tree) | 126.911 | 0.054 | 2,350.2× | 5,884 → 8 | 2,942 → 2 | 1 / 1.0 | Index Scan on payment (idx_payment_order_hash) |
| Q5 | selection pushdown + join order + aggregation | 211.579 | 204.259 | 1.0× | 12,633 → 8,666 | 5,137 → 2,825 | 10 / 10.0 | Seq Scan on order_item; Index Scan on customer_order (idx_order_date); Seq Scan on product_variant; Seq Scan on product |
| Q6 | small table – does an index help? | 2.065 | 2.568 | 0.8× | 70 → 50 | 24 → 26 | 293 / 293.0 | Bitmap Heap Scan on product_variant; Bitmap Index Scan (idx_variant_stock); Seq Scan on product |
