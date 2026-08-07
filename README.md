# YHP Credit Assessment

I started this project in a Jupyter notebook, exploring the raw data
to see what was actually in it. Once I understood the data, I decided on the
architecture and the method, and then built the pipeline. Along the way I used
Claude Code as a coding assistant — coding efficiency & debugging with the whole project
in context — and ChatGPT for general research.

**Live dashboard:** https://datastudio.google.com/s/taLG52JGGKY
(Note: Make sure the filter is not selecting all)

**Part 1 write-up:** [`part1_credit_risk_analysis.pdf`](part1_credit_risk_analysis.pdf)
— three findings, a data-quality section, and what each means for a
small-business lender. Six pages. Every figure comes from a tested mart in this
repo.

## What this project is

A raw loan dataset turned into a set of clean, tested tables that answer
credit-risk questions.

The source is one SQLite file with two tables: 10,000 funded loans with their
outcomes, and 99 anonymised features describing each loan. The loans were
received between **2018-04-11 and 2025-12-18**, and **21.19%** ended in a
recorded loss. Amounts are in USD.

Questions the project answers:

- How much are we losing, and how often?
- Is the loss rate getting better or worse over time?
- Are some kinds of loan riskier than others?
- Can the data be trusted?

Built with **dbt** and **DuckDB**. dbt writes the SQL and runs the tests. DuckDB
is the database and reads the SQLite file directly, so there is no separate
import step and no second copy of the data to keep in sync.

Every published number comes from a tested table. If a number is wrong, a test
fails and the build stops.

---

## How the project fits together

```
   ┌─────────────┐      ┌──────────────────┐      ┌────────────────┐
   │  NOTEBOOK   │ ───► │  dbt  +  DuckDB  │ ───► │ LOOKER STUDIO  │
   │             │      │                  │      │                │
   │   explore   │      │  build  &  test  │      │      show      │
   └─────────────┘      └──────────────────┘      └────────────────┘
    exploration/           credit_dbt/               exports/*.csv
     one-off,              repeatable,               read-only,
     throwaway             tested                    no logic
```

**1. Notebook.** `exploration/yhp_credit_exploration.ipynb` opens the raw SQLite
file and profiles it: what columns exist, what is missing, what looks wrong.
None of it is part of the pipeline and none of it needs to run again.

**2. dbt + DuckDB.** Whatever the notebook established gets written as a model in
`credit_dbt/`. dbt builds the tables in layers (staging → intermediate → marts)
and runs a test after each one. This is the only place a number is calculated.

**3. Looker Studio.** The marts are exported to CSV and uploaded to Looker, which
draws the charts. Looker performs no calculation: no custom formulas, no blended
fields, no filters that change a number. A wrong figure on a dashboard is fixed
in a dbt model, not in Looker.

Calculation happens in one place only.

---

## What gets built

Thirteen tables across three layers.

### Staging

| Table | Rows | Description |
|---|---|---|
| `stg_loans` | 10,000 | Loan outcomes, typed. Dates cast to DATE, `is_loss` to BOOLEAN. |
| `stg_loan_features` | 10,000 | The 99 features, typed. Numerics cast to DOUBLE, categoricals to VARCHAR. |

### Intermediate

| Table | Rows | Description |
|---|---|---|
| `int_loans_joined` | 10,000 | One row per loan: outcome plus all 99 features. |

### Marts

| Table | Rows | Description |
|---|---|---|
| `mart_portfolio_kpis` | 29 | Headline numbers for the whole book. |
| `mart_portfolio_kpis_wide` | 1 | The same numbers, one row, one column each. For BI dashboards. |
| `mart_portfolio_yearly` | 8 | Portfolio performance by year. |
| `mart_portfolio_seasonality` | 28 | The same, by quarter within each year. |
| `mart_risk_segmentation` | 295 | Loss outcomes per category of all 5 categorical features, all-time, against the portfolio benchmark. |
| `mart_loss_concentration` | 2,232 | Every loss-making loan, ranked largest first, with cumulative totals. |
| `mart_loss_concentration_summary` | 4 | Share of losses carried by the top 1%, 5%, 10% and 20% of loss-making loans. |
| `mart_loss_severity_bands` | 5 | Loss distribution across five size bands. |
| `mart_ml_training_set` | 10,000 | Model-ready features for Part 2a, with the train/test split and leakage guards applied. |
| `mart_ml_severity_set` | 2,232 | Model-ready features for Part 2b. Loss-making loans only; here `loss_amount` is the target. |

---

# USER GUIDE

## Prerequisites

1. **Python 3.12.**
2. **The data file.** `data/` is not in git, so place the source file at:

   ```
   data/YHP_credit_assessment_DS.sqlite
   ```

   Nothing builds without it.

