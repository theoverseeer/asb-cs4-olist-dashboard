# Dashboard build guide (Power BI)

Follow this page by page. Every choice maps to a rule from Module 04 (Fundamentals of data visualization and Dashboard design principles).

## 0. One-time setup
1. Start the data: `docker compose up -d`, then run `sql/00_profile.sql` and `sql/01_semantic_model.sql` (PostgreSQL `localhost:5432`, or DuckDB).
2. Power BI Desktop > **Get data > PostgreSQL database** > server `localhost:5432`, your database name (see the docker compose file) > **Import** the six views from schema `semantic`: `fact_orders`, `fact_order_items`, `dim_customer`, `dim_product`, `dim_seller`, `dim_date`. (DuckDB route: run `python scripts/export_semantic_to_csv.py` and import the CSVs from `exports/`.)
3. **Model view:** create the relationships listed at the top of `dax/measures.dax`. Single direction, one-to-many. Mark `dim_date` as the **date table** (Table tools > Mark as date table > `date_key`).
4. Hide key and helper columns from the report view (ids, `order_weight`, flags) so users only see business fields.
5. **View > Themes > Browse for themes** > `dashboard/theme.json` (colour-blind-safe palette).
6. Create the `_Measures` table and paste in the measures from `dax/measures.dax`. Format: money as currency (BRL or R$), percentages with 1 decimal, review score with 2 decimals.
7. Canvas: 16:9 (1280 x 720), top-rail layout.

## 1. Layout (all pages, top-rail)
```
+--------------------------------------------------------------------+
| Header: page title + one-sentence takeaway            [page nav]   |
| Filters: Year | Month | State (slicers, same position on every page)|
| KPI cards (4-6)                                                     |
| Main visual (trend / ranking)        | Supporting visual            |
| Diagnostic visual                    | Insight box (dynamic text)   |
+--------------------------------------------------------------------+
```
- Read order follows the **Z pattern**: title/KPIs top-left to top-right, then the main visual, then diagnostics bottom-right.
- Sync the slicers across pages (View > Sync slicers).
- Dashboard type: **strategic / executive** for page 1 (comparisons, baselines, annotations) and **analytical** for pages 3 and 4 (filters, drill-down).

## 2. Colour rules (applied everywhere)
| Use | Colour |
|---|---|
| Main series / "good" | `#0072B2` blue |
| Problem / late / low review | `#D55E00` orange |
| Secondary highlight | `#E69F00` amber |
| De-emphasised bars/points | `#BDBDBD` grey |
| Sequential scale (maps) | light blue `#C6DBEF` to `#0072B2` |

- Never red-vs-green. No more than 5 colours on one visual; group the rest into "Other".
- **Highlight, don't rainbow:** rankings use one blue; colour only the item the story is about.
- Bars start at zero (proportional ink). Do not truncate axes.
- Avoid dual-axis charts; use two aligned visuals instead.
- No 3-D, no pie charts with more than 3 slices (use bars).

## 3. Pages

### Page 1: Executive overview (questions 5.1.x)
| Visual | Fields | Notes |
|---|---|---|
| KPI cards x6 | `Sales (Items)`, `Valid Orders`, `AOV`, `Unique Customers`, `On-Time Delivery %`, `Avg Review Score` | Show `Sales MoM %` as the card sub-label. |
| Line chart "Monthly sales" | Axis `dim_date[year_month]`, Values `Sales (Items)` | Start the trend where data is complete (check the monthly query; the first and last months are partial). Add a constant average line. |
| Column chart "Monthly valid orders" | Axis `dim_date[year_month]`, Values `Valid Orders` | Same x-axis and slicers as the line chart. |
| Bar chart "Order status mix" | Axis `fact_orders[order_status]`, Values `Order Status %` | Sort descending; delivered in blue, other statuses grey. |
| Insight box | Text box with the finding for this page | Written from the data after you finish. |

