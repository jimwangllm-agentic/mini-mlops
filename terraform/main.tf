# Terraform describes the Kubernetes resources we want. It does not run Python.
# Read docs/BEGINNER-GUIDE.md before this file if Pods/Services are unfamiliar.
#
# HOW TO READ THIS FILE:
# The "Hi Kubernetes, please ..." comments translate the settings into plain English.
# Kubernetes does not read these comments. Terraform reads the real settings and
# its Kubernetes provider sends authenticated HTTPS requests to the API server.
# For example, creating a Deployment uses its /apis/apps/v1/.../deployments API.
# Terraform does not run kubectl for each resource or upload this .tf file to Kubernetes.
#
# From the project root, our deployment script runs:
#   terraform -chdir=terraform init -input=false
#     -> "Hi Terraform, prepare this folder and install the Kubernetes provider."
#   terraform -chdir=terraform apply -auto-approve -input=false
#     -> "Hi Terraform, compare the desired resources below with the existing ones,
#         then send the necessary create/update requests without an approval prompt."
# -chdir selects this folder; -input=false prevents questions for missing inputs.
#
# This configuration manages 19 Kubernetes objects at the default settings:
#   1 Namespace + 7 Deployments + 6 Services + 3 storage claims + 2 ConfigMaps.
# Kubernetes creates supporting ReplicaSets and Pods from those Deployments.
# The kind cluster and application image already exist before apply runs.
# The separate deploy.sh script builds/loads the image and creates a training Job.
# Resource references determine dependencies; this file is not executed line by line.
terraform {
  # Accept Terraform CLI 1.x versions with the features used by this project.
  required_version = ">= 1.6, < 2.0"
  required_providers {
    # A provider is a plugin that translates Terraform resources into API calls.
    # "Hi Terraform, install this exact plugin during init so you know how to
    # read and manage Kubernetes objects. This is not an application container."
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.36.0"
    }
  }
}

variable "kube_config" {
  # Connection details for Kubernetes; local setup may override this file path.
  # "Use this file to find the API server address and authentication/TLS settings."
  # demo-env.sh overrides the default with our workspace's prepared kubeconfig.
  type    = string
  default = "~/.kube/config"
}
variable "kube_context" {
  # Select the kind demo cluster rather than another cluster in the same config.
  # "Choose this named connection from the kubeconfig, so requests go to our demo."
  type    = string
  default = "kind-mini-mlops"
}
variable "image" {
  # The application image loaded into kind; CI supplies a commit-specific tag.
  # "Use this packaged image for API, Celery, and MLflow. Do not build it here."
  type    = string
  default = "mini-mlops:local"
}
variable "worker_replicas" {
  # Number of worker Pods. Each has Celery concurrency=1, so 2 Pods can run 2 jobs.
  # "Please maintain one worker Pod by default. If I set this to 2, maintain two."
  # A replica counts a copy of a Pod, not an extra container inside the same Pod.
  type    = number
  default = 1
}

provider "kubernetes" {
  # "Hi provider, connect to the Kubernetes API using this file and context.
  # Authenticate using its credentials, then send the resource requests below."
  # pathexpand turns '~' into the user's home directory when using the default.
  config_path    = pathexpand(var.kube_config)
  config_context = var.kube_context
}

resource "kubernetes_namespace_v1" "demo" {
  # A namespace groups all this demo's resources under the name mini-mlops.
  # "Hi Kubernetes, please create a Namespace named mini-mlops for this project."
  # The second resource string, "demo", is Terraform's internal label. The actual
  # Kubernetes object name comes from metadata.name below.
  metadata { name = "mini-mlops" }
}

