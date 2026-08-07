"""
Inference for the YHP credit-risk models.

Given a loan_id, pulls that loan's feature vector, runs it through both models,
and returns the probability of default and the predicted dollar loss.

    from inference import predict
    predict("LRQ-267780")

    {'loan_id': 'LRQ-267780',
     'probability_of_default': 0.9989,
     'predicted_loss_given_default': 24880.11,
     'expected_loss_usd': 24853.75,
     ...}

Two entry points:

    build_artifacts()   fits both models and writes them to modelling/artifacts/.
                        Run once, or after retraining. Takes about 5 seconds.

    predict(loan_id)    loads the saved artefacts and scores one loan.
                        Millisecond latency after the first call.

Command line:

    python inference.py --build
    python inference.py LRQ-267780
    python inference.py LRQ-267780 LRQ-233460 --json

Design notes
------------
Nothing is re-fitted at prediction time. The encoder, imputer, scaler and both
models are fitted once during build_artifacts() on the training rows only, then
serialised together. Re-fitting any of them against a new batch would change the
medians and scaling factors and silently shift every prediction.

Logistic Regression supplies the probability rather than the SVM, which scored
marginally higher on ROC-AUC (0.6112 against 0.6104, a difference well inside
noise). The SVM's decision_function returns a signed distance, not a calibrated
probability, and this function is contracted to return a probability. See
ml_methodology.md, decision 7.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import duckdb
import joblib
import numpy as np
import pandas as pd

from sklearn.base import BaseEstimator, TransformerMixin
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.linear_model import LogisticRegression, Ridge

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATABASE_PATH = PROJECT_ROOT / "credit_dbt" / "credit.duckdb"
ARTIFACT_PATH = PROJECT_ROOT / "modelling" / "artifacts" / "credit_models.joblib"

# Chosen in the notebooks. Recorded here so the artefact build is reproducible
# without re-running a parameter sweep.
DEFAULT_PROBABILITY_C = 1.0
DEFAULT_SEVERITY_ALPHA = 100.0
RARE_CATEGORY_MIN_COUNT = 20
RANDOM_STATE = 42


class LoanNotFound(KeyError):
    """Raised when a loan_id is not present in the warehouse."""


class ArtifactsMissing(FileNotFoundError):
    """Raised when predict() is called before build_artifacts()."""


class RareCategoryGrouper(BaseEstimator, TransformerMixin):
    """
    Replace infrequent categories with a single RARE label.

    Defined at module level, not inside a function, because joblib needs to
    import this class by name when the pipeline is loaded back.
    """

    def __init__(self, min_count: int = RARE_CATEGORY_MIN_COUNT):
        self.min_count = min_count

    def fit(self, X, y=None):
        self.keep_ = {
            column: set(
                X[column].astype(str).value_counts().pipe(
                    lambda counts: counts[counts >= self.min_count]
                ).index
            )
            for column in X.columns
        }
        return self

    def transform(self, X):
        X = X.copy()
        for column in X.columns:
            values = X[column].astype(str)
            X[column] = values.where(values.isin(self.keep_[column]), "RARE")
        return X


@dataclass
class CreditModels:
    """Everything needed to score a loan, fitted once and serialised together."""

    probability_pipeline: Pipeline
    probability_features: list[str]
    severity_pipeline: Pipeline
    severity_features: list[str]
    # (min, max) of log1p(loss_amount) over the severity training rows.
    # Predictions are clipped to this range -- see predict().
    severity_log_range: tuple[float, float]
    training_cutoff: str
    metadata: dict


def _read(table: str) -> pd.DataFrame:
    """Read a mart, casting boolean features to int as the notebooks do."""
    if not DATABASE_PATH.exists():
        raise FileNotFoundError(
            f"Database not found at {DATABASE_PATH}. Run `dbt build` first."
        )
    with duckdb.connect(str(DATABASE_PATH), read_only=True) as connection:
        frame = connection.execute(f"select * from {table}").df()

    bool_features = [
        c for c in frame.select_dtypes(include=["bool"]).columns if c != "is_loss"
    ]
    frame[bool_features] = frame[bool_features].astype(int)
    return frame


def _split_columns(frame: pd.DataFrame, exclude: list[str]) -> tuple[list[str], list[str]]:
    """Return (categorical, numeric) feature columns, asserting nothing falls through."""
    features = frame.drop(columns=exclude)
    categorical = features.select_dtypes(include=["object", "category"]).columns.tolist()
    numeric = features.select_dtypes(include=[np.number]).columns.tolist()

    missed = set(features.columns) - set(categorical) - set(numeric)
    if missed:
        raise ValueError(f"columns matched neither selector: {sorted(missed)}")
    return categorical, numeric


def build_artifacts(output_path: Path = ARTIFACT_PATH) -> Path:
    """
    Fit both models on their training rows and serialise them.

    Every fitted object -- encoder, imputer, scaler, and the two estimators --
    is stored inside the pipelines, so prediction applies exactly the transforms
    that training saw.
    """
    print("Building artefacts")

    # --- probability of default ------------------------------------------
    classifier_frame = _read("mart_ml_training_set")
    classifier_exclude = ["loan_id", "split", "received_date", "is_loss"]
    cat_cols, num_cols = _split_columns(classifier_frame, classifier_exclude)

    train = classifier_frame["split"] == "train"
    X_train = classifier_frame.loc[train, cat_cols + num_cols]
    y_train = classifier_frame.loc[train, "is_loss"].astype(int)

    probability_pipeline = Pipeline([
        ("preprocess", ColumnTransformer([
            ("categorical", Pipeline([
                ("impute", SimpleImputer(strategy="constant", fill_value="MISSING")),
                ("encode", OneHotEncoder(handle_unknown="ignore", sparse_output=False)),
            ]), cat_cols),
            ("numeric", Pipeline([
                ("impute", SimpleImputer(strategy="median")),
                ("scale", StandardScaler()),
            ]), num_cols),
        ])),
        ("model", LogisticRegression(
            C=DEFAULT_PROBABILITY_C, max_iter=2000,
            class_weight="balanced", random_state=RANDOM_STATE,
        )),
    ])
    probability_pipeline.fit(X_train, y_train)
    print(f"  probability model fitted on {len(X_train):,} loans")

    # --- severity ---------------------------------------------------------
    severity_frame = _read("mart_ml_severity_set")
    severity_exclude = ["loan_id", "split", "received_date", "is_loss", "loss_amount"]
    scat_cols, snum_cols = _split_columns(severity_frame, severity_exclude)

    strain = severity_frame["split"] == "train"
    SX_train = severity_frame.loc[strain, scat_cols + snum_cols]
    sy_train = severity_frame.loc[strain, "loss_amount"]

    severity_pipeline = Pipeline([
        ("preprocess", ColumnTransformer([
            ("categorical", Pipeline([
                ("group_rare", RareCategoryGrouper(min_count=RARE_CATEGORY_MIN_COUNT)),
                ("impute", SimpleImputer(strategy="constant", fill_value="MISSING")),
                ("encode", OneHotEncoder(handle_unknown="ignore", sparse_output=False)),
            ]), scat_cols),
            ("numeric", Pipeline([
                ("impute", SimpleImputer(strategy="median")),
                ("scale", StandardScaler()),
            ]), snum_cols),
        ])),
        ("model", Ridge(alpha=DEFAULT_SEVERITY_ALPHA, max_iter=10000)),
    ])
    # Fitted on log1p; predict() reverses the transform.
    severity_pipeline.fit(SX_train, np.log1p(sy_train))
    print(f"  severity model fitted on {len(SX_train):,} loss-making loans")

    severity_log_range = (
        float(np.log1p(sy_train).min()),
        float(np.log1p(sy_train).max()),
    )

    artifacts = CreditModels(
        probability_pipeline=probability_pipeline,
        probability_features=cat_cols + num_cols,
        severity_pipeline=severity_pipeline,
        severity_features=scat_cols + snum_cols,
        severity_log_range=severity_log_range,
        training_cutoff="2024-10-01",
        metadata={
            "probability_model": f"LogisticRegression(C={DEFAULT_PROBABILITY_C}, class_weight=balanced)",
            "severity_model": f"Ridge(alpha={DEFAULT_SEVERITY_ALPHA}) on log1p(loss_amount)",
            "probability_training_loans": int(len(X_train)),
            "severity_training_loans": int(len(SX_train)),
            "currency": "USD",
        },
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(artifacts, output_path)
    print(f"Saved to: {output_path}")
    return output_path


@lru_cache(maxsize=1)
def _load(artifact_path: str = str(ARTIFACT_PATH)) -> CreditModels:
    """Load artefacts once and keep them in memory for subsequent calls."""
    path = Path(artifact_path)
    if not path.exists():
        raise ArtifactsMissing(
            f"No artefacts at {path}. Run `python inference.py --build` first."
        )
    return joblib.load(path)


@lru_cache(maxsize=1)
def _feature_store() -> tuple[pd.DataFrame, pd.DataFrame]:
    """Load both feature tables once. Indexed by loan_id for constant-time lookup."""
    classifier = _read("mart_ml_training_set").set_index("loan_id")
    severity = _read("mart_ml_severity_set").set_index("loan_id")
    return classifier, severity


def predict(loan_id: str) -> dict:
    """
    Score one loan.

    Parameters
    ----------
    loan_id : str
        Loan identifier, for example "LRQ-267780".

    Returns
    -------
    dict with keys:
        loan_id                      the identifier requested
        probability_of_default       P(is_loss), between 0 and 1
        predicted_loss_given_default predicted USD loss if the loan does default
        expected_loss_usd            probability x predicted_loss_given_default
        received_date                origination date, as YYYY-MM-DD
        data_split                   'train' or 'test'
        scored_on_training_data      True if this loan was used to fit the models

    Raises
    ------
    LoanNotFound      if the loan_id is not in the warehouse
    ArtifactsMissing  if build_artifacts() has not been run
    """
    models = _load()
    classifier_store, severity_store = _feature_store()

    if loan_id not in classifier_store.index:
        raise LoanNotFound(
            f"loan_id {loan_id!r} is not in the warehouse. "
            f"Expected a value like 'LRQ-267780'."
        )

    row = classifier_store.loc[[loan_id]]

    probability = float(
        models.probability_pipeline.predict_proba(row[models.probability_features])[0, 1]
    )

    # The severity model is trained only on loans that lost money, so it answers
    # "how much, given a loss". Its feature vector comes from the severity mart
    # where the loan is present; otherwise the classifier mart supplies the same
    # columns, since the two differ only in feat_001 grouping and the target.
    if loan_id in severity_store.index:
        severity_row = severity_store.loc[[loan_id]]
    else:
        severity_row = row.rename(columns={"feat_001_grouped": "feat_001"})

    severity_input = severity_row.reindex(columns=models.severity_features)
    severity_log = float(models.severity_pipeline.predict(severity_input)[0])

    # Bound the prediction to the range of losses the model was actually fitted
    # on. Ridge is linear, so a feature far outside the training range
    # extrapolates without limit: one test loan carries feat_010 = 255,428
    # against a severity-training mean of 1,403, which is 120 standard
    # deviations out and produced a predicted loss of $86 billion before this
    # clip existed. The model has no basis for an answer there, and a clamped
    # figure flagged as such is more use than a confident absurdity.
    low, high = models.severity_log_range
    was_clipped = not (low <= severity_log <= high)
    loss_given_default = float(np.expm1(np.clip(severity_log, low, high)))

    received_date = row["received_date"].iloc[0]
    data_split = str(row["split"].iloc[0])

    return {
        "loan_id": loan_id,
        "probability_of_default": round(probability, 6),
        "predicted_loss_given_default": round(loss_given_default, 2),
        "expected_loss_usd": round(probability * loss_given_default, 2),
        "received_date": str(pd.Timestamp(received_date).date()),
        "data_split": data_split,
        "scored_on_training_data": data_split == "train",
        # The severity model is fitted only on loans that lost money. For any
        # other loan it answers a counterfactual -- "how much would this have
        # lost, had it lost" -- outside the population it was trained on.
        "severity_in_population": loan_id in severity_store.index,
        "severity_clipped": bool(was_clipped),
    }


def predict_many(loan_ids) -> pd.DataFrame:
    """Score several loans and return one row each."""
    return pd.DataFrame([predict(loan_id) for loan_id in loan_ids])


def _main() -> None:
    parser = argparse.ArgumentParser(description="Score loans for default risk and dollar loss.")
    parser.add_argument("loan_ids", nargs="*", help="one or more loan_id values")
    parser.add_argument("--build", action="store_true", help="fit and save the models, then exit")
    parser.add_argument("--json", action="store_true", help="print JSON instead of a table")
    args = parser.parse_args()

    if args.build:
        build_artifacts()
        return

    if not args.loan_ids:
        parser.error("give at least one loan_id, or use --build")

    results = [predict(loan_id) for loan_id in args.loan_ids]

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        frame = pd.DataFrame(results)
        pd.set_option("display.width", 200)
        print(frame.to_string(index=False))


if __name__ == "__main__":
    # Re-import under the module's real name before doing anything.
    #
    # Running this file directly puts its classes in the __main__ namespace, so
    # joblib pickles them as __main__.CreditModels. Loading the artefact from
    # `import inference` then fails with AttributeError, because that name does
    # not exist there. Delegating to the imported module means the classes are
    # always pickled and unpickled as inference.CreditModels, whichever way the
    # code was entered.
    import inference

    inference._main()
