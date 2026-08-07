# YHP Credit Risk Assessment

This repository contains an end-to-end credit risk analysis of an anonymised small-business lending portfolio. It was developed for the **YH & Partners Data Science Take-Home Assessment: Credit Risk — Default & Loss**.

The work is split into two parts:

1. **Analytics and data engineering** — profile the portfolio, identify three business-relevant findings, surface data-quality issues, and build repeatable transformations.
2. **Predictive modelling** — estimate the probability that a funded loan ends in loss and the size of the loss when it occurs, then expose those predictions through a small inference function.

The analytical pipeline is built with **dbt** and **DuckDB**. Initial exploration is carried out in Python, and the published Part 1 charts are produced in **Looker Studio** from exported dbt marts.

## Links

- **Live dashboard:** https://datastudio.google.com/s/taLG52JGGKY  
  Check the dashboard filter selections before interpreting a chart; the current view is not intended to be read with all filter values selected.
- **Part 1 report:** [`part1_credit_risk_analysis.pdf`](part1_credit_risk_analysis.pdf)
- **Modelling methodology:** [`modelling/ml_methodology.md`](modelling/ml_methodology.md)

---

## Project objective

The source data contains funded-loan outcomes and 99 anonymised predictors. The project turns those raw tables into a reproducible analytical layer that can answer four practical questions:

- How often does the portfolio experience a recorded credit loss?
- How large are those losses?
- Has portfolio risk changed over time or across borrower/loan segments?
- Are the data and model outputs reliable enough to support further analysis?

Part 2 then uses the same prepared data to answer two predictive questions:

- **Will this loan end in a loss?**
- **If it does, how large is the loss likely to be?**

The two predictions can be combined into an expected-loss estimate for each loan.

---

## Data

The source is a single SQLite database containing two tables and **10,000 funded loans** originated between **11 April 2018 and 18 December 2025**.

| Source table | Contents |
|---|---|
| `loans` | `loan_id`, `received_date`, `is_loss`, `loss_amount` |
| `loan_features` | `loan_id` plus 99 anonymised predictors |

The portfolio's recorded `is_loss` rate is **21.19%**. Amounts are denominated in **USD**.

The two modelling targets are:

- `is_loss`: binary indicator of whether the loan recorded a material credit loss or charge-off.
- `loss_amount`: realised dollar loss. The source includes some zero, negative, missing, and target-inconsistent values; these are reported as data-quality issues rather than silently corrected.

Because the predictors are anonymised, the analysis can identify statistically different risk groups but cannot assign a business meaning to most feature names.

---

## Workflow

```text
Raw SQLite
    |
    v
Exploration notebook
    |
    v
dbt staging models
    |
    v
Intermediate joined model
    |
    +----------------------+
    |                      |
    v                      v
Analytical marts       ML datasets
    |                      |
    v                      v
CSV exports            Python models
    |                      |
    v                      v
Looker Studio          Inference function
```

### 1. Exploration

`exploration/yhp_credit_exploration.ipynb` is used to inspect the raw database, profile missingness and distributions, and identify data-quality issues.

The notebook is exploratory. Production calculations are moved into dbt models once their logic is defined.

### 2. dbt and DuckDB

The repeatable analytical pipeline lives in `credit_dbt/`.

dbt is responsible for:

- typing and documenting the raw fields;
- joining outcomes to the 99 predictors;
- creating portfolio, time-trend, segmentation and concentration marts;
- creating model-ready datasets for Part 2;
- running column-level and table-level tests.

DuckDB is the local analytical database. It reads the SQLite source directly, so no separate raw-data import is required.

### 3. Dashboard exports

The analytical marts are exported to CSV and loaded into Looker Studio.

Business logic is kept in dbt rather than recreated in the dashboard. This keeps the reported metrics traceable to a version-controlled SQL model and reduces the risk of different calculations being used in different charts.

---

## Data model

The dbt project builds **13 tables** across three layers.

### Staging

| Model | Rows | Purpose |
|---|---:|---|
| `stg_loans` | 10,000 | Types loan outcomes and converts `received_date` to a date and `is_loss` to a boolean. |
| `stg_loan_features` | 10,000 | Types the 99 anonymised predictors. |

### Intermediate

| Model | Rows | Purpose |
|---|---:|---|
| `int_loans_joined` | 10,000 | One row per loan containing outcomes and all predictors. |

### Marts