# locals names values reused below. These declarations alone create no resources.
locals {
  # These are recipes/values used by the resource blocks later. Merely listing
  # postgres/api/worker here does not create any container or Kubernetes object.
  namespace = kubernetes_namespace_v1.demo.metadata[0].name
  app_env = {
    # Kubernetes Services provide these internal hostnames (postgres/redis/mlflow).
    # "Please give API and worker processes these connection settings. They can
    # reach other Pods through stable Service names, even if individual Pods change."
    DATABASE_URL        = "postgresql+psycopg2://demo:demo@postgres:5432/demo"
    REDIS_URL           = "redis://redis:6379/0"
    MLFLOW_TRACKING_URI = "http://mlflow:5000"
  }
  services = {
    # Each map entry becomes one Deployment. 'port=0' means no Service is needed.
    # image: packaged environment; command: startup process (null uses image CMD).
    # env: process configuration; storage: persistent mount path, or null for none.
    # memory: per-container memory limit; replicas: desired number of Pods.
    postgres = {
      # Recipe: "Please create a postgres Deployment maintaining 1 Pod using
      # postgres:16.8-alpine. Use the image's default database startup command,
      # listen on 5432, and mount persistent storage at /var/lib/postgresql/data."
      # The image initializes the demo user/database on fresh data; a replacement
      # Pod reuses the existing database through its storage claim.
      image   = "postgres:16.8-alpine", port = 5432, command = null
      env     = { POSTGRES_USER = "demo", POSTGRES_PASSWORD = "demo", POSTGRES_DB = "demo", PGDATA = "/var/lib/postgresql/data/pgdata" }
      storage = "/var/lib/postgresql/data", memory = "256Mi", replicas = 1
    }
    redis = {
      # Recipe: "Please create a redis Deployment maintaining 1 Pod using this
      # Redis image. Run redis-server --appendonly yes, listen on 6379, and keep
      # append-only persistence files in the mounted /data storage."
      image = "redis:7.4.2-alpine", port = 6379, command = ["redis-server", "--appendonly", "yes"]
      env   = {}, storage = "/data", memory = "128Mi", replicas = 1
    }
    mlflow = {
      # Recipe: "Please create an mlflow Deployment maintaining 1 Pod using the
      # application image. Run the mlflow server command on port 5000. Keep its
      # SQLite metadata database and model artifacts in persistent /mlflow storage."
      # --workers 1 is a server-process setting; replicas=1 is the number of Pods.
      image   = var.image, port = 5000
      command = ["mlflow", "server", "--host", "0.0.0.0", "--port", "5000", "--backend-store-uri", "sqlite:////mlflow/mlflow.db", "--serve-artifacts", "--artifacts-destination", "/mlflow/artifacts", "--workers", "1"]
      env     = {}, storage = "/mlflow", memory = "768Mi", replicas = 1
    }
    api = {
      # Recipe: "Please create an api Deployment maintaining 1 Pod using the
      # application image. Run its default Uvicorn/FastAPI command on port 8000,
      # pass the database/Redis/MLflow URLs, and cap container memory at 512 MiB."
      # command=null means use the image's CMD; it does not mean run nothing.
      # This Pod needs no persistent disk: saved prediction jobs live in PostgreSQL.
      image = var.image, port = 8000, command = null
      env   = local.app_env, storage = null, memory = "512Mi", replicas = 1
    }
    worker = {
      # Recipe: "Please create a worker Deployment using the application image.
      # Maintain worker_replicas Pods, each running the Celery command below with
      # concurrency=1. Give them the same DB/Redis/MLflow connection settings."
      # A worker consumes Redis messages; it does not provide an HTTP endpoint.
      # port=0 tells OUR Service filter below to skip a worker Service; it is not
      # an instruction to open network port zero or disable outgoing connections.
      image   = var.image, port = 0
      command = ["celery", "-A", "app.tasks:celery", "worker", "--loglevel=info", "--concurrency=1"]
      env     = local.app_env, storage = null, memory = "768Mi", replicas = var.worker_replicas
    }
    prometheus = {
      # Recipe: "Please create a prometheus Deployment maintaining 1 Pod from
      # this image. Use its default command, listen on 9090, and read the supplied
      # configuration file to scrape API metrics. No persistent disk is requested."
      image = "prom/prometheus:v3.3.0", port = 9090, command = null
      env   = {}, storage = null, memory = "256Mi", replicas = 1
    }
    grafana = {
      # Recipe: "Please create a grafana Deployment maintaining 1 Pod from this
      # image. Use its default server command on port 3000, initialize login as
      # admin/admin, and load our provisioned datasource/dashboard files."
      # No persistent disk is requested; provisioned files recreate the dashboard.
      image   = "grafana/grafana:11.6.1", port = 3000, command = null
      env     = { GF_SECURITY_ADMIN_USER = "admin", GF_SECURITY_ADMIN_PASSWORD = "admin" }
      storage = null, memory = "256Mi", replicas = 1
    }
  }
  files = {
    # Read existing monitoring files; ConfigMaps carry their contents into Pods.
    # "Read these text files from the repository so later ConfigMap requests can
    # send their contents to Kubernetes. file(...) reads a file; it does not run it."
    prometheus = { "prometheus.yml" = file("${path.module}/../monitoring/prometheus.yml") }
    grafana = {
      "datasource.yml"         = file("${path.module}/../monitoring/datasource.yml")
      "dashboard-provider.yml" = file("${path.module}/../monitoring/dashboard-provider.yml")
      "dashboard.json"         = file("${path.module}/../monitoring/dashboard.json")
    }
  }
  mounts = {
    # Map each configuration filename to the location expected inside its container.
    # "When creating a monitoring Pod, put each supplied file at this exact path
    # so Prometheus/Grafana can find it without rebuilding their images."
    prometheus = { "prometheus.yml" = "/etc/prometheus/prometheus.yml" }
    grafana = {
      "datasource.yml"         = "/etc/grafana/provisioning/datasources/default.yml"
      "dashboard-provider.yml" = "/etc/grafana/provisioning/dashboards/default.yml"
      "dashboard.json"         = "/var/lib/grafana/dashboards/iris.json"
    }
  }
}

