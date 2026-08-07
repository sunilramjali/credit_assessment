# YHP Credit Assessment

I started this project in a Jupyter notebook, exploring the raw data
to see what was actually in it. Once I understood the data, I decided on the
architecture and the method, and then built the pipeline. Along the way I used
Claude Code as a coding assistant — coding efficiency & debugging with the whole project
in context — and ChatGPT for general research.

**Live dashboard:** https://datastudio.google.com/s/taLG52JGGKY
(Note: Make sure the filter is not selecting all)

**Part 1 write-up:** [`part1_credit_risk_analysis.pdf`](part1_credit_risk_analysis.pdf)
— the three findings, the data-quality section, and what each one means for a
small-business lender. Six pages. Every figure in it comes from a tested mart in
this repo.

## What this project is

This project takes a raw loan dataset and turns it into a small set of clean,
tested tables that answer credit-risk questions.

The raw data is one SQLite file with two tables: 10,000 funded loans with their
outcomes, and 99 anonymised features describing each loan. The loans were
received between **2018-04-11 and 2025-12-18**, and **21.19%** of them ended in
a recorded loss.

The job is to answer questions like:

- How much are we losing, and how often?
- Is the loss rate getting better or worse over time?
- Are some kinds of loan riskier than others?
- Can the data be trusted?

The work is done with **dbt** and **DuckDB**. dbt writes the SQL and runs the
tests. DuckDB is the database, and it reads the SQLite file directly — so there
is no separate import step and no copy of the data to keep in sync.

Every number this project publishes comes out of a tested table. If a number is
wrong, a test fails and the build stops.

---

## How the project fits together

The work moves through three stages. Each stage has one job, and each one hands
its output to the next.

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

**1. Notebook — explore.** `exploration/yhp_credit_exploration.ipynb` opens the
raw SQLite file and asks questions of it: what columns exist, what is missing,
what looks wrong. This is where the understanding comes from. Nothing here is
part of the pipeline — it is thinking out loud, and it does not need to run
again.

**2. dbt + DuckDB — build and test.** Everything the notebook found that turned
out to be true gets written down as a model in `credit_dbt/`. dbt writes the
SQL, builds the tables in layers (staging → intermediate → marts), and runs a
test after every one. This is the only place where a number is calculated. Run
`dbt build` and you get the same tables every time.

**3. Looker Studio — show.** The marts are exported to CSV and uploaded to
Looker, which draws the charts. Looker does **no** calculation: no custom
formulas, no blended fields, no filters that change a number. If a figure on a
dashboard looks wrong, the fix belongs in a dbt model, not in Looker.

The rule that holds this together: **calculation happens in one place only.**
The notebook is where you find things out, dbt is where you make them true, and
Looker is where you show them. Push logic backwards down the arrow, never
forwards.

---

## What gets built

Thirteen tables, in three layers. Each layer has one job.

### Staging — clean the raw data, nothing more

| Table | Rows | What it does |
|---|---|---|
| `stg_loans` | 10,000 | Reads the loans table. Fixes the types: dates become real dates, `is_loss` becomes true/false. |
| `stg_loan_features` | 10,000 | Reads the features table. Numbers become numbers, categories stay text. |

### Intermediate — join the two together

| Table | Rows | What it does |
|---|---|---|
| `int_loans_joined` | 10,000 | One row per loan: the outcome plus all 99 features. |

### Marts — the tables you actually use

| Table | Rows | What it answers |
|---|---|---|
| `mart_portfolio_kpis` | 29 | The headline numbers for the whole book. Start here. |
| `mart_portfolio_kpis_wide` | 1 | The same numbers, one row, one column each. Use this one for BI dashboards. |
| `mart_portfolio_yearly` | 8 | How the portfolio performed each year. |
| `mart_portfolio_seasonality` | 28 | The same, split by quarter within each year. |
| `mart_risk_segmentation` | 295 | Loss outcomes per category of all 5 categorical features, all-time, against the portfolio benchmark. |
| `mart_loss_concentration` | 2,232 | Every loss-making loan, ranked biggest first, with cumulative totals. |
| `mart_loss_concentration_summary` | 4 | Share of losses carried by the top 1%, 5%, 10% and 20% of loss-making loans. |
| `mart_loss_severity_bands` | 5 | How losses spread across five size bands. |
| `mart_ml_training_set` | 10,000 | Model-ready features for Part 2a, with the train/test split and the leakage guards built in. |
| `mart_ml_severity_set` | 2,232 | Model-ready features for Part 2b. Only loans that lost money — here `loss_amount` is the target, not a leak. |