| Model | Rows | Purpose |
|---|---:|---|
| `mart_portfolio_kpis` | 29 | Long-form portfolio KPI table. |
| `mart_portfolio_kpis_wide` | 1 | Wide-form KPI table for BI scorecards. |
| `mart_portfolio_yearly` | 8 | Portfolio performance by year. |
| `mart_portfolio_seasonality` | 28 | Portfolio performance by quarter within year. |
| `mart_risk_segmentation` | 295 | Loss outcomes by category for the five categorical features, with portfolio benchmarks. |
| `mart_loss_concentration` | 2,232 | Positive-loss loans ranked by loss size with cumulative totals. |
| `mart_loss_concentration_summary` | 4 | Loss shares for the top 1%, 5%, 10% and 20% of positive-loss loans. |
| `mart_loss_severity_bands` | 5 | Distribution of loss amounts across five severity bands. |
| `mart_ml_training_set` | 10,000 | Model-ready classification dataset with chronological split and leakage controls. |
| `mart_ml_severity_set` | 2,232 | Model-ready severity dataset containing positive-loss observations only. |

---

# User guide

## Prerequisites

- Python **3.12**
- `pip`
- the source SQLite database

The raw data is not stored in Git. Place the assessment database at:

```text
data/YHP_credit_assessment_DS.sqlite
```

The project will not reproduce the analysis without this file.

---

## 1. Create and activate a virtual environment

From the repository root:

### macOS / Linux

```bash
python3 -m venv .venv
source .venv/bin/activate
```

### Windows

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
```

If `.venv` already exists, only activate it.

---

## 2. Install Python dependencies

```bash
pip install -r requirements.txt
```

The installed environment should include `dbt-core`, `dbt-duckdb` and `duckdb`.

---

## 3. Build the dbt project

Run dbt commands from the `credit_dbt/` directory so that the configured relative paths resolve correctly.

```bash
cd credit_dbt
```

Install dbt packages on the first run:

```bash
dbt deps
```

Check the project and database connection:

```bash
dbt debug
```

A correctly configured environment should finish with:

```text
All checks passed
```

Build the full project and run its tests:

```bash
dbt build
```

The current project contains **145 build and test nodes**. A clean run should complete without warnings or errors. If a test fails, treat the affected output as unvalidated until the underlying issue is resolved.

The resulting DuckDB database is:

```text
credit_dbt/credit.duckdb
```

---

## 4. Export the analytical marts

Return to the repository root:

```bash
cd ..
```

Run the required export scripts:

```bash
python exports/export_mart_kpis.py
python exports/export_mart_kpis_wide.py
python exports/export_mart_yearly.py
python exports/export_mart_season.py
python exports/export_mart_segmentation.py
python exports/export_mart_concentration.py
python exports/export_mart_concentration_summary.py
python exports/export_mart_severity_bands.py
```

Each script writes one CSV to `exports/`.

| Dashboard area | Source CSV |
|---|---|
| KPI scorecards | `mart_portfolio_kpis_wide.csv` |
| Time trend and seasonality | `mart_portfolio_yearly.csv`, `mart_portfolio_seasonality.csv` |
| Risk segmentation | `mart_risk_segmentation.csv` |
| Loss concentration | `mart_loss_concentration.csv`, `mart_loss_concentration_summary.csv`, `mart_loss_severity_bands.csv` |

The DuckDB marts remain the analytical source of truth. The CSV files are export copies for visualisation.

`mart_loss_concentration.csv` is intentionally sorted from the largest loss downward because the cumulative concentration curve depends on that ordering.

---

## 5. Query the DuckDB database directly

```python
import duckdb

con = duckdb.connect("credit_dbt/credit.duckdb", read_only=True)

df = con.execute(
    """
    select *
    from mart_portfolio_kpis
    order by kpi_display_order
    """
).df()

