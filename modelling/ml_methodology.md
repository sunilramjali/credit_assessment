# Part 2 — Credit-risk modelling

This section explains the modelling approach used to estimate credit risk. Two
models were developed because the decision involves two separate questions:

| Part | Question | Target | Population |
|---|---|---|---|
| **2a — Classification** | Is this loan likely to result in a loss? | `is_loss` | All 10,000 loans |
| **2b — Regression** | If a loss occurs, how large is it likely to be? | `loss_amount` | 2,232 loans with a positive loss amount |

Together, the models provide an estimate of expected loss:

```text
Expected loss = Probability of loss × Expected loss amount if a loss occurs
```

## Data preparation

Data preparation was divided between dbt and Python. Fixed, repeatable rules
were applied in dbt, while steps that learn from the training data were included
in the modelling pipelines.

| Stage | Main tasks |
|---|---|
| dbt | Create the modelling datasets, assign the time-based split, remove target leakage and replace known sentinel codes with null values |
| Python pipelines | Encode categories, impute missing values, scale numeric features, group rare categories and fit the models |

Separate datasets were created for classification and regression. This prevents
`loss_amount` from accidentally entering the classification model as a feature,
while allowing it to remain the target for regression.

## Classification model

### Train and test split

The data was split by date using 1 October 2024 as the cut-off:

- Training set: 8,037 loans
- Test set: 1,963 loans

A chronological split was more appropriate than a random split for two reasons.
First, it reflects real use: a model is trained on past applications and applied
to future ones. Second, 5,427 rows share the same feature values as at least one
other record. A random split could place matching records in both sets and
overstate model performance.

The loss rate increased from 20.60% in training to 23.59% in testing. The test
period is therefore somewhat more challenging and also reflects a change in the
portfolio over time.

### Feature preparation

`loss_amount` was excluded because it closely reveals the classification target.
Across the dataset, `is_loss` and `loss_amount > 0` agree for 9,847 of the 10,000
loans.

Nineteen numeric features used values such as 999, 9,995, 99,995 or
1,000,000,000 to represent an unavailable observation. These values were
replaced with nulls and paired with indicator columns so that the model could
retain information about whether a value was originally unobserved.

`feat_001` contained 232 categories, most with very few records. Categories with
fewer than 100 training loans were grouped as `OTHER` to reduce sparse
one-hot-encoded features. Category frequencies were calculated from training
data only.

### Class imbalance

Approximately 21% of loans were labelled as losses. The main models used class
weighting so that loss cases received greater importance without creating
synthetic observations.

SMOTE was also tested. It produced a slightly higher ROC-AUC of 0.6138 compared
with 0.6104 for class weighting, but the difference was too small to support a
meaningful preference. Class weighting was retained as the simpler approach.

### Model comparison

Four models were evaluated. ROC-AUC was used as the main comparison metric
because the purpose of the classifier is to rank loans by risk. PR-AUC,
precision, recall and accuracy were also reported.

| Model | ROC-AUC | PR-AUC | Precision | Recall | Accuracy |
|---|---:|---:|---:|---:|---:|
| SVM (linear, C=10) | **0.6112** | 0.2982 | 0.300 | **0.503** | 0.606 |
| Logistic Regression (C=1.0) | 0.6104 | **0.3012** | **0.315** | 0.447 | 0.640 |
| Decision Tree (max depth=2) | 0.5822 | 0.2704 | 0.278 | 0.266 | 0.664 |
| KNN (k=40) | 0.5397 | 0.2651 | 0.000 | 0.000 | **0.762** |

KNN achieved the highest accuracy but predicted no losses at all. Its result
shows why accuracy is misleading when one class is much more common than the
other.

SVM achieved the highest ROC-AUC, although its lead over Logistic Regression was
only 0.0008. Logistic Regression was selected for the inference function because
it provides a probability directly. The SVM score is a relative distance from
the decision boundary and is not a calibrated probability.

The ranking was useful but modest. In the highest-risk test decile, 33.2% of
loans resulted in a loss, compared with 12.1% in the lowest-risk decile. This is
a 2.7-fold difference, although risk did not decline perfectly across every
intermediate decile.

## Loss-severity model

The regression model estimates the size of a loss, conditional on a positive
loss having occurred.

### Modelling population

Only the 2,232 loans with `loss_amount > 0` were included:

- Training set: 1,781 loans
- Test set: 451 loans

Using all loans would make 75.67% of the target values zero. A conventional
linear model would then focus mainly on reproducing the zeros rather than
estimating loss severity.