---

# USER GUIDE

## What you need first

1. **Python 3.12** installed.
2. **The data file.** `data/` is not in git, because the dataset is private. You
   must put the file here yourself:

   ```
   data/YHP_credit_assessment_DS.sqlite
   ```

   Without this file nothing will build.

---

## Step 1 — Turn on the virtual environment

From the top folder of the project:

```bash
source .venv/bin/activate
```

If the `.venv` folder does not exist yet, make it first:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

You will know it worked because your terminal line starts with `(.venv)`.

---

## Step 2 — Install the libraries

Only needed the first time, or when `requirements.txt` changes:

```bash
pip install -r requirements.txt
```

Check it worked:

```bash
pip list
```

You should see `dbt-core`, `dbt-duckdb` and `duckdb` in the list.

---

## Step 3 — Move into the dbt folder

**This step matters. Do not skip it.**

```bash
cd credit_dbt
```

All dbt commands must be run from inside `credit_dbt/`, not from the top
folder. The paths to the database and the SQLite file are relative, so running
from the wrong place quietly builds an empty database in the wrong location.
See "When things go wrong" below.

---

## Step 4 — Install the dbt package

Only needed the first time:

```bash
dbt deps
```

This downloads `dbt_utils`, which some of the models and tests use.

---

## Step 5 — Check the connection

```bash
dbt debug
```

You want to see **All checks passed**.

---

## Step 6 — Build everything

```bash
dbt build
```

This does three things in order: it builds the tables, it runs all the tests,
and it stops immediately if any test fails.

A good run ends like this:

```
Done. PASS=145 WARN=0 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=145
```

**145 out of 145 passing is the expected result.** If you see any ERROR, do not
use the output — something is wrong with the data or the code.

The finished database is `credit_dbt/credit.duckdb`.

### What the tests are checking

Most of the 145 are ordinary column checks — is this unique, is it ever null, is
it one of these allowed values. A handful do something different and are worth
knowing about, because they catch faults that column checks cannot see:

| Test | What breaks without it |
|---|---|
| Row counts match between each staging table and its source | A failed cast or a stray filter quietly dropping loans on the way out of SQLite |
| Row count matches between `int_loans_joined` and `stg_loans` | The join fanning out and silently multiplying rows |
| Every `loan_id` in `stg_loans` exists in `stg_loan_features` | A loan arriving with 99 empty feature columns |
| `mart_portfolio_yearly` totals match the loans it was built from | A `GROUP BY` dropping a whole year while every column still looks fine |
| Segment and band shares sum to 1 | A share calculated against the wrong denominator |
| The concentration curve ends at exactly 1 | A window function ordered or framed wrongly |
| The ML train/test split is chronological | A test loan leaking into the training period |

The pattern: the ordinary tests ask whether a **column** is well formed. These
ask whether the table still **adds up** to what it came from. A table can pass
every column check and still be missing a year of loans.

---

## Step 7 — Export the results to CSV

Go back to the top folder first:

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

Each script writes one CSV into `exports/`. The CSVs are just a copy of the
tables — the database is always the source of truth.

Which CSV feeds which dashboard:

| Dashboard | CSV |
|---|---|
| KPI scorecards | `mart_portfolio_kpis_wide.csv` |
| 1 — time and vintage | `mart_portfolio_yearly.csv`, `mart_portfolio_seasonality.csv` |
| 2 — risk segmentation | `mart_risk_segmentation.csv` |
| 3 — loss concentration | `mart_loss_concentration.csv`, `mart_loss_concentration_summary.csv`, `mart_loss_severity_bands.csv` |

Every script sorts its rows on the way out. For most of them this is only
tidiness, but for `mart_loss_concentration.csv` it is the whole point: the
concentration curve **is** the row order, running from the largest loss down.

