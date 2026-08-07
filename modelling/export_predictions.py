"""
Export Part 2 model results to CSV.

Refits the tuned models at the hyperparameters chosen in the notebooks, then
writes their test-set predictions and metrics to modelling/predictions/.

No parameter sweeps are re-run here. The sweeps, the plots and the reasoning
live in the notebooks; this script exists so the results can be read, charted
and checked without executing a notebook that takes ten minutes.

Outputs are written to modelling/predictions/ rather than exports/, because
exports/ holds dbt marts copied verbatim for Looker. These files are model
output, which is a different kind of artefact with a different provenance.

Run from the modelling/ directory:

    python export_predictions.py

Takes roughly four minutes. The SVM fit is almost all of it.
"""

import time
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

from sklearn.base import BaseEstimator, TransformerMixin
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.linear_model import LogisticRegression, LinearRegression, Ridge, Lasso
from sklearn.neighbors import KNeighborsClassifier
from sklearn.svm import SVC
from sklearn.tree import DecisionTreeClassifier
from sklearn.metrics import (
    accuracy_score, precision_score, recall_score, f1_score,
    roc_auc_score, average_precision_score,
    mean_absolute_error, mean_squared_error, r2_score,
)

RANDOM_STATE = 42

project_root = Path(__file__).resolve().parent.parent
database_path = project_root / "credit_dbt" / "credit.duckdb"
output_dir = project_root / "modelling" / "predictions"

print(f"Connecting to: {database_path}")

if not database_path.exists():
    raise FileNotFoundError(f"Database not found: {database_path}")

output_dir.mkdir(exist_ok=True)


def load(table):
    """Read a mart and cast boolean features to int, as the notebooks do."""
    with duckdb.connect(str(database_path), read_only=True) as con:
        frame = con.execute(f"select * from {table}").df()
    bool_features = [
        c for c in frame.select_dtypes(include=["bool"]).columns if c != "is_loss"
    ]
    frame[bool_features] = frame[bool_features].astype(int)
    return frame


# ---------------------------------------------------------------------------
# Part 2a — classification
# ---------------------------------------------------------------------------

print("\n[1/2] Classification — is_loss")
start = time.time()

df = load("mart_ml_training_set")
identifiers = ["loan_id", "split", "received_date"]
target = "is_loss"

features = df.drop(columns=identifiers + [target])
cat_cols = features.select_dtypes(include=["object"]).columns.tolist()
num_cols = features.select_dtypes(include=[np.number]).columns.tolist()

assert len(cat_cols) + len(num_cols) == features.shape[1], (
    f"feature columns matched neither selector: "
    f"{set(features.columns) - set(cat_cols) - set(num_cols)}"
)

train_mask = df["split"] == "train"
X_train = df.loc[train_mask, cat_cols + num_cols].copy()
X_test = df.loc[~train_mask, cat_cols + num_cols].copy()
y_train = df.loc[train_mask, target].astype(int)
y_test = df.loc[~train_mask, target].astype(int)

# Every fitted step learns from the training rows only.
encoder = OneHotEncoder(sparse_output=False, handle_unknown="ignore").fit(X_train[cat_cols])
encoded_names = encoder.get_feature_names_out(cat_cols)


def encode(frame):
    encoded = pd.DataFrame(
        encoder.transform(frame[cat_cols]), columns=encoded_names, index=frame.index
    )
    return pd.concat([frame.drop(columns=cat_cols), encoded], axis=1)


X_train, X_test = encode(X_train), encode(X_test)

imputer = SimpleImputer(strategy="median").fit(X_train[num_cols])
X_train[num_cols] = imputer.transform(X_train[num_cols])
X_test[num_cols] = imputer.transform(X_test[num_cols])

scaler = StandardScaler().fit(X_train[num_cols])
X_train[num_cols] = scaler.transform(X_train[num_cols])
X_test[num_cols] = scaler.transform(X_test[num_cols])

