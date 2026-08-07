import duckdb
from pathlib import Path

project_root = Path(__file__).resolve().parent.parent
database_path = project_root / "credit_dbt" / "credit.duckdb"
output_path = project_root / "exports" / "mart_portfolio_yearly.csv"

print(f"Connecting to: {database_path}")

if not database_path.exists():
    raise FileNotFoundError(f"Database not found: {database_path}")

with duckdb.connect(str(database_path), read_only=True) as con:
    con.execute(
        f"""
        copy main.mart_portfolio_yearly
        to '{output_path}'
        with (
            header true,
            delimiter ','
        )
        """
    )

print(f"Exported to: {output_path}")