---

## Everyday commands

Once it is set up, these are the ones you will use.

| Command | What it does |
|---|---|
| `dbt build` | Build everything and test everything. The safe default. |
| `dbt build --select mart_portfolio_kpis` | Build and test one model only. Much faster while you work. |
| `dbt run` | Build the tables but skip the tests. Use only when in a hurry. |
| `dbt test` | Run the tests without rebuilding. |
| `dbt build --select +mart_portfolio_kpis` | Build one model **and everything it depends on**. |
| `dbt docs generate && dbt docs serve` | Open a website showing every table, column and how they connect. |

Remember: run all of these from inside `credit_dbt/`.

---

## Reading the data yourself

You can query the database directly with Python:

```python
import duckdb

con = duckdb.connect("credit_dbt/credit.duckdb", read_only=True)
print(con.execute("select * from mart_portfolio_kpis order by kpi_display_order").df())
```

Always open it with `read_only=True` unless you mean to change it. DuckDB
allows only one writer at a time, so an open notebook holding a write
connection will block `dbt build` from running.

---

## How to read `mart_portfolio_kpis`

This table is shaped differently from the others. Instead of one row with many
columns, it has **29 rows, one per number**:

| Column | Meaning |
|---|---|
| `kpi_group` | Which section: `volume`, `frequency`, `severity` or `data_quality`. |
| `kpi_name` | The name of the number, for example `portfolio_loss_rate`. |
| `kpi_unit` | How to read it: `count`, `rate`, `rate_change`, `amount` or `date`. |
| `kpi_display_order` | The order to show them in. |
| `is_headline` | True for the 8 numbers a reader should see first. |
| `kpi_value` | The number itself. |
| `kpi_value_text` | Used only for dates, which have no sensible number form. |

**If you want the short version, filter on `is_headline`:**

```sql
select * from mart_portfolio_kpis where is_headline order by kpi_display_order
```

That gives 8 numbers instead of 29. The rest of the table is the detail behind
them, and stays there when you need it.

**Always check `kpi_unit` before you format a value.** All the numbers share one
column, so nothing stops you printing a loss rate of `0.2119` as £0.21. The unit
column is what tells you it is a proportion, not money. `rate_change` can be
negative; the other units cannot.

### Three important warnings this table gives you

**1. The loss rate counts loans, not money.** The source has no loan amount
column, so `portfolio_loss_rate` means "21.19% of loans went bad". It does
**not** mean "we lost 21.19% of what we lent". That second number cannot be
calculated from this data.

**2. One average hides a rising trend.** The overall rate is 21.19%, but that
covers eight years. The last 12 months of the book ran at **23.46%** against
**21.91%** the year before. Quote the trend alongside the average, not instead
of it.

**3. Over half the rows are repeats.** `duplicate_feature_vector_rate` is
**0.5427** — 5,427 of the 10,000 rows share their 99 feature values exactly with
another row, leaving only 7,008 truly distinct records. Every other number in
this table, including the loss rate, is weighted by those repeats. This is a
property of the source data, not a bug in the pipeline, but you should know it
before quoting anything.

The `data_quality` group also reports 153 loans where `is_loss` disagrees with
`loss_amount`, and 4 loans with no loss amount at all. These are known problems
in the source data. They are reported, not silently fixed.

## Putting the KPIs on a Looker scorecard

**Use `mart_portfolio_kpis_wide`, not `mart_portfolio_kpis`.**

A scorecard shows one field as one number. The long table cannot do that: all 29
values live in the single `kpi_value` column, so a scorecard would add them all
together, and every card would be stuck sharing one number format.

The wide table is the same numbers turned sideways — **one row, 29 columns, one
column per KPI.** Each card points at its own field, so each field gets its own
type and its own formatting.

### Steps

1. Export the file:

   ```bash
   python exports/export_mart_kpis_wide.py
   ```

   This writes `exports/mart_portfolio_kpis_wide.csv` — a header row and one
   data row.

2. In Looker Studio, add a data source and upload that CSV (File Upload).

3. Add a **Scorecard**. Set the Metric to the field you want, for example
   `portfolio_loss_rate`. The aggregation does not matter, because there is
   only one row.