print(df)
```

Use a read-only connection unless the task requires writing to the database. DuckDB permits a single writer, so an open write connection can block a dbt build.

---

## Common dbt commands

Run these from `credit_dbt/`.

| Command | Purpose |
|---|---|
| `dbt build` | Build all selected models and run their tests. |
| `dbt run` | Build models without running tests. |
| `dbt test` | Run tests without rebuilding models. |
| `dbt build --select mart_portfolio_kpis` | Build and test one model. |
| `dbt build --select +mart_portfolio_kpis` | Build one model and its upstream dependencies. |
| `dbt docs generate && dbt docs serve` | Generate and browse project documentation and lineage. |

---

## Testing and data validation

The project uses standard dbt column tests alongside table-level reconciliation tests.

The checks cover:

- uniqueness and completeness of business keys;
- accepted values for controlled fields;
- row-count agreement between source, staging and joined models;
- preservation of loan coverage through the feature join;
- reconciliation of yearly totals to the underlying loans;
- segment and severity-band shares summing to one;
- the loss-concentration curve ending at one;
- chronological integrity of the machine-learning train/test split.

These tests do not prove that every analytical decision is correct. They are designed to catch common transformation, join, denominator and leakage errors before the outputs are used.

---

## Portfolio KPI table

`mart_portfolio_kpis` is stored in long form: one row per KPI.

| Column | Meaning |
|---|---|
| `kpi_group` | KPI family: `volume`, `frequency`, `severity` or `data_quality`. |
| `kpi_name` | Metric name. |
| `kpi_unit` | Unit such as `count`, `rate`, `rate_change`, `amount` or `date`. |
| `kpi_display_order` | Intended display order. |
| `is_headline` | Identifies the headline metrics. |
| `kpi_value` | Numeric value. |
| `kpi_value_text` | Text representation used where a numeric value is not appropriate, such as dates. |

To return only the headline KPIs:

```sql
select *
from mart_portfolio_kpis
where is_headline
order by kpi_display_order;
```

For Looker Studio scorecards, use `mart_portfolio_kpis_wide`. Each KPI is stored in its own column, which allows percentages, currency and counts to be formatted independently.

---

## Part 1: analytics and engineering

Part 1 is documented in [`part1_credit_risk_analysis.pdf`](part1_credit_risk_analysis.pdf).

The analysis focuses on three areas:

- change in portfolio risk over time;
- differences in loss outcomes across available categorical segments;
- concentration and severity of realised losses.

A separate data-quality section records issues found in the raw data and explains where they affect interpretation.

The dashboard is a presentation layer. Calculations used in the report and dashboard are produced in dbt marts rather than being recreated as dashboard formulas.

---

## Part 2: predictive modelling

Part 2 uses two models because the classification and severity targets answer different questions and require different training populations.

| Notebook | Question | Target | Population |
|---|---|---|---|
| `yhp_credit_classification.ipynb` | Will the loan record a loss? | `is_loss` | All 10,000 loans |
| `yhp_credit_regression.ipynb` | How large is the loss when a positive loss occurs? | `loss_amount` | 2,232 positive-loss loans |

Expected loss is calculated as:

```text
expected loss = probability of loss × predicted loss conditional on loss
```

### Leakage controls

Feature preparation is deliberately split between dbt and the modelling notebooks.

**dbt applies rules that do not need to learn from the data**, including:

- removing leakage fields where required;
- assigning the chronological train/test split;
- grouping predefined rare categories;
- converting known sentinel codes to null.

**The notebooks fit data-dependent transformations on the training rows only**, including:

- encoding;
- imputation;
- scaling;
- model fitting and tuning.

This separation keeps data-dependent preprocessing on the correct side of the validation split.

### Run the modelling notebooks

From the repository root:

```bash
cd modelling
jupyter notebook yhp_credit_classification.ipynb
```

and:

```bash
jupyter notebook yhp_credit_regression.ipynb
```

The classification notebook takes longer because of SVM tuning.

Detailed modelling decisions, validation choices and limitations are documented in:

```text
modelling/ml_methodology.md
```

---

## Inference

The inference utility accepts a `loan_id`, loads the saved preprocessing and fitted models, and returns:

- probability of loss;
- predicted loss conditional on loss;
- expected loss in USD;
- diagnostic flags where relevant.

Build and save the fitted artefacts:

```bash
cd modelling
python inference.py --build
```

Score a loan:

```bash
python inference.py LRQ-100067
```

From Python:

```python
from inference import predict