classifiers = {
    "SVM (C=10, linear)": SVC(
        C=10, kernel="linear", class_weight="balanced",
        random_state=RANDOM_STATE, cache_size=1000,
    ),
    "Logistic Regression (C=1.0)": LogisticRegression(
        C=1.0, max_iter=2000, class_weight="balanced", random_state=RANDOM_STATE
    ),
    "Decision Tree (max_depth=2)": DecisionTreeClassifier(
        max_depth=2, class_weight="balanced", random_state=RANDOM_STATE
    ),
    "KNN (k=40)": KNeighborsClassifier(n_neighbors=40),
}

classification_rows = []
scores = {}

for label, model in classifiers.items():
    print(f"  fitting {label} ...", end=" ", flush=True)
    fit_start = time.time()
    model.fit(X_train, y_train)
    predictions = model.predict(X_test)
    score = (
        model.predict_proba(X_test)[:, 1]
        if hasattr(model, "predict_proba")
        else model.decision_function(X_test)
    )
    scores[label] = score

    classification_rows.append({
        "model": label,
        "roc_auc": roc_auc_score(y_test, score),
        "pr_auc": average_precision_score(y_test, score),
        "accuracy": accuracy_score(y_test, predictions),
        "precision": precision_score(y_test, predictions, zero_division=0),
        "recall": recall_score(y_test, predictions, zero_division=0),
        "f1_score": f1_score(y_test, predictions, zero_division=0),
    })
    print(f"{time.time() - fit_start:.0f}s")

classification_comparison = (
    pd.DataFrame(classification_rows).sort_values("roc_auc", ascending=False).reset_index(drop=True)
)

svm_score = scores["SVM (C=10, linear)"]
logreg_probability = scores["Logistic Regression (C=1.0)"]

# Both winning models are exported. SVM ranks marginally better on ROC-AUC
# (0.6112 against 0.6104) but its decision_function is a signed distance, not a
# probability. Logistic Regression gives a calibrated probability, which is what
# anything downstream actually needs, and the two are statistically
# indistinguishable. Exporting both lets the reader choose without re-fitting.
classification_predictions = pd.DataFrame({
    "loan_id": df.loc[~train_mask, "loan_id"].values,
    "received_date": df.loc[~train_mask, "received_date"].values,
    "actual_is_loss": y_test.values,
    "svm_score": svm_score,
    "logreg_probability_of_loss": logreg_probability,
})

# Decile 1 is the riskiest tenth. This is the unit a lending policy is written
# in -- "decline the riskiest N%" -- and it works for any scorer, calibrated or
# not.
classification_predictions["risk_decile"] = (
    pd.qcut(classification_predictions["svm_score"], 10, labels=False, duplicates="drop")
    .rsub(9)
    .add(1)
)
classification_predictions = classification_predictions.sort_values(
    "svm_score", ascending=False
).reset_index(drop=True)

print(f"  done in {time.time() - start:.0f}s")


# ---------------------------------------------------------------------------
# Part 2b — regression
# ---------------------------------------------------------------------------

print("\n[2/2] Regression — loss_amount")
start = time.time()


class RareCategoryGrouper(BaseEstimator, TransformerMixin):
    """Replace categories below min_count with RARE. Learned during fit only."""

    def __init__(self, min_count=20):
        self.min_count = min_count

    def fit(self, X, y=None):
        self.keep_ = {}
        for column in X.columns:
            counts = X[column].astype(str).value_counts()
            self.keep_[column] = set(counts[counts >= self.min_count].index)
        return self

    def transform(self, X):
        X = X.copy()
        for column in X.columns:
            values = X[column].astype(str)
            X[column] = values.where(values.isin(self.keep_[column]), "RARE")
        return X


severity = load("mart_ml_severity_set")
severity_identifiers = ["loan_id", "split", "received_date", "is_loss"]
severity_target = "loss_amount"

severity_features = severity.drop(columns=severity_identifiers + [severity_target])
severity_cat = severity_features.select_dtypes(include=["object"]).columns.tolist()
severity_num = severity_features.select_dtypes(include=[np.number]).columns.tolist()