4. Set the format on the field:

   | Field type | Format to use |
   |---|---|
   | `*_rate`, `*_change` | Percent |
   | `total_*_amount`, `average_*` | Currency |
   | `*_count`, `*_days` | Number |
   | `*_date` | Date |

### For a scorecard with a comparison arrow

Set the Metric to `loss_rate_last_12_months` and the Comparison to
`loss_rate_prior_12_months`. Looker will show 23.5% with the change against
21.9% underneath. `loss_rate_12_month_change` already holds that difference if
you would rather show it as its own card.

**One warning: `loss_rate_12_month_change` can be negative.** It is the only
field here that can. Do not format it as an unsigned percent, or a year of
improving losses will display as if nothing changed.

### Which columns to put on the panel

These 8 are the ones marked `is_headline` in the long table:

`funded_loan_count` · `portfolio_loss_rate` · `loss_rate_last_12_months` ·
`loss_rate_12_month_change` · `total_recorded_loss_amount` ·
`average_loss_per_funded_loan` · `average_loss_severity` ·
`duplicate_feature_vector_rate`

The other 21 columns are still in the file if you need them.

---

### Which "total loss" is which

The table publishes three, and they differ by about £2 million:

| KPI | Value | What it means |
|---|---|---|
| `total_recorded_loss_amount` | 68,530,441.67 | Every loss amount, with the 197 recoveries netted off. **This is the headline one.** |
| `total_positive_loss_amount` | 68,905,381.05 | Losses only, recoveries ignored. |
| (sum over `is_loss` rows) | 66,928,268.75 | Lower, because 133 loans lost real money but are flagged as no loss. |

All three are correct. They answer different questions. Pick one, name it, and
stick to it.

---

## When things go wrong

**"All checks passed" but the tables are empty.**
You ran dbt from the top folder instead of `credit_dbt/`. This creates a second,
empty `credit.duckdb` in the top folder. Delete that stray file, `cd credit_dbt`,
and build again. This failure is quiet — `dbt debug` still says everything is
fine, because it only opens a connection and does not read the SQLite file.

**`Could not find adapter type ...`**
Almost never means a missing library. It usually means the config file has a
structure problem, such as wrong indentation. Check `profiles.yml` first before
installing anything.

**`IO Error: database is locked`**
Something else has the database open for writing, usually a notebook. Close it,
or reconnect with `read_only=True`.

**A test fails after you change a model.**
That is the system working. Read which test failed — the name tells you the
table, the column and the rule. Fix the cause, not the test.

**A row-count test fails.**
Something changed how many rows survive a step. Check for a filter added to a
staging model, a cast that turned values into nulls, or a join key that stopped
being unique. These tests exist because that kind of change raises no error on
its own.

---

## Project layout

```
yhp_credit_assessment/
├── credit_dbt/              <- run all dbt commands from here
│   ├── models/
│   │   ├── staging/         <- clean the raw data
│   │   ├── intermediate/    <- join the tables
│   │   └── marts/           <- the tables you use
│   ├── tests/               <- checks that span whole tables
│   ├── macros/              <- reusable SQL snippets
│   ├── profiles.yml         <- database connection settings
│   ├── dbt_project.yml      <- project settings
│   └── credit.duckdb        <- the built database (not in git)
├── data/                    <- the source SQLite file (not in git)
├── exploration/             <- notebook used to explore the raw data
├── exports/                 <- scripts that write the CSVs, and the CSVs
├── modelling/               <- Part 2
│   ├── yhp_credit_classification.ipynb   <- 2a: will it lose money?
│   ├── yhp_credit_regression.ipynb       <- 2b: how much?
│   ├── inference.py                      <- score a loan by loan_id
│   ├── export_predictions.py             <- writes the results to CSV
│   ├── artifacts/                        <- the fitted models
│   ├── predictions/                      <- the model results
│   └── ml_methodology.md    <- why each modelling decision was made
├── requirements.txt
└── README.md
```

Every `.sql` model has a `.yml` file beside it describing what each column
means and which tests it must pass. If you want to know what a column is, read
the `.yml` — that is what it is for.

---

## Part 2 — the prediction model