result = predict("LRQ-100067")
print(result)
```

The model is not re-fitted for each prediction. Saved model and preprocessing artefacts are loaded from disk so that scoring uses the same transformations as model development.

Two response fields require attention:

- `scored_on_training_data`: identifies loans that were part of model fitting, for which predictive performance will be optimistic.
- `severity_clipped`: identifies predictions capped because the observation falls outside the range used to train the severity model. This affects approximately 0.6% of loans.

---

## Export model predictions

To create the Part 2 output files:

```bash
cd modelling
python export_predictions.py
```

The script refits the selected model specifications without repeating the full parameter searches and writes the following files to `modelling/predictions/`:

| File | Rows | Contents |
|---|---:|---|
| `predictions_classification.csv` | 1,963 | Test-loan outcomes, model scores and risk deciles. |
| `predictions_regression.csv` | 451 | Actual and predicted losses for positive-loss test loans. |
| `model_comparison_classification.csv` | 4 | Classification model comparison metrics. |
| `model_comparison_regression.csv` | 4 | Regression model comparison metrics. |

In the current classification results, the riskiest test decile has a **33.2%** observed loss rate compared with **12.1%** in the safest decile, a **2.7×** spread. The reported ROC-AUC is **0.61**. This indicates modest discrimination: the model is more suitable for relative risk ranking than as a standalone underwriting rule.

---

## Data-quality findings and interpretation

Several source-data issues are deliberately retained and reported.

### Loss label and amount do not always agree

The data-quality mart reports **153 loans** where `is_loss` and `loss_amount` disagree, plus **4 loans** with no recorded loss amount.

The pipeline does not silently overwrite these records because there is no source-system information available to determine which field is authoritative.

### Duplicate feature vectors

**5,427 of 10,000 rows** share their complete 99-feature vector with at least one other row. This leaves **7,008 distinct feature records**.

Portfolio metrics remain weighted by the original loan rows. The duplication rate should therefore be considered when interpreting both descriptive and predictive results.

### Loss rate is count-based

The dataset does not contain a loan principal or funded exposure amount. A portfolio loss rate such as **21.19%** therefore means the percentage of loans that recorded a loss, not the percentage of dollars lent that were lost.

An exposure-weighted default or loss rate cannot be derived from the available fields.

### Multiple valid definitions of total loss

The repository reports different loss totals where the definitions answer different questions.

| Measure | USD | Definition |
|---|---:|---|
| `total_recorded_loss_amount` | 68,530,441.67 | Net recorded loss amount, including negative recoveries. |
| `total_positive_loss_amount` | 68,905,381.05 | Positive losses only. |
| Sum of `loss_amount` where `is_loss = 1` | 66,928,268.75 | Label-restricted total; lower because some positive loss amounts occur on records with `is_loss = 0`. |

The analysis uses named measures rather than treating these values as interchangeable.

---

## Assumptions and limitations

1. **The source fields are taken as provided.** Data-quality conflicts are surfaced rather than repaired without supporting information.
2. **Portfolio loss rates are loan-count based.** The source does not include funded exposure, so amount-weighted risk measures are unavailable.
3. **The predictors are anonymised.** Statistical associations can be measured, but most feature-level findings cannot be translated into specific borrower or product characteristics.
4. **Duplicate feature vectors remain in the analytical population.** This preserves the source portfolio weighting but can affect model training and interpretation.
5. **Model performance is not production-grade evidence.** The current classifier has modest discrimination and should be read as a take-home modelling exercise, not a deployed credit decision system.
6. **Inference flags training observations and clipped severity estimates.** These outputs should not be interpreted in the same way as clean out-of-sample predictions.

---

## Repository structure

```text
yhp_credit_assessment/
├── credit_dbt/                         # dbt project
│   ├── models/
│   │   ├── staging/
│   │   ├── intermediate/
│   │   └── marts/
│   ├── tests/                          # table-level checks
│   ├── macros/
│   ├── profiles.yml
│   ├── dbt_project.yml
│   └── credit.duckdb                   # generated; not stored in Git
├── data/
│   └── YHP_credit_assessment_DS.sqlite # source data; not stored in Git
├── exploration/
│   └── yhp_credit_exploration.ipynb
├── exports/                            # dbt mart export scripts and CSVs
├── modelling/
│   ├── yhp_credit_classification.ipynb
│   ├── yhp_credit_regression.ipynb
│   ├── inference.py
│   ├── export_predictions.py
│   ├── artifacts/
│   ├── predictions/
│   └── ml_methodology.md
├── part1_credit_risk_analysis.pdf
├── requirements.txt
└── README.md
```

Each SQL model is documented in the dbt project alongside its associated tests.

---

## Troubleshooting

### `dbt debug` succeeds but the expected data is not available

Confirm that:

- the SQLite file exists at `data/YHP_credit_assessment_DS.sqlite`;
- dbt is being run from `credit_dbt/`;
- the paths in `profiles.yml` resolve to the intended SQLite and DuckDB files.

### `Could not find adapter type ...`

Check the virtual environment and `profiles.yml` first:

```bash
pip list
dbt debug
```

`dbt-core` and `dbt-duckdb` should both be installed.

### `IO Error: database is locked`

Another process is holding a write connection to DuckDB, commonly an open notebook or Python session. Close that connection or reopen it with:

```python
duckdb.connect("credit_dbt/credit.duckdb", read_only=True)
```

### A dbt test fails after changing a model

Read the failing test name and inspect the affected transformation. Row-count failures usually indicate that a filter, cast or join has changed the number of loans moving through the pipeline.

Fix the transformation or its documented assumption rather than disabling the test to force a green build.

---

## Use of AI-assisted development tools

AI assistants were used during development, as permitted by the assessment brief.

- **Claude Code** was used for codebase-aware implementation support and debugging.
- **ChatGPT** was used for general research and discussion.

The reproducible logic, validation checks, documented methodology and outputs remain in this repository so that the work can be inspected and rerun independently of those tools.