### Page 2: Customers (questions 5.2.x)
| Visual | Fields | Notes |
|---|---|---|
| KPI cards | `Unique Customers`, `Repeat Customer Rate`, `Orders per Customer` | |
| Filled map or ranked bar | Location `fact_orders[customer_state]`, colour `Sales (Items)` | A bar chart is acceptable if the map is hard to read; sequential blue. |
| Bar chart "Top 10 states" | Axis `customer_state`, Values `Unique Customers` | Top N filter = 10; secondary table below for orders and sales. |
| Clustered bar "Repeat vs one-time" | Axis `fact_orders[customer_type]`, Values `AOV`, `Avg Review Score`, `Late Delivery %` | Use small multiples or separate cards so scales are not mixed. |

### Page 3: Products and sellers (questions 5.3.x)
| Visual | Fields | Notes |
|---|---|---|
| Horizontal bar "Top 10 categories by sales" | Axis `dim_product[category_en]`, Values `Item Sales` | Top N = 10, one blue colour. |
| Horizontal bar "Average order value by category" | Axis `category_en`, Values `Avg Order Value in Selection (item grain)` | Filter to categories with enough orders. |
| Pareto "Seller concentration" | Axis `dim_seller[seller_id]` sorted by `Item Sales` (Top 50), columns `Item Sales`, line `Cumulative Sales % (Seller)` | The only place a two-measure combo is justified; put the line on the secondary axis in 0-100%. |
| Table "Top sellers" | `seller_id`, `seller_state`, `Item Sales`, `Late % (item grain)`, `Avg Review (item grain)` | Conditional-format late % in orange above the average. |

### Page 4: Delivery and customer experience (questions 5.4.x and 5.5.x)
| Visual | Fields | Notes |
|---|---|---|
| KPI cards | `Avg Delivery Days`, `Late Delivery %`, `Avg Days Late (late orders only)`, `Avg Review Score`, `Negative Review %` | |
| Line chart "Late delivery % by month" | Axis `year_month`, Values `Late Delivery %` | Orange line, average reference line. |
| Bar chart "Late % by state" | Axis `customer_state`, Values `Late Delivery %` | Top 10, orange; filter small states (e.g. delivered orders >= 300). |
| **Column chart "Review score by delay"** | Axis `fact_orders[delay_bucket]`, Values `Avg Review Score` | The key diagnostic for question 5.5.3; y-axis from 0 or 1 with a clear label, on-time blue, late buckets orange. |
| Column chart "Review score distribution" | Axis `review_score`, Values `Reviewed Orders` | Single hue. |
| Bar chart "Lowest-rated categories" | Axis `category_en`, Values `Avg Review (item grain)` | Bottom 10, min items filter. |
| Insight box | `Insight: Late vs On-Time Review` | Dynamic text measure. |

## 4. Interactivity checklist
- [ ] Year, month and state slicers on every page, synced.
- [ ] Drill-through from state to city (right-click > Drill through) or a drill-down hierarchy `state > city`.
- [ ] Cross-filtering works (click a state, the other visuals update); turn off interactions that mislead.
- [ ] Tooltips show the measure name and value formatting.
- [ ] A "Reset filters" bookmark button.

## 5. Quality checklist (from the module slides)
- [ ] Each visual answers a stated business question (remove the rest).
- [ ] Proportional ink: bars start at zero; no truncated axes.
- [ ] Not more than 5 colours per visual; one highlight colour at a time.
- [ ] Colour-blind-safe palette; no red/green pairs.
- [ ] Direct labels instead of crowded legends; clear axis titles with units.
- [ ] Same filter positions and same colours for the same meaning on every page.
- [ ] KPI values reconcile with `sql/02_validation_and_insights.sql`.
- [ ] Screenshots of all four pages saved to `screenshots/`.

## 6. Publishing the files
Save as `dashboard/olist_dashboard.pbix`. If the file is over 100 MB, either import fewer columns or use Git LFS. Export each page as PNG (File > Export > or screenshot) and also export a PDF of the report into `screenshots/`.
