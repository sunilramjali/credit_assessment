# Part 2 — Methodology note

Classification of `is_loss` on 10,000 funded SMB loans.

The notebook is `yhp_credit_classification.ipynb`. This file records the
decisions behind it and the reasoning for each, so the notebook can stay focused
on the work.

---

## Where the work happens

| Layer | What it does | Why there |
|---|---|---|
| `mart_ml_training_set` (dbt) | Drops `loss_amount`, assigns the split, groups rare categories, converts sentinel codes to NULL | These are **fixed rules**. They need no knowledge of the data, so they cannot move test information into training, and they can be covered by dbt tests. |
| `yhp_credit_classification.ipynb` | Encoding, imputation, scaling, model fitting | These must be **fitted**, and fitted on the training rows alone. Doing them in SQL would be awkward and easy to get subtly wrong. |

The dividing line is simply: *does this step have to learn anything from the
data?* If no, it belongs in dbt. If yes, it belongs in the notebook, downstream
of the split.

---

## Decisions

### 1. Time-based split, not random

Cutoff `2024-10-01` — 8,037 training loans, 1,963 test loans.

**Why not `train_test_split(stratify=y)`:** 5,427 of the 10,000 rows (54.3%) are
byte-identical to another row across all 99 feature columns, forming 2,435
duplicate groups. Within every group the rows share the same date, label and
loss amount; only `loan_id` differs.

A random split would put identical records on both sides of it. The model would
memorise the training set and be scored on copies of it. Nothing in the metrics
would reveal this — the scores would simply look good.

Because duplicates always share a date, **none of the 2,435 groups straddle this
cutoff**. A time split is structurally immune. It is also how the model would be
used: fit on the past, predict the future.

**Cost:** base rates differ across the split — 20.60% train, 23.59% test —
because the loss rate drifts upward across the period. That makes the test set
harder than the training set, so the reported scores are conservative rather
than flattering.

Enforced by `tests/assert_ml_split_is_chronological.sql`, and re-asserted inside
the notebook.

### 2. Duplicate rows kept

No rows removed.

The time split already blocks the leak, and deleting rows the source supplied
would mean the test set no longer matches the book being scored.

**Cost:** a repeated record carries extra weight during training, so patterns in
duplicated loans are over-represented. Effective sample sizes are smaller than
the row counts suggest. Every result must be read with this attached.

The alternative — refitting on the 7,008 distinct records to size the effect —
is listed under next steps.

### 3. `loss_amount` excluded, in the schema

`is_loss ≈ loss_amount > 0` holds for 9,847 of 10,000 rows. Left in the feature
set, a careless `SELECT *` trains on the answer.

The column is dropped in the dbt model rather than in notebook code, because a
leakage guard written as one line of pandas is a leakage guard anyone can delete
without noticing.

### 4. Sentinel codes converted to NULL plus an indicator

19 of 94 numeric columns encode "no observation" as an all-nines code —
1,000,000,000, 99,995, 9,995 or 995–999 — rather than as a null. `feat_066_min`
is 87.0% code; `feat_030_max` is 72.9%. **9,877 rows (98.8%) carry at least one.**

Left as numbers they corrupt every mean, distance and coefficient that touches
them, which is fatal for KNN, SVM and Logistic Regression. Dropped without a
marker, the information that an observation was missing is lost — and "no
history available" may itself separate risk.

So each affected column gets its code replaced by NULL and gains an
`is_unobserved_*` indicator. The value stops being a lie; the absence survives
as a feature.

**A detection note worth recording:** an automated largest-relative-gap search
initially flagged 21 columns. Two of them, `feat_071_min` and `feat_057_min`,
turned out to run continuously up to 18.6 million and 736 million — their
apparent cliffs were ordinary long tails, not codes. The rule was tightened to
require a recognisable all-nines value, giving 19. An earlier version of the
same search, dividing by the lower value of each pair, flagged 91 of 94 columns
because a step from 0 to any positive number looks like an infinite relative
gap. Automated detection needed a human check at every stage.

### 5. Rare `feat_001` categories collapsed to `OTHER`

`feat_001` has 232 categories; 208 hold fewer than 100 loans and 115 hold fewer
than 10. One-hot encoding all of them would produce 232 near-empty columns.