---

## Step 1 — Virtual environment

From the top folder:

```bash
source .venv/bin/activate
```

If `.venv` does not exist yet:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

---

## Step 2 — Install dependencies

First run, or whenever `requirements.txt` changes:

```bash
pip install -r requirements.txt
```

Confirm with `pip list` — `dbt-core`, `dbt-duckdb` and `duckdb` should appear.

---

## Step 3 — Move into the dbt folder

```bash
cd credit_dbt
```

All dbt commands run from inside `credit_dbt/`, not the top folder. The paths to
the database and the SQLite file are relative, so running from elsewhere builds
an empty database in the wrong location without reporting an error. See
[When things go wrong](#when-things-go-wrong).

---

## Step 4 — Install the dbt package

First run only:

```bash
dbt deps
```

Downloads `dbt_utils`, used by several models and tests.

---

## Step 5 — Check the connection

```bash
dbt debug
```

Expect **All checks passed**.

---

## Step 6 — Build

```bash
dbt build
```

Builds the tables, runs every test, and stops on the first failure.

```
Done. PASS=145 WARN=0 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=145
```

145 of 145 is the expected result. Any ERROR means the output should not be
used.

The built database is `credit_dbt/credit.duckdb`.

### What the tests cover

Most of the 145 are column checks: unique, not null, accepted values. Seven
check something a column test cannot see.

| Test | Fault it catches |
|---|---|
| Row counts match between each staging table and its source | A failed cast or stray filter dropping loans on the way out of SQLite |
| Row count matches between `int_loans_joined` and `stg_loans` | The join fanning out and multiplying rows |
| Every `loan_id` in `stg_loans` exists in `stg_loan_features` | A loan arriving with 99 empty feature columns |
| `mart_portfolio_yearly` totals match the loans it was built from | A `GROUP BY` dropping a whole year while every column still validates |
| Segment and band shares sum to 1 | A share computed against the wrong denominator |
| The concentration curve ends at exactly 1 | A window function ordered or framed wrongly |
| The ML train/test split is chronological | A test loan leaking into the training period |

Column tests ask whether a column is well formed. These ask whether the table
still reconciles to its source.

---

## Step 7 — Export to CSV

From the top folder:

```bash
cd ..
python exports/export_mart_kpis.py
python exports/export_mart_kpis_wide.py
python exports/export_mart_yearly.py
python exports/export_mart_season.py
python exports/export_mart_segmentation.py
python exports/export_mart_concentration.py
python exports/export_mart_concentration_summary.py
python exports/export_mart_severity_bands.py
```

Each script writes one CSV into `exports/`. The CSVs are copies; the database is
the source of truth.

| Dashboard | CSV |
|---|---|
| KPI scorecards | `mart_portfolio_kpis_wide.csv` |
| 1 — time and vintage | `mart_portfolio_yearly.csv`, `mart_portfolio_seasonality.csv` |
| 2 — risk segmentation | `mart_risk_segmentation.csv` |
| 3 — loss concentration | `mart_loss_concentration.csv`, `mart_loss_concentration_summary.csv`, `mart_loss_severity_bands.csv` |

Every script sorts on the way out. For `mart_loss_concentration.csv` the order is
load-bearing: the concentration curve is the row order, running from the largest
loss down.

---

## Everyday commands

| Command | Effect |
|---|---|
| `dbt build` | Build and test everything. |
| `dbt build --select mart_portfolio_kpis` | Build and test one model. |
| `dbt run` | Build the tables, skip the tests. |
| `dbt test` | Run the tests without rebuilding. |
| `dbt build --select +mart_portfolio_kpis` | Build one model and its upstream dependencies. |
| `dbt docs generate && dbt docs serve` | Browse every table, column and dependency. |

Run all of these from inside `credit_dbt/`.

---

## Querying the database directly

```python
import duckdb

con = duckdb.connect("credit_dbt/credit.duckdb", read_only=True)
print(con.execute("select * from mart_portfolio_kpis order by kpi_display_order").df())
```

Open with `read_only=True` unless writing. DuckDB permits one writer at a time,
so an open notebook holding a write connection blocks `dbt build`.

---

## Reading `mart_portfolio_kpis`

This table is shaped differently from the others: **29 rows, one per number**,
rather than one row with many columns.

| Column | Meaning |
|---|---|
| `kpi_group` | Section: `volume`, `frequency`, `severity` or `data_quality`. |
| `kpi_name` | Name of the number, for example `portfolio_loss_rate`. |
| `kpi_unit` | `count`, `rate`, `rate_change`, `amount` or `date`. |
| `kpi_display_order` | Presentation order. |
| `is_headline` | True for the 8 numbers to show first. |
| `kpi_value` | The number. |
| `kpi_value_text` | Dates only, which have no numeric form. |

For the short version:

```sql
select * from mart_portfolio_kpis where is_headline order by kpi_display_order
```

That returns 8 numbers instead of 29; the rest is the supporting detail.

Check `kpi_unit` before formatting a value. All the numbers share one column, so
nothing prevents a loss rate of `0.2119` being printed as $0.21. `rate_change`
can be negative; the other units cannot.

### Three caveats this table reports

**1. The loss rate counts loans, not money.** The source has no loan amount
column, so `portfolio_loss_rate` means 21.19% of loans went bad, not that 21.19%
of the money lent was lost. The second figure cannot be derived from this data.

**2. One average hides a rising trend.** The overall rate is 21.19% across eight
years. The last 12 months of the book ran at **23.46%** against **21.91%** the
year before.

**3. Over half the rows are repeats.** `duplicate_feature_vector_rate` is
**0.5427** — 5,427 of the 10,000 rows share their 99 feature values exactly with
another row, leaving 7,008 distinct records. Every other number in the table,
including the loss rate, is weighted by those repeats. This is a property of the
source data, not the pipeline.

The `data_quality` group also reports 153 loans where `is_loss` disagrees with
`loss_amount`, and 4 loans with no loss amount. Both are surfaced rather than
corrected.

### Which "total loss" is which

Three are published, differing by about $2 million:

| KPI | Value (USD) | Definition |
|---|---|---|
| `total_recorded_loss_amount` | 68,530,441.67 | Every loss amount, net of the 197 recoveries. The headline figure. |
| `total_positive_loss_amount` | 68,905,381.05 | Losses only, recoveries excluded. |
| (sum over `is_loss` rows) | 66,928,268.75 | Lower, because 133 loans lost money while flagged as no loss. |

All three are correct and answer different questions.

---

## Putting the KPIs on a Looker scorecard

Use `mart_portfolio_kpis_wide`, not `mart_portfolio_kpis`.

A scorecard displays one field as one number. In the long table all 29 values sit
in a single `kpi_value` column, so a scorecard would sum them, and every card
would share one number format. The wide table is the same data transposed — one
row, 29 columns — so each card points at its own field with its own type and
formatting.

1. Export the file:

   ```bash
   python exports/export_mart_kpis_wide.py
   ```

2. In Looker Studio, add a data source and upload the CSV (File Upload).

3. Add a **Scorecard** and set the Metric, for example `portfolio_loss_rate`.
   Aggregation is irrelevant with one row.

4. Set the field format:

   | Field pattern | Format |
   |---|---|
   | `*_rate`, `*_change` | Percent |
   | `total_*_amount`, `average_*` | Currency (USD) |
   | `*_count`, `*_days` | Number |
   | `*_date` | Date |

**Comparison arrow.** Set the Metric to `loss_rate_last_12_months` and the
Comparison to `loss_rate_prior_12_months`. Looker shows 23.5% with the change
against 21.9% beneath it. `loss_rate_12_month_change` holds the same difference
as a standalone figure.

`loss_rate_12_month_change` is the only field here that can be negative. Do not
format it as an unsigned percent, or a year of falling losses will display as no
change.

**Panel fields** — the 8 marked `is_headline`:

`funded_loan_count` · `portfolio_loss_rate` · `loss_rate_last_12_months` ·
`loss_rate_12_month_change` · `total_recorded_loss_amount` ·
`average_loss_per_funded_loan` · `average_loss_severity` ·
`duplicate_feature_vector_rate`

The other 21 columns remain in the file.

---

## When things go wrong

**"All checks passed" but the tables are empty.**
dbt was run from the top folder instead of `credit_dbt/`, creating a second,
empty `credit.duckdb` there. Delete the stray file, `cd credit_dbt`, rebuild.
`dbt debug` still reports success in this state, because it only opens a
connection and never reads the SQLite file.

**`Could not find adapter type ...`**
Rarely a missing library. Usually a structural problem in the config, such as
wrong indentation. Check `profiles.yml` before installing anything.

**`IO Error: database is locked`**
Something holds the database open for writing, usually a notebook. Close it, or
reconnect with `read_only=True`.

**A test fails after a model change.**
The test name identifies the table, column and rule. Fix the cause rather than
the test.

**A row-count test fails.**
The number of rows surviving a step has changed. Look for a filter added to a
staging model, a cast producing nulls, or a join key that stopped being unique.
None of these raise an error on their own.

---

## Project layout

```
yhp_credit_assessment/
├── credit_dbt/              <- run all dbt commands from here
│   ├── models/
│   │   ├── staging/
│   │   ├── intermediate/
│   │   └── marts/
│   ├── tests/               <- table-level checks
│   ├── macros/
│   ├── profiles.yml         <- connection settings
│   ├── dbt_project.yml
│   └── credit.duckdb        <- built database (not in git)
├── data/                    <- source SQLite file (not in git)
├── exploration/             <- profiling notebook
├── exports/                 <- export scripts and the CSVs
├── modelling/               <- Part 2
│   ├── yhp_credit_classification.ipynb   <- 2a: will it lose money?
│   ├── yhp_credit_regression.ipynb       <- 2b: how much?
│   ├── inference.py                      <- score a loan by loan_id
│   ├── export_predictions.py             <- model results to CSV
│   ├── artifacts/                        <- fitted models
│   ├── predictions/                      <- model results
│   └── ml_methodology.md                 <- modelling decisions and reasoning
├── part1_credit_risk_analysis.pdf
├── requirements.txt
└── README.md
```

Every `.sql` model has a `.yml` beside it documenting each column and the tests
it must pass.

---

## Part 2 — the models

Two models, one for each half of the question.

| Notebook | Question | Target | Loans used |
|---|---|---|---|
| `yhp_credit_classification.ipynb` | Will this loan lose money? | `is_loss` | all 10,000 |
| `yhp_credit_regression.ipynb` | How much will it lose? | `loss_amount` | the 2,232 that lost something |

Their product is expected loss per loan, in USD:

```
expected loss  =  P(loss)  x  average loss when it happens
```

Run them after `dbt build`:

```bash
cd modelling
jupyter notebook yhp_credit_classification.ipynb    # ~10 minutes
jupyter notebook yhp_credit_regression.ipynb        # ~1 minute
```

The SVM tuning accounts for most of the classification runtime.

Two separate tables feed them because `loss_amount` gives away the answer in the
classifier and is the answer in the regression. Keeping them apart prevents a
column being a feature in one model and the target in the other.

Feature preparation is split across two places:

- **dbt** applies the fixed rules — dropping `loss_amount`, assigning the
  train/test split by date, grouping rare categories, nulling sentinel codes.
  These require no knowledge of the data, so they cannot leak, and dbt tests
  them.
- **The notebooks** apply the fitted steps — encoding, imputation, scaling — all
  fitted on the training rows alone.

If a step has to learn from the data, it happens after the split, in the
notebook.

`modelling/ml_methodology.md` documents every decision, its cost, and the
limitations of the results.

### Scoring a loan

The inference function takes a `loan_id` and returns the probability of default
and the predicted dollar loss.

```bash
cd modelling
python inference.py --build          # fit and save the models, ~5 seconds
python inference.py LRQ-100067
```

From Python:

```python
from inference import predict

predict("LRQ-100067")
{'loan_id': 'LRQ-100067',
 'probability_of_default': 0.29365,
 'predicted_loss_given_default': 16945.21,   # USD, conditional on default
 'expected_loss_usd': 4975.97,               # probability x the line above
 ...}
```

Nothing is re-fitted on a call. The models and all fitted preprocessing are saved
once by `--build` and loaded from disk, so a call takes about 20 milliseconds.
Re-fitting per call would change the fill values and scaling factors and shift
every prediction.

Two response fields are qualifiers rather than results.
`scored_on_training_data` is true for loans the models were fitted on, where the
prediction is optimistic. `severity_clipped` is true where the dollar figure was
capped because the loan fell outside the range the severity model was trained on;
it applies to about 0.6% of loans, and the uncapped predictions in those cases
are not usable.

### Model results

The notebooks display their results inline. To produce them as files:

```bash
cd modelling
python export_predictions.py
```

This refits the tuned models at the settings the notebooks selected — it does not
repeat the parameter searches — and writes four files to `modelling/predictions/`:

| File | Rows | Contents |
|---|---|---|
| `predictions_classification.csv` | 1,963 | Per test loan: actual outcome, both models' scores, risk decile. |
| `predictions_regression.csv` | 451 | Per loss-making test loan: actual loss, predicted loss, error. |
| `model_comparison_classification.csv` | 4 | Metrics for the four classifiers. |
| `model_comparison_regression.csv` | 4 | Metrics for the regression models. |

Runtime is about three minutes, almost all of it the SVM fit.

These files sit in `modelling/predictions/` rather than `exports/`. `exports/`
holds dbt tables copied out unchanged, so every file there traces back to a
tested model; model predictions depend on a fitted model as well as the data.

Ranking quality is clearest in the `risk_decile` column: decile 1 is the riskiest
tenth of test loans at a 33.2% actual loss rate, decile 10 the safest at 12.1%.
A 2.7× spread. The ROC-AUC of 0.61 is modest, but separation of that size is
usable for prioritisation.
