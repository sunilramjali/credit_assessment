# Part 2 — Modelling methodology

Reference for the two models in `modelling/`. It covers what I built, the
reasoning behind each decision, what each one costs, and where the results
should not be trusted.

| Part | Question | Target | Population | Notebook |
|---|---|---|---|---|
| **2a — classification** | Will this loan lose money? | `is_loss` | all 10,000 loans | `yhp_credit_classification.ipynb` |
| **2b — regression** | How much will it lose? | `loss_amount` | the 2,232 loans that lost something | `yhp_credit_regression.ipynb` |

Splitting the problem in two is the standard credit-risk decomposition. The
product of the halves is the figure a lender prices against:

```
expected loss per loan  =  P(loss)  ×  E[loss | loss]
                             2a           2b
```

---

## Contents

- [Pipeline architecture](#pipeline-architecture)
- [Part 2a — classification](#part-2a--classification)
- [Part 2b — regression](#part-2b--regression)
- [Inference function](#inference-function)
- [Results](#results)
- [Limitations](#limitations)
- [Next steps](#next-steps)
- [Running it](#running-it)

---

## Pipeline architecture

Feature preparation is split between dbt and the notebooks. The dividing line is
whether a step has to learn anything from the data.

| Step | Location | Reason |
|---|---|---|
| Drop `loss_amount`, assign the split, group rare categories, null out sentinel codes | `mart_ml_training_set` (dbt) | Fixed rules. They need no knowledge of the data, so they cannot carry test information into training, and dbt can test them. |
| Filter to `loss_amount > 0`, assign the split, null out sentinel codes | `mart_ml_severity_set` (dbt) | As above, for the regression population. |
| Encoding, imputation, scaling, rare-category grouping, model fitting | The notebooks | Fitted steps. They must see the training rows only, and doing that in SQL is awkward and easy to get subtly wrong. |

Fixed rules go in dbt. Fitted steps go in the notebook, downstream of the split.

### Why two marts rather than one

`loss_amount` is a leak in 2a and the target in 2b. Two tables mean a column
cannot be a feature in one model and the answer in another. Building the second
one takes a few minutes; discovering that a severity column had drifted into the
classifier's feature set would take considerably longer.

### An inconsistency I accepted

Rare-category grouping sits in dbt for 2a and in the pipeline for 2b.

Strictly it is a fitted step, so the pipeline is the more correct home. The dbt
version reaches the same guarantee by a different route — it computes its counts
from training rows only. 2b follows the reference regression methodology, which
implements grouping as a transformer, and I kept that rather than forcing the
two notebooks to match.

---

## Part 2a — Classification

### 1. Split by date, not at random

Cutoff `2024-10-01`: 8,037 training loans, 1,963 test loans.

`train_test_split(stratify=y)` is unsafe on this dataset. 5,427 of the 10,000
rows (54.3%) are byte-identical to another row across all 99 feature columns,
forming 2,435 duplicate groups. Within each group the rows share date, label and
loss amount — only `loan_id` differs. A random split places identical records on
both sides, and the model is then scored on copies of what it trained on. The
metrics would not show it; they would simply look good.

Duplicates always share a date, so none of the 2,435 groups straddle the cutoff.
A date split is structurally immune, and it matches how the model would be
deployed: fit on the past, predict the future.

**Cost.** Base rates differ across the split — 20.60% train, 23.59% test —
because the loss rate drifts upward over the period. The test set is harder than
the training set, so reported scores are conservative.

Asserted by `tests/assert_ml_split_is_chronological.sql` and re-checked in the
notebook.

### 2. Duplicate rows retained

The date split already blocks the leak, and removing rows the source supplied
would leave the test set no longer matching the book being scored.

**Cost.** A repeated record carries extra weight in training, so patterns in
duplicated loans are over-represented and effective sample sizes are smaller
than the row counts suggest. Refitting on the 7,008 distinct records to size the
effect is in [next steps](#next-steps).

### 3. `loss_amount` dropped in the schema, not the notebook

`is_loss ≈ loss_amount > 0` holds on 9,847 of 10,000 rows. Left in the feature
set, a careless `SELECT *` trains on the answer.

The column is dropped in the dbt model. A leakage guard written as a line of
pandas is one anyone can delete without noticing.

### 4. Sentinel codes replaced by NULL plus an indicator

19 of 94 numeric columns encode "no observation" as an all-nines code —
1,000,000,000, 99,995, 9,995, or 995–999 — rather than as a null. `feat_066_min`
is 87.0% code and `feat_030_max` is 72.9%. In total, 9,877 rows (98.8%) carry at
least one.

Left as numbers, they corrupt every mean, distance and coefficient that touches
them, which matters most for KNN, SVM and Logistic Regression. Removed without a
marker, the information that an observation was missing is lost, and "no history
available" may itself separate risk.

Each affected column has its code replaced by NULL and gains an `is_unobserved_*`
indicator.

**On detecting them.** An automated largest-relative-gap search first flagged 21
columns. Two — `feat_071_min` and `feat_057_min` — run continuously up to 18.6
million and 736 million, so their apparent cliffs were long tails rather than
codes. Tightening the rule to require a recognisable all-nines value gave 19. An
earlier version of the same search divided by the lower value of each pair and
flagged 91 of 94 columns, because a step from 0 to any positive number reads as
an infinite relative gap. The detection needed checking by hand at each stage.

### 5. Rare `feat_001` categories collapsed to `OTHER`

`feat_001` has 232 categories; 208 hold fewer than 100 loans and 115 hold fewer
than 10. One-hot encoding all of them produces 232 near-empty columns.

Categories with at least 100 training loans are kept — 19 of them — and the rest
become `OTHER`. The counts come from training rows only; deciding which
categories are common from the full dataset would let the test set shape the
encoding, which is leakage even though no target value is touched.

Four `feat_001` categories appear in the test period but never in training.
`OneHotEncoder(handle_unknown="ignore")` renders those as all-zero rows.

### 6. `class_weight="balanced"` rather than SMOTE

The reference classification methodology used SMOTE because its target was rare.
Here the loss class is 21% — imbalanced, not rare.

My reasoning for class weighting was that SMOTE interpolates minority examples
between existing points, and on a dataset that is over half duplicates it would
be generating synthetic records from copies.

The comparison did not support that reasoning:

| Setting | ROC-AUC | PR-AUC | Precision | Recall |
|---|---|---|---|---|
| SMOTE, no class weight | **0.6138** | **0.3133** | 0.3262 | 0.4579 |
| `class_weight="balanced"` | 0.6104 | 0.3012 | 0.3146 | 0.4471 |

SMOTE came out marginally ahead. Two things follow.

The mechanism I was concerned about did not bite on this data. Without the
comparison, a plausible argument would have gone into this document unchecked.

The difference is also too small to act on. +0.0034 ROC-AUC and +0.0121 PR-AUC on
a 1,963-row test set sit inside the range a different seed would move.

`class_weight="balanced"` remains the main path because it invents no rows and
needs no extra dependency, not because SMOTE was shown to harm. The two are
indistinguishable here.

KNN has no `class_weight` parameter and trains on the natural distribution. It
collapsed to predicting the majority class.

### 7. Model selection on ROC-AUC; threshold set separately

Credit scoring is a ranking problem: order loans by risk, then set a cut-off
according to how much good business the lender will decline. Fixing a threshold
during model selection answers a question that has not been asked yet.

ROC-AUC measures ranking independently of any cut-off. PR-AUC is reported beside
it because it is more informative on an imbalanced target, with the base rate
rather than 0.5 as its baseline.

The cut-off table is expressed as a share of the book rather than a probability,
for two reasons. SVM's `decision_function` returns a signed distance, not a
calibrated probability, so a 0.5 threshold is meaningless for it. And "decline
the riskiest N%" is how a credit policy is written.

### 8. Four models

KNN, SVM, Decision Tree and Logistic Regression, each tuned over one parameter
and refitted at its best setting, following the reference methodology.

Gradient boosting was excluded to stay within that methodology, but checked
separately: it reaches roughly 0.64 ROC-AUC against 0.61 for the best of the
four. The small gap suggests the ceiling is in the data rather than the model
choice.

---

## Part 2b — Regression

Severity: how much a loan loses, given that it lost something.

### 9. Population is `loss_amount > 0`

2,232 loans, split 1,781 train / 451 test.

Modelling `loss_amount` across all 10,000 loans would make 75.67% of the target
exactly zero. A linear model fitted on that predicts near zero almost
everywhere, and its R² measures how well it reproduces zeros rather than
anything about severity. It is a zero-inflated problem and linear regression is
the wrong tool for it.

The populations of the two models do not match. 2,232 loans have a positive loss
amount, 2,119 carry the loss flag, and 2,099 are in both; the gap is the 153
known label conflicts. This is why the expected-loss calculation is done at
portfolio level rather than per loan.

### 10. Target modelled as `log1p(loss_amount)`

Raw skewness is 3.55 — most losses are moderate, a few reach 440,332.
Untransformed, squared-error models chase the extremes and fit the body badly.

The transform is not a clean fix. log1p overcorrects to a skewness of −1.61,
because 60 loans (2.7%) fall below 1,000 and the log stretches them into a long
left tail; a cube root would be more symmetric at 0.49. I kept the log because it
is the conventional and defensible choice for loss severity, and because the
overcorrection comes from a small tail of very small losses rather than from the
body of the distribution.

Every reported error is back-transformed to currency. Models are fitted on the
log scale, predictions exponentiated, then MAE, RMSE and R² computed on the
original units.

### 11. A median baseline in the comparison table

The training median applied to every test loan, using no features at all.

It earned its place: Simple Linear Regression is worse than the baseline on MAE
(28,245 against 27,911). Without that row, a model that performs worse than no
model would have read as a modest result.

### 12. Polynomial degree by BIC, on a restricted feature set

Polynomial expansion is applied to the ten most correlated numeric features, not
to all 113.

Without the restriction the model fails. A degree-2 expansion of 113 features
gives 6,554 terms against 1,781 training rows — 3.7 parameters per observation.
With more parameters than observations OLS fits the training data exactly, the
residual sum of squares collapses towards zero, and the `n·ln(RSS/n)` term in BIC
runs to minus infinity. BIC then selects degree 2 because the model is
unidentifiable. Run that way it scored an MAE of 73.6 million against a target
whose median is 26,000.

BIC computed from training-set predictions is only reliable while parameters stay
well below observations. The notebook prints a `params_per_row` column beside the
BIC so the ratio is visible. With ten features it is 0.09 and BIC selects
degree 1.

### 13. Ridge and Lasso alphas tuned on a training-only validation split

The training set is split again, 80/20, and alpha chosen on the inner validation
fold. The test set is used once, for the final comparison.

Ridge suits this data: seven feature pairs correlate above 0.98, one at exactly
1.0000, and an L2 penalty stops correlated coefficients exploding against each
other. Lasso contributes differently, driving 89 of 167 coefficients to zero,
which is useful selection across 113 numeric columns with no data dictionary.

### 14. Inference function returns a calibrated probability, so it uses Logistic Regression

The brief asks the inference function to return "the probability of default and
the predicted dollar loss" given a `loan_id`.

SVM scored marginally higher on ROC-AUC (0.6112 against 0.6104) but its
`decision_function` returns a signed distance, not a probability. The function is
contracted to return a probability and the brief asks for discipline around
calibration, so `inference.py` uses Logistic Regression. The two models are
separated by 0.0008 ROC-AUC, which is noise; nothing is given up.

Nothing is re-fitted at prediction time. `build_artifacts()` fits the encoder,
imputer, scaler and both estimators on the training rows and serialises them
together with `joblib`. Re-fitting any of them against a new batch would change
the medians and scaling factors and shift every prediction, with no error raised.

### 15. Severity predictions are clipped to the fitted range

The severity model is fitted on 1,781 loss-making loans. Asked about a loan
outside that population it answers a counterfactual — how much this would have
lost, had it lost — from outside the domain it was trained on.

Ridge is linear and extrapolates without limit. One test loan carries
`feat_010` = 255,428 against a severity-training mean of 1,403 and standard
deviation of 2,568: 120 standard deviations out. Before clipping, that produced a
predicted loss of $86 billion. At the other extreme the raw log-scale predictions
reach −1,994,306.

Predictions are therefore clipped to the range of `log1p(loss_amount)` seen in
training, and the response carries `severity_clipped` and
`severity_in_population` flags so a caller can tell a clamped figure from an
estimate.

The clip is rare: 0.6% of out-of-population loans and 0.1% of in-population
loans. Mean predicted severity is consistent across both paths, $22,541 and
$20,378, which suggests the model behaves normally away from the extremes.

### 16. Expected loss combined at portfolio level

P(loss) × E[loss | loss], using the classifier's test base rate and the severity
model's mean prediction.

Not per loan, because the two marts have different schemas by design:
`mart_ml_training_set` carries `feat_001_grouped`, `mart_ml_severity_set` carries
the ungrouped `feat_001`. Scoring the severity model directly on classifier rows
produces an all-NULL column and meaningless predictions. The first version of the
notebook did exactly that and returned a mean severity of 6.7 × 10¹⁶ before the
mismatch was caught.

The modelled figure is 5,711 per funded loan against an actual 9,018 — a 36.7%
shortfall. The cause is the back-transform: `expm1` of a mean prediction is not
the mean of the predictions, so estimates are pulled towards the middle and the
large losses that drive the portfolio total are under-predicted. A smearing
correction is the standard remedy and is in [next steps](#next-steps).

---

## Inference function

`inference.py` implements the deliverable the brief asks for: given a `loan_id`,
pull that loan's feature vector, run it through both models, and return the
probability of default and the predicted dollar loss.

```python
from inference import predict

predict("LRQ-100067")
{'loan_id': 'LRQ-100067',
 'probability_of_default': 0.29365,
 'predicted_loss_given_default': 16945.21,
 'expected_loss_usd': 4975.97,
 'received_date': '2019-03-07',
 'data_split': 'train',
 'scored_on_training_data': True,
 'severity_in_population': True,
 'severity_clipped': False}
```

Also available from the command line:

```bash
python inference.py --build              # fit and serialise, ~5 seconds
python inference.py LRQ-100067 --json
```

Latency is around 20 ms per call once the artefacts are loaded, since the models
and both feature tables are cached in memory after the first request.

### Returned fields

`predicted_loss_given_default` is severity conditional on a loss, because that is
what the regression models. `expected_loss_usd` is the product of the two, which
is the unconditional figure. Both are returned rather than one, because "the
predicted dollar loss" is ambiguous between them and the caller should not have
to guess which they have.

The last four fields exist so a caller can judge how much to trust the numbers.
`scored_on_training_data` is true for loans the models were fitted on, where the
prediction is optimistic. `severity_in_population` and `severity_clipped` are
explained in decision 15.

### Assumptions

The function reads feature vectors from `mart_ml_training_set` and
`mart_ml_severity_set`, so it scores loans already in the warehouse. A genuinely
new loan would need the dbt preparation rules — the sentinel thresholds, the rare
category grouping, the dropped target — restated in Python, and the two
implementations could then drift. Keeping the rules in one place and running new
loans through dbt first would be the production answer.

---

## Results

### Classification — test set, 1,963 loans

| Model | ROC-AUC | PR-AUC | Precision | Recall | Accuracy |
|---|---|---|---|---|---|
| SVM (C=10, linear) | **0.6112** | 0.2982 | 0.300 | 0.503 | 0.606 |
| Logistic Regression (C=1.0) | 0.6104 | **0.3012** | 0.315 | 0.447 | 0.640 |
| Decision Tree (max_depth=2) | 0.5822 | 0.2704 | 0.278 | 0.266 | 0.664 |
| KNN (k=40) | 0.5397 | 0.2651 | 0.000 | 0.000 | **0.762** |

KNN has the highest accuracy and is the worst model. It predicts "no loss" for
every test loan and is right 76% of the time, because that is the share that do
not default. This is why accuracy was not the selection metric.

SVM and Logistic Regression are separated by 0.0008 ROC-AUC, which is noise.

Ranking quality is more usefully seen in deciles of the test set:

| Risk decile | Loans | Actual loss rate |
|---|---|---|
| 1 (riskiest) | 196 | 33.2% |
| 5 | 196 | 31.1% |
| 10 (safest) | 198 | 12.1% |

A 2.7× spread between the extreme deciles, declining broadly but not perfectly
monotonically. ROC-AUC of 0.61 is modest; separation of this size is still usable
for prioritisation.

### Regression — test set, 451 loans

| Model | MAE | RMSE | R² |
|---|---|---|---|
| Ridge (alpha=100) | 25,797 | **41,744** | 0.088 |
| Lasso (alpha=0.01) | **25,714** | 41,774 | 0.087 |
| Polynomial (degree 1) | 26,933 | 42,661 | 0.048 |
| Multiple Linear | 26,933 | 42,661 | 0.048 |
| Simple Linear | 28,245 | 48,316 | −0.221 |
| Baseline (median) | 27,911 | 48,458 | −0.229 |

Degree 1 and Multiple Linear are identical because degree 1 applies no
expansion — the polynomial model found nothing worth adding.

The regularised models beat the baseline by about 2,100 on MAE, roughly 7.6%,
and explain under 9% of the variance in severity. These features carry real but
weak information about how much a loan loses. That is a property of the data
rather than a failure of the models.

Results are exported by `export_predictions.py` to `modelling/predictions/`.

---

## Limitations

### Applying to both models

1. **About 1.5% of labels are known to be wrong.** 153 loans have `is_loss`
   contradicting `loss_amount`, including one flagged as no-loss with a 101,341
   loss. Labels are kept as supplied, so no classifier can exceed roughly 98.5%
   accuracy, and the errors are not randomly distributed.
2. **Every result is duplicate-weighted.** See decision 2.
3. **The test set is harder than the training set by construction**, at 20.60%
   against 23.59% base rate. Scores are conservative.
4. **Recent loans are not fully seasoned.** Some test-set "no loss" labels may yet
   become losses, which pushes against point 3.
5. **No feature meaning is available.** The models rank; they do not explain. No
   coefficient should be given a business reading.
6. **Category effects are uncontrolled.** No adjustment for vintage, and the
   portfolio loss rate drifts from 15.1% to 26.7% across the period.
7. **One split, not a backtest.** Performance is measured on a single future
   window.

### Regression only

8. **The features carry little information about severity.** Under 9% of variance
   explained. Read every result against the median baseline.
9. **Back-transforming from the log scale biases predictions downward**, which is
   the direct cause of the 36.7% shortfall in the expected-loss figure.
10. **451 test loans is a small evaluation set.** Ridge and Lasso are separated by
    30 on RMSE and 83 on MAE, which is noise rather than a ranking.
11. **The severity test set is also harder**, at a mean loss of 39,250 against
    28,750 in training.
12. **The expected-loss figure is an illustration.** The two models are fitted on
    different populations and were not validated jointly.

---

## Next steps

- Refit on the 7,008 distinct records to size the duplicate effect rather than
  only noting it.
- Add gradient boosting to both halves. It handles sparse categoricals and heavy
  missingness natively and needs neither imputation nor scaling.
- Move cut-off selection onto an expected-cost basis once a cost for a missed loss
  and for a declined good loan are available, so the model optimises money rather
  than a statistic.
- Replace the single split with a rolling-origin backtest.
- Apply Duan's smearing estimator to the severity back-transform to remove the
  systematic under-prediction. A few lines, not a redesign.
- Fit a Tweedie or gamma GLM on all 10,000 loans as an alternative to the
  frequency-severity split. Both handle a mass at zero with a continuous positive
  tail, which is the shape of `loss_amount`, and would give expected loss from one
  model.
- Validate the two models jointly on a common population so expected loss can be
  scored per loan.

---

## Running it

```bash
source .venv/bin/activate
pip install -r requirements.txt

cd credit_dbt
dbt build --select mart_ml_training_set mart_ml_severity_set

cd ../modelling
jupyter notebook yhp_credit_classification.ipynb    # Part 2a, ~10 minutes
jupyter notebook yhp_credit_regression.ipynb        # Part 2b, ~1 minute
python export_predictions.py                        # results to CSV, ~3 minutes
```

The SVM parameter sweep accounts for almost all of the classification runtime.