assert len(severity_cat) + len(severity_num) == severity_features.shape[1], (
    "severity feature columns matched neither selector"
)

severity_train_mask = severity["split"] == "train"
SX_train = severity.loc[severity_train_mask, severity_cat + severity_num].copy()
SX_test = severity.loc[~severity_train_mask, severity_cat + severity_num].copy()
sy_train = severity.loc[severity_train_mask, severity_target]
sy_test = severity.loc[~severity_train_mask, severity_target]

categorical_pipeline = Pipeline([
    ("group_rare", RareCategoryGrouper(min_count=20)),
    ("impute", SimpleImputer(strategy="constant", fill_value="MISSING")),
    ("encode", OneHotEncoder(handle_unknown="ignore", sparse_output=False)),
])
numeric_pipeline = Pipeline([
    ("impute", SimpleImputer(strategy="median")),
    ("scale", StandardScaler()),
])
preprocessor = ColumnTransformer([
    ("categorical", categorical_pipeline, severity_cat),
    ("numeric", numeric_pipeline, severity_num),
])

regressors = {
    "Ridge (alpha=100)": Ridge(alpha=100.0, max_iter=10000),
    "Lasso (alpha=0.01)": Lasso(alpha=0.01, max_iter=10000),
    "Multiple Linear Regression": LinearRegression(),
}

regression_rows = [{
    "model": "Baseline (training median)",
    "MAE": mean_absolute_error(sy_test, np.full(len(sy_test), sy_train.median())),
    "RMSE": float(np.sqrt(mean_squared_error(sy_test, np.full(len(sy_test), sy_train.median())))),
    "R2": r2_score(sy_test, np.full(len(sy_test), sy_train.median())),
}]
regression_predictions_by_model = {}

for label, model in regressors.items():
    print(f"  fitting {label} ...", end=" ", flush=True)
    fit_start = time.time()
    pipeline = Pipeline([("preprocessor", preprocessor), ("model", model)])

    # Fitted on log1p, predictions back-transformed so errors are in currency.
    pipeline.fit(SX_train, np.log1p(sy_train))
    predictions = np.clip(np.expm1(pipeline.predict(SX_test)), 0, None)
    regression_predictions_by_model[label] = predictions

    regression_rows.append({
        "model": label,
        "MAE": mean_absolute_error(sy_test, predictions),
        "RMSE": float(np.sqrt(mean_squared_error(sy_test, predictions))),
        "R2": r2_score(sy_test, predictions),
    })
    print(f"{time.time() - fit_start:.0f}s")

regression_comparison = (
    pd.DataFrame(regression_rows).sort_values(["RMSE", "MAE"]).reset_index(drop=True)
)

best_severity = regression_predictions_by_model["Ridge (alpha=100)"]
regression_predictions = pd.DataFrame({
    "loan_id": severity.loc[~severity_train_mask, "loan_id"].values,
    "received_date": severity.loc[~severity_train_mask, "received_date"].values,
    "actual_loss_amount": sy_test.values,
    "predicted_loss_amount": best_severity,
})
regression_predictions["residual"] = (
    regression_predictions["actual_loss_amount"] - regression_predictions["predicted_loss_amount"]
)
regression_predictions["absolute_error"] = regression_predictions["residual"].abs()
regression_predictions = regression_predictions.sort_values(
    "absolute_error", ascending=False
).reset_index(drop=True)

print(f"  done in {time.time() - start:.0f}s")


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

files = {
    "predictions_classification.csv": classification_predictions,
    "predictions_regression.csv": regression_predictions,
    "model_comparison_classification.csv": classification_comparison,
    "model_comparison_regression.csv": regression_comparison,
}

print()
for name, frame in files.items():
    path = output_dir / name
    frame.to_csv(path, index=False)
    print(f"Exported to: {path}  ({len(frame):,} rows, {frame.shape[1]} cols)")
