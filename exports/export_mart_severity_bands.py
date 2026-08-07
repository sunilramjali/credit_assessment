import duckdb
from pathlib import Path

project_root = Path(__file__).resolve().parent.parent
database_path = project_root / "credit_dbt" / "credit.duckdb"
output_path = project_root / "exports" / "mart_loss_severity_bands.csv"

print(f"Connecting to: {database_path}")

if not database_path.exists():
    raise FileNotFoundError(f"Database not found: {database_path}")

# Sorted by the numeric band order, never by the label: as text, "100k+" sorts
# before "10k-25k" and the histogram comes out in the wrong sequence.
with duckdb.connect(str(database_path), read_only=True) as con:
    con.execute(
        f"""
        copy (
            select *
            from main.mart_loss_severity_bands
            order by severity_band_order
        )
        to '{output_path}'
        with (
            header true,
            delimiter ','
        )
        """
    )

print(f"Exported to: {output_path}")
