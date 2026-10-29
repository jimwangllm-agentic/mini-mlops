# Cloud equivalents for the interview

These are functional mappings rather than guaranteed drop-in replacements.

| Local technology | Role | AWS | Azure | GCP |
|---|---|---|---|---|
| FastAPI | REST API and input validation | API Gateway + Lambda + Pydantic | API Management + Functions + Pydantic | API Gateway + Cloud Run + Pydantic |
| PostgreSQL | Persistent data and job status | RDS for PostgreSQL | Azure Database for PostgreSQL | Cloud SQL for PostgreSQL |
| Redis + Celery | Asynchronous jobs | SQS + workers | Service Bus + workers | Cloud Tasks + workers |
| MLflow | Experiment tracking and model management | SageMaker AI managed MLflow | Azure Machine Learning tracking + model registry | Vertex AI Experiments + Model Registry |
| Docker | Container image building and storage | CodeBuild + ECR | ACR Tasks + Azure Container Registry | Cloud Build + Artifact Registry |
| Kubernetes | Container orchestration and scaling | EKS | AKS | GKE |
| Terraform | Infrastructure provisioning | CloudFormation | Bicep + Azure Resource Manager | Infrastructure Manager |
| GitHub Actions | Automated testing and deployment | CodeBuild + CodePipeline | Azure Pipelines | Cloud Build + Cloud Deploy |
| Prometheus + Grafana | Monitoring and dashboards | Amazon Managed Service for Prometheus + Amazon Managed Grafana | Azure Monitor managed service for Prometheus + Azure Managed Grafana | Managed Service for Prometheus + Cloud Monitoring dashboards |

## Details to explain accurately

- API Gateway/API Management handle API exposure and policies. Compute executes Python; Pydantic validates application inputs. These platforms do not automatically supply FastAPI's application logic. Lambda/Functions adapters or rewritten handlers may be needed.
- A worker is your running application code. It consumes a queued job, loads input/model, computes the result, and persists it. On AWS it might be an ECS/Fargate task; on Azure a Container Apps replica; Cloud Tasks typically dispatches HTTP requests to a handler such as Cloud Run.
- SQS/Service Bus/Cloud Tasks are queues or task delivery services, not ML inference engines. Migrating from Celery to native handlers can require changes to message formats, retries, authentication, and acknowledgements.
- CodeBuild/ACR Tasks/Cloud Build build images; ECR/ACR/Artifact Registry store them. Container runtime and orchestration are separate roles.
- Infrastructure Manager executes Terraform configurations. It is not a separate Terraform replacement language. CloudFormation and Bicep are provider-specific declarative alternatives.
- GCP's Cloud Monitoring dashboards are a functional dashboard alternative, not managed Grafana. Grafana can also connect to GCP metrics.
- Cloud-native services reduce infrastructure administration but add cost, permissions, quotas, and provider-specific configuration. This repository deploys locally only.

## Queue stack discussion

| Environment | Example stack | Why |
|---|---|---|
| Open source, minimal Python jobs | FastAPI → Redis → Celery workers | Small setup, Python integration, good local demo |
| Open source, dedicated broker | FastAPI → RabbitMQ → Celery workers | Messaging/routing features and durable queue options |
| AWS | API → SQS → workers on ECS/Fargate | Managed buffering and independent worker scaling |
| Azure | API → Service Bus → workers on Container Apps | Managed durable messages and queue-driven worker scaling |

There is no verified universal popularity ranking. Kafka is primarily a replayable event stream platform; this project needs a work queue. Scale based on queue depth, oldest message age, per-job processing time, and worker utilization. Design for duplicates, bounded retries, dead-letter handling, and backpressure.

## Primary references

- [SageMaker AI managed MLflow](https://docs.aws.amazon.com/sagemaker/latest/dg/mlflow.html)
- [Azure Machine Learning MLflow integration](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-use-mlflow-configure-tracking?view=azureml-api-2)
- [GCP experiment tracking](https://cloud.google.com/vertex-ai/docs/experiments/intro-vertex-ai-experiments)
- [Infrastructure Manager](https://docs.cloud.google.com/infrastructure-manager/docs/overview)
- [SQS Standard queues](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues.html)
- [Azure Service Bus queues and subscriptions](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-queues-topics-subscriptions)
- [Service Bus duplicate handling](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-message-loss-and-duplicates)
- [Cloud Tasks overview](https://cloud.google.com/tasks/docs/dual-overview)
- [Celery broker comparison](https://docs.celeryq.dev/en/stable/getting-started/backends-and-brokers/)
- [Amazon Managed Service for Prometheus](https://aws.amazon.com/prometheus/), [Amazon Managed Grafana](https://aws.amazon.com/grafana/)
- [Azure managed Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-metrics-overview)
- [Cloud Deploy](https://cloud.google.com/deploy)
