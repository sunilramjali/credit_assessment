import duckdb
from pathlib import Path

project_root = Path(__file__).resolve().parent.parent
database_path = project_root / "credit_dbt" / "credit.duckdb"
output_path = project_root / "exports" / "mart_loss_concentration.csv"

print(f"Connecting to: {database_path}")

if not database_path.exists():
    raise FileNotFoundError(f"Database not found: {database_path}")

# The order by is not cosmetic here. The concentration curve is the row order:
# every cumulative column only makes sense read from rank 1 downwards.
with duckdb.connect(str(database_path), read_only=True) as con:
    con.execute(
        f"""
        copy (
            select *
            from main.mart_loss_concentration
            order by loss_rank
        )
        to '{output_path}'
        with (
            header true,
            delimiter ','
        )
        """
    )

print(f"Exported to: {output_path}")