resource "kubernetes_config_map_v1" "monitoring" {
  # for_each creates one ConfigMap per map entry: prometheus and grafana.
  # "Hi Kubernetes, please create a prometheus ConfigMap and a grafana ConfigMap
  # in mini-mlops. Store these filenames and their text contents in those objects."
  # Example iteration: each.key="grafana"; each.value is its map of three files.
  for_each = local.files
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  data = each.value # The filenames and text contents for this ConfigMap.
}

resource "kubernetes_persistent_volume_claim_v1" "data" {
  # Ask the cluster for separate persistent storage for each stateful service.
  # "Hi Kubernetes, please create three PersistentVolumeClaims named postgres,
  # redis, and mlflow in mini-mlops. Each requests 1 GiB of storage. Please let
  # replacement Pods reconnect to that storage instead of losing saved data."
  # The cluster's storage provisioner supplies volumes for these requests.
  for_each = toset(["postgres", "redis", "mlflow"])
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  # Allow Pod scheduling to trigger storage provisioning before waiting for a bind.
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"] # Read-write mount from one node at a time.
    resources { requests = { storage = "1Gi" } }
  }
}

resource "kubernetes_deployment_v1" "service" {
  # One Deployment for each service defined above. It maintains its requested Pods.
  # THIS IS WHERE THE SEVEN RECIPES BECOME KUBERNETES DEPLOYMENT REQUESTS.
  # "Hi Kubernetes, for every entry in local.services, please maintain a
  # Deployment with that name, image, replica count, command, and configuration."
  # The string "service" here is a Terraform label, not a Kubernetes Service.
  # Kubernetes Services are separate objects requested by the final resource block.
  #
  # Example loop iteration:
  #   each.key = "worker"
  #   each.value.image = var.image (mini-mlops:local by default)
  #   each.value.replicas = var.worker_replicas (1 by default)
  #   each.value.command = the Celery worker command from the recipe above
  #
  # Kubernetes receives the Deployment object through the provider's API calls.
  # Its Deployment controller creates a ReplicaSet; the ReplicaSet controller
  # creates Pods; the scheduler assigns Pods to a node; kubelet/containerd starts
  # their containers. Terraform does not manually execute each of those steps.
  for_each = local.services
  metadata {
    # "Name this Deployment after the map key (for example worker) and put it
    # in the mini-mlops Namespace created above."
    name      = each.key
    namespace = local.namespace
  }
  # Data services and pods can start in parallel. Kubernetes retries API startup
  # while PostgreSQL starts; scripts wait for readiness before training/smoke tests.
  wait_for_rollout = false
  # "Terraform may return after the resource is created/updated. Do not wait here
  # for every Pod to become ready; deploy.sh waits using kubectl rollout status."
  spec {
    # selector matches the labels on this Deployment's Pods.
    replicas = each.value.replicas
    # "This Deployment manages Pods with app=<this service name>."
    selector { match_labels = { app = each.key } }
    # Stop old Pods before replacing them; small demo, not a zero-downtime rollout.
    strategy { type = "Recreate" }
    template {
      # "Use this template when Kubernetes creates a new Pod for the Deployment."
      # The Deployment is the long-lived manager; a Pod is a replaceable instance.
      metadata {
        labels = { app = each.key }
        # "Label each worker Pod app=worker (or api Pod app=api), so the manager
        # and network Services can find the appropriate Pods."
        annotations = {
          # A configuration content change changes this hash, replacing the Pods
          # so their mounted configuration files are read again at startup.
          config_hash = sha256(jsonencode(lookup(local.files, each.key, {})))
        }
      }
      spec {
        container {
          # "Inside each Pod, please start ONE container with these settings."
          name              = each.key
          image             = each.value.image
          image_pull_policy = "IfNotPresent" # Prefer the image already loaded into kind.
          # "Use the image available on the node; pull it if missing. kind load
          # already supplied our local application image before Terraform ran."
          command = each.value.command
          dynamic "env" {
            # dynamic emits repeated env blocks, one for each key/value in the map.
            # "Add each environment variable to the process. For API, turn the
            # three app_env entries into three env settings in its Pod template."
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }
          resources {
            # requests guide scheduling; limits cap usage. 1000m CPU means one core.
            # Exceeding memory can terminate the container; exceeding CPU is throttled.
            # "Schedule where capacity is available for 0.05 CPU cores and 64 MiB
            # per container. Cap CPU at one core and memory at the recipe's limit."
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "1000m", memory = each.value.memory }
          }
          dynamic "readiness_probe" {
            # Only API/MLflow get HTTP readiness checks in this small demo.
            # Kubernetes routes Service traffic to ready Pods.
            # "For api and mlflow, GET /health on the configured port, starting
            # after 5 seconds and repeating every 5 seconds. Mark the Pod unready
            # if it fails. A readiness failure alone does not restart a container."
            for_each = contains(["api", "mlflow"], each.key) ? [1] : []
            content {
              http_get {
                path = "/health"
                port = each.value.port
              }
              initial_delay_seconds = 5
              period_seconds        = 5
            }
          }
          dynamic "volume_mount" {
            # If storage is configured, mount its persistent volume into the container.
            # "For postgres, redis, and mlflow, make their saved data visible at
            # the recipe's storage path. For API/worker, emit no data mount."
            for_each = each.value.storage == null ? [] : [each.value.storage]
            content {
              name       = "data"
              mount_path = volume_mount.value
            }
          }
          dynamic "volume_mount" {
            # Mount ConfigMap files at their expected container paths.
            # "For monitoring containers, expose each configuration file at its
            # mapped path, read-only. Other service recipes have no such mounts."
            for_each = lookup(local.mounts, each.key, {})
            content {
              name       = "config"
              mount_path = volume_mount.value
              sub_path   = volume_mount.key # Select one file from the volume.
              read_only  = true
            }
          }
        }
        dynamic "volume" {
          # A Pod volume refers to storage; volume_mount above places it in a container.
          # "Connect this Pod's data volume to the storage claim with the same
          # service name. This reference makes the claim a Terraform dependency."
          for_each = each.value.storage == null ? [] : [each.key]
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.data[each.key].metadata[0].name
            }
          }
        }
        dynamic "volume" {
          # Monitoring Pods also receive a volume populated from their ConfigMap.
          # "Populate the monitoring Pod's config volume from its ConfigMap."
          for_each = contains(keys(local.files), each.key) ? [each.key] : []
          content {
            name = "config"
            config_map { name = kubernetes_config_map_v1.monitoring[each.key].metadata[0].name }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "service" {
  # A Service gives Pods a stable internal hostname/IP. Worker has no HTTP port.
  # "Hi Kubernetes, please create six internal network Services: postgres, redis,
  # mlflow, api, prometheus, and grafana. Keep these addresses stable when Pods
  # are replaced. Skip worker because its recipe has port=0."
  # These are ClusterIP Services by default: they do not publish Windows ports.
  # kubectl port-forward later makes them reachable through the laptop's localhost.
  for_each = { for name, service in local.services : name => service if service.port != 0 }
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  spec {
    # Send traffic to Pods whose app label matches this service name.
    selector = { app = each.key }
    # Example: "Send api:8000 traffic to ready Pods labeled app=api, on port 8000."
    port {
      port        = each.value.port
      target_port = each.value.port # The destination port inside the selected Pod.
    }
  }
}
