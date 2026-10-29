"""One-off training program: train -> evaluate -> log -> register -> promote.

Run with `python -m app.train`. Compose or a Kubernetes Job runs this program
before the demo submits predictions. Inference happens separately in tasks.py.
"""

import mlflow
import mlflow.sklearn
from mlflow import MlflowClient
from mlflow.models import infer_signature
from sklearn.datasets import load_iris
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler


def main():
    """Train an Iris classifier and publish it as MLflow's champion model.

    Uses sklearn's bundled dataset, so no external dataset is needed. Logs
    parameters, test accuracy, and a reloadable model, then registers a version.
    """
    # 1. X contains four measurements per flower; y contains its known species.
    # Reserve 20% for evaluation. stratify preserves each species' proportion.
    x, y = load_iris(return_X_y=True)
    x_train, x_test, y_train, y_test = train_test_split(
        x, y, test_size=0.2, random_state=42, stratify=y
    )
    # 2. Bundle preprocessing and prediction so inference applies the same scaler.
    # Fitting only on training samples avoids leaking the held-out test data.
    model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=200, random_state=42))
    mlflow.set_experiment("iris-demo")
    with mlflow.start_run():
        # 3. Learn from training data; measure accuracy on unseen test samples.
        model.fit(x_train, y_train)
        accuracy = accuracy_score(y_test, model.predict(x_test))
        # 4. Save the settings and score so runs can be compared in MLflow's UI.
        mlflow.log_params({"max_iter": 200, "random_state": 42, "test_size": 0.2})
        mlflow.log_metric("accuracy", accuracy)
        # 5. Store the fitted model artifact and its expected input/output schema.
        info = mlflow.sklearn.log_model(
            model, "model", signature=infer_signature(x_train, model.predict(x_train)),
            input_example=x_train[:1],
        )
        # 6. Create an immutable version, then point the movable champion alias
        # at it. Workers resolve this alias when processing new prediction jobs.
        version = mlflow.register_model(info.model_uri, "iris", await_registration_for=60)
        MlflowClient().set_registered_model_alias("iris", "champion", version.version)
        print(f"Registered iris version={version.version}, alias=champion, accuracy={accuracy:.3f}")


if __name__ == "__main__":
    main()
