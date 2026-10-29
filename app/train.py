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
    x, y = load_iris(return_X_y=True)
    x_train, x_test, y_train, y_test = train_test_split(
        x, y, test_size=0.2, random_state=42, stratify=y
    )
    model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=200, random_state=42))
    mlflow.set_experiment("iris-demo")
    with mlflow.start_run():
        model.fit(x_train, y_train)
        accuracy = accuracy_score(y_test, model.predict(x_test))
        mlflow.log_params({"max_iter": 200, "random_state": 42, "test_size": 0.2})
        mlflow.log_metric("accuracy", accuracy)
        info = mlflow.sklearn.log_model(
            model, "model", signature=infer_signature(x_train, model.predict(x_train)),
            input_example=x_train[:1],
        )
        version = mlflow.register_model(info.model_uri, "iris", await_registration_for=60)
        MlflowClient().set_registered_model_alias("iris", "champion", version.version)
        print(f"Registered iris version={version.version}, alias=champion, accuracy={accuracy:.3f}")


if __name__ == "__main__":
    main()