Part 2 is two models, one for each half of the question a lender asks.

| Notebook | Question | Target | Loans used |
|---|---|---|---|
| `yhp_credit_classification.ipynb` | Will this loan lose money? | `is_loss` | all 10,000 |
| `yhp_credit_regression.ipynb` | How much will it lose? | `loss_amount` | the 2,232 that lost something |

Multiplied together they give **expected loss per loan**, in money:

```
expected loss  =  P(loss)  x  average loss when it happens
```

Run them after `dbt build`:

```bash
cd modelling
jupyter notebook yhp_credit_classification.ipynb    # about 10 minutes
jupyter notebook yhp_credit_regression.ipynb        # about 1 minute
```

The classification notebook is slow because of the SVM tuning.

Why two separate tables feed them: in the classifier, `loss_amount` gives away
the answer, so it is dropped. In the regression it **is** the answer. Keeping
them apart means a column cannot quietly be a clue in one model and the answer
in the other.

The feature preparation is split across two places on purpose:

- **dbt** does the steps that are fixed rules — dropping `loss_amount`,
  assigning the train/test split by date, grouping rare categories, turning
  sentinel codes into nulls. These need no knowledge of the data, so they cannot
  leak, and dbt can test them.
- **The notebook** does the steps that must be *learned* from data — encoding,
  filling gaps, scaling. All of these are fitted on the training rows only.

The rule is: if a step has to learn something from the data, it happens after
the split, in the notebook.

`modelling/ml_methodology.md` records why each decision was made, what it costs,
and the limitations of the result. Read that before quoting any score.

### Scoring a loan

The brief asks for an inference function: give it a `loan_id`, get back the
probability of default and the predicted dollar loss.

```bash
cd modelling
python inference.py --build          # fit and save the models, once, ~5 seconds
python inference.py LRQ-100067
```

Or from Python:

```python
from inference import predict

predict("LRQ-100067")
{'loan_id': 'LRQ-100067',
 'probability_of_default': 0.29365,
 'predicted_loss_given_default': 16945.21,   # USD, if it does default
 'expected_loss_usd': 4975.97,               # probability x the line above
 ...}
```

Nothing is re-fitted when you call `predict`. The models and all the fitted
preprocessing are saved once by `--build` and loaded from disk, so a call takes
about 20 milliseconds. Re-fitting on each call would change the fill values and
scaling and quietly move every prediction.

Two fields in the response are warnings rather than results.
`scored_on_training_data` is true for loans the models learned from, where the
prediction flatters itself. `severity_clipped` is true when the dollar figure had
to be capped because the loan sat outside the range the severity model was
trained on — it happens to about 0.6% of loans, and without the cap those
predictions run to absurd values.

### Getting the results out

The notebooks show their results as tables and charts inside the cells. To get
them as files you can chart or check without re-running anything:

```bash
cd modelling
python export_predictions.py
```

This refits the tuned models at the settings the notebooks chose — it does not
repeat the parameter searches — and writes four files into
`modelling/predictions/`:

| File | Rows | What it holds |
|---|---|---|
| `predictions_classification.csv` | 1,963 | One row per test loan: the actual outcome, both models' scores, and a risk decile. |
| `predictions_regression.csv` | 451 | One row per loss-making test loan: actual loss, predicted loss, and the error. |
| `model_comparison_classification.csv` | 4 | The metrics table for the four classifiers. |
| `model_comparison_regression.csv` | 4 | The same for the regression models. |

It takes about three minutes. Fitting the SVM is nearly all of it.

These files live in `modelling/predictions/`, not `exports/`. That is
deliberate: `exports/` holds dbt tables copied out unchanged for Looker, so
anything in there can be traced straight back to a tested model. Model
predictions are a different kind of thing — they depend on a fitted model, not
just on the data — and mixing them in would break that guarantee.

**The risk decile is the column worth looking at.** Decile 1 is the riskiest
tenth of the test loans and 33.2% of them lost money; decile 10 is the safest
and 12.1% did. That 2.7-times spread is what the model is actually good for.
Its ROC-AUC of 0.61 sounds unimpressive, and it is modest, but ranking loans
into deciles that differ this much is still useful for deciding where to look
first.