The loss flag and positive loss amount do not identify exactly the same records.
There are 2,119 loans marked as losses, 2,232 with a positive loss amount and
2,099 that meet both conditions. This discrepancy is considered when the two
models are combined.

### Target transformation

Positive losses were strongly right-skewed, with a small number of values as
high as 440,332. The model was fitted to `log1p(loss_amount)` so that extreme
losses had less influence on the fitted relationship. Predictions were then
converted back to the original currency scale before evaluation.

### Model selection

The regression comparison included a median baseline so that each model could
be judged against a simple prediction that uses no loan features.

Polynomial regression was restricted to the ten numeric features most closely
associated with the target. Expanding all features would produce more parameters
than training observations and lead to severe overfitting. The Bayesian
Information Criterion selected degree 1, indicating that the additional
polynomial terms did not improve the model.

Ridge and Lasso regularisation strengths were selected using a validation split
within the training data. The final test set was used only for evaluation.

| Model | MAE | RMSE | R² |
|---|---:|---:|---:|
| Ridge (alpha=100) | 25,797 | **41,744** | **0.088** |
| Lasso (alpha=0.01) | **25,714** | 41,774 | 0.087 |
| Multiple Linear Regression | 26,933 | 42,661 | 0.048 |
| Simple Linear Regression | 28,245 | 48,316 | -0.221 |
| Median baseline | 27,911 | 48,458 | -0.229 |

Ridge and Lasso reduced MAE by approximately 2,100, or 7.6%, compared with the
baseline. However, they explained less than 9% of the variation in loss size.
The available features therefore provide only limited information about
severity.

Ridge was used in the inference function because it handled the highly
correlated predictors well and achieved the lowest RMSE. Severity predictions
were restricted to the range observed in the training data to prevent extreme
extrapolation. The output identifies any prediction affected by this safeguard.

## Expected loss

At portfolio level, expected loss was calculated as:

```text
Test loss rate × Mean predicted loss severity
```

The model estimated an expected loss of 5,711 per funded loan, compared with an
observed value of 9,018. This is a 36.7% underestimation. Much of the shortfall is
linked to converting predictions back from the logarithmic scale, which pulls
estimates towards the centre and understates the largest losses.

This portfolio estimate should be treated as illustrative. The two models use
different target definitions because of inconsistencies between `is_loss` and
`loss_amount`, and they have not yet been validated jointly on a common
population.

## Inference output

The inference function accepts a `loan_id` and returns:

| Field | Meaning |
|---|---|
| `probability_of_default` | Estimated probability that the loan results in a loss |
| `predicted_loss_given_default` | Estimated loss amount if a loss occurs |
| `expected_loss_usd` | Probability of loss multiplied by predicted severity |
| `scored_on_training_data` | Whether the loan was used to fit the model |
| `severity_in_population` | Whether the loan belongs to the population used for severity modelling |
| `severity_clipped` | Whether the severity estimate was restricted to the training range |

The function scores loans already available in the prepared data. In a
production setting, new applications would need to pass through the same dbt
transformations before scoring.

## Limitations

- **Target inconsistencies:** 153 loans have conflicting values between
  `is_loss` and `loss_amount`. The supplied labels were retained.
- **Duplicate records:** repeated feature profiles remain in the data and may
  give some patterns more weight during training.
- **Changing risk over time:** the loss rate is higher in the test period than
  in the training period, so performance may partly reflect portfolio drift.
- **Recent loans may be incomplete:** some recent loans currently labelled as
  no loss may not yet have reached their final outcome.
- **Anonymised features:** the absence of a feature dictionary prevents a
  reliable business interpretation of individual coefficients or importance
  scores.
- **Single test period:** performance was assessed on one future window rather
  than across several time-based backtests.
- **Limited severity performance:** the regression models explain less than 9%
  of the variation in loss size and systematically under-predict portfolio loss.
- **Small severity test set:** the regression results are based on 451 test
  loans, so small differences between Ridge and Lasso should not be treated as
  conclusive.

## Recommended next steps

1. Refit the models using distinct feature records to measure the effect of
   duplication.
2. Replace the single time split with rolling time-based backtesting.
3. Correct the bias introduced when severity predictions are converted back
   from the log scale.
4. Test gradient-boosting models, which may handle non-linear relationships and
   missing values more effectively.
5. Select a classification threshold using the financial cost of missed losses
   and rejected good loans.
6. Validate probability and severity together on a consistent population before
   using expected loss for individual lending decisions.
