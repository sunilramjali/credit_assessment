from pathlib import Path

import duckdb


project_root = Path(__file__).resolve().parents[1]

db_path = project_root / "credit_dbt" / "credit.duckdb"
output_path = project_root / "exports" / "mart_categorical_feature_risk.csv"


with duckdb.connect(str(db_path), read_only=True) as con:

    con.execute(
        f"""
        COPY (
            SELECT *
            FROM main.mart_categorical_feature_risk
            ORDER BY feature_name, loan_count DESC
        )
        TO '{output_path}'
        (HEADER, DELIMITER ',');
        """
    )


print(f"Exported successfully to: {output_path}")