Categories with at least 100 **training** loans are kept — 19 of them — and the
rest become `OTHER`.

**The counts come from training rows only.** Using the whole dataset to decide
which categories are common would let the test set influence the encoding. That
is leakage even though no target value is touched, and it is easy to do by
accident.

Four `feat_001` categories appear in the test period but never in training.
`OneHotEncoder(handle_unknown="ignore")` turns those into all-zero rows rather
than raising an error.

### 6. `class_weight="balanced"` rather than SMOTE

The brain stroke notebook this methodology follows used SMOTE, because a stroke
was rare in that dataset. Here the loss class is 21% — imbalanced, not rare.

SMOTE interpolates new minority examples between existing ones. On a dataset
where over half the rows are already duplicates of each other, it would
manufacture synthetic records from copies, adding no information while inflating
apparent performance.

SMOTE is still run at the end as an explicit comparison, so the choice is shown
rather than asserted.

KNN has no `class_weight` parameter, so it trains on the natural distribution.
Its results should be read with that in mind — and in the event, it collapsed to
predicting the majority class.

### 7. Selection on ROC-AUC, threshold chosen afterwards

Credit scoring is a ranking problem: order loans by risk, then choose a cut-off
according to how much good business the lender will decline. Baking one
threshold into model selection answers a question nobody asked.

ROC-AUC measures ranking quality independently of any cut-off. PR-AUC is
reported beside it because it is more informative on an imbalanced target, and
its baseline is the base rate rather than 0.5.

**The cut-off table is expressed as a share of the book, not as a probability.**
Two reasons: SVM's `decision_function` returns a signed distance rather than a
calibrated probability, so a 0.5 cut-off would be meaningless for it; and
"decline the riskiest N%" is how a credit policy is actually written.

### 8. Four models, matching the reference methodology

KNN, SVM, Decision Tree, Logistic Regression — each tuned over one parameter,
then refitted at its best setting.

Gradient boosting was deliberately excluded to stay with the methodology being
followed, but was checked separately: it reaches roughly 0.64 ROC-AUC against
the best of these four at about 0.61. The gap is small, which suggests the
ceiling is in the data rather than in the model choice.

---

## Limitations

1. **About 1.5% of labels are known to be wrong.** 153 loans have `is_loss`
   contradicting `loss_amount`, including one flagged as no-loss with a 101,341
   loss. Labels are kept as supplied, so no model can exceed roughly 98.5%
   accuracy, and the errors are not randomly distributed.

2. **Every result is duplicate-weighted.** See decision 2.

3. **The test set is harder than the training set by construction.** 20.60%
   against 23.59% base rate. Scores are conservative.

4. **Recent loans are not fully seasoned.** Loans near the end of the window have
   had less time to default, so some test-set "no loss" labels may yet become
   losses. This pushes in the opposite direction to point 3.

5. **No feature meaning is available.** The model can be said to rank; it cannot
   be said to explain. No coefficient should be given a business reading.

6. **Category effects are uncontrolled.** No adjustment for vintage, and the
   portfolio loss rate drifts from 15.1% to 26.7% across the period.

7. **One split, not a backtest.** Performance is measured on a single future
   window. A rolling-origin evaluation would show whether it holds across
   several vintages.

---

## What I would do next

- Refit on the 7,008 distinct records and compare, to size the duplicate effect
  rather than only noting it.
- Add gradient boosting, which handles sparse categoricals and heavy missingness
  natively and needs neither imputation nor scaling.
- Move cut-off selection onto an expected-cost basis, once a cost for a missed
  loss and a cost for a declined good loan are available. At that point the
  model optimises money rather than a statistic.
- Replace the single split with a rolling-origin backtest.
- Model expected loss directly rather than the loss flag, since frequency and
  severity have moved in opposite directions since 2023.

---

## Reproducing

```bash
source .venv/bin/activate
pip install -r requirements.txt

cd credit_dbt
dbt build --select mart_ml_training_set     # 9 tests, all must pass
cd ../modelling
jupyter notebook yhp_credit_classification.ipynb
```

The notebook takes roughly ten minutes to run end to end. The SVM parameter
sweep is almost all of it.
