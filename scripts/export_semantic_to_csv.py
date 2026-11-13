"""Export the semantic views to CSV (for Tableau / Power BI import / Excel).

Usage:
    pip install duckdb
    python scripts/export_semantic_to_csv.py [path/to/asb_oltp.duckdb]

The lab DuckDB file is COPIED first so the original is never modified.
Output: exports/<view>.csv (git-ignored, because the files are large).
"""
import pathlib
import shutil
import sys

import duckdb

SRC = sys.argv[1] if len(sys.argv) > 1 else "/asb_materials/setup/03_duckdb_databases/asb_oltp.duckdb"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "exports"
OUT.mkdir(exist_ok=True)

work = OUT / "_work.duckdb"
shutil.copy(SRC, work)

con = duckdb.connect(str(work))
con.execute((ROOT / "sql" / "01_semantic_model.sql").read_text(encoding="utf-8"))

for view in ["fact_orders", "fact_order_items", "dim_customer", "dim_product", "dim_seller", "dim_date"]:
    target = (OUT / f"{view}.csv").as_posix()
    con.execute(f"COPY (SELECT * FROM semantic.{view}) TO '{target}' (HEADER, DELIMITER ',')")
    n = con.execute(f"SELECT COUNT(*) FROM semantic.{view}").fetchone()[0]
    print(f"{view}: {n:,} rows -> {target}")

con.close()
work.unlink()
