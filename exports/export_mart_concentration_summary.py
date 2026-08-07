import duckdb
from pathlib import Path

project_root = Path(__file__).resolve().parent.parent
database_path = project_root / "credit_dbt" / "credit.duckdb"
output_path = project_root / "exports" / "mart_loss_concentration_summary.csv"

print(f"Connecting to: {database_path}")

if not database_path.exists():
    raise FileNotFoundError(f"Database not found: {database_path}")

with duckdb.connect(str(database_path), read_only=True) as con:
    con.execute(
        f"""
        copy (
            select *
            from main.mart_loss_concentration_summary
            order by top_share_threshold
        )
        to '{output_path}'
        with (
            header true,
            delimiter ','
        )
        """
    )

print(f"Exported to: {output_path}")
