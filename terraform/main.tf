# Terraform describes the Kubernetes resources we want. It does not run Python.
# Read docs/BEGINNER-GUIDE.md before this file if Pods/Services are unfamiliar.
terraform {
  # Accept Terraform CLI 1.x versions with the features used by this project.
  required_version = ">= 1.6, < 2.0"
  required_providers {
    # A provider is a plugin that translates Terraform resources into API calls.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.36.0"
    }
  }
}

variable "kube_config" {
  # Connection details for Kubernetes; local setup may override this file path.
  type    = string
  default = "~/.kube/config"
}
variable "kube_context" {
  # Select the kind demo cluster rather than another cluster in the same config.
  type    = string
  default = "kind-mini-mlops"
}
variable "image" {
  # The application image loaded into kind; CI supplies a commit-specific tag.
  type    = string
  default = "mini-mlops:local"
}
variable "worker_replicas" {
  # Number of worker Pods. Each has Celery concurrency=1, so 2 Pods can run 2 jobs.
  type    = number
  default = 1
}

provider "kubernetes" {
  # pathexpand turns '~' into the user's home directory when using the default.
  config_path    = pathexpand(var.kube_config)
  config_context = var.kube_context
}

resource "kubernetes_namespace_v1" "demo" {
  # A namespace groups all this demo's resources under the name mini-mlops.
  metadata { name = "mini-mlops" }
}

# locals names values reused below. These declarations alone create no resources.
locals {
  namespace = kubernetes_namespace_v1.demo.metadata[0].name
  app_env = {
    # Kubernetes Services provide these internal hostnames (postgres/redis/mlflow).
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
      image   = "postgres:16.8-alpine", port = 5432, command = null
      env     = { POSTGRES_USER = "demo", POSTGRES_PASSWORD = "demo", POSTGRES_DB = "demo", PGDATA = "/var/lib/postgresql/data/pgdata" }
      storage = "/var/lib/postgresql/data", memory = "256Mi", replicas = 1
    }
    redis = {
      image = "redis:7.4.2-alpine", port = 6379, command = ["redis-server", "--appendonly", "yes"]
      env   = {}, storage = "/data", memory = "128Mi", replicas = 1
    }
    mlflow = {
      image   = var.image, port = 5000
      command = ["mlflow", "server", "--host", "0.0.0.0", "--port", "5000", "--backend-store-uri", "sqlite:////mlflow/mlflow.db", "--serve-artifacts", "--artifacts-destination", "/mlflow/artifacts", "--workers", "1"]
      env     = {}, storage = "/mlflow", memory = "768Mi", replicas = 1
    }
    api = {
      image = var.image, port = 8000, command = null
      env   = local.app_env, storage = null, memory = "512Mi", replicas = 1
    }
    worker = {
      image   = var.image, port = 0
      command = ["celery", "-A", "app.tasks:celery", "worker", "--loglevel=info", "--concurrency=1"]
      env     = local.app_env, storage = null, memory = "768Mi", replicas = var.worker_replicas
    }
    prometheus = {
      image = "prom/prometheus:v3.3.0", port = 9090, command = null
      env   = {}, storage = null, memory = "256Mi", replicas = 1
    }
    grafana = {
      image   = "grafana/grafana:11.6.1", port = 3000, command = null
      env     = { GF_SECURITY_ADMIN_USER = "admin", GF_SECURITY_ADMIN_PASSWORD = "admin" }
      storage = null, memory = "256Mi", replicas = 1
    }
  }
  files = {
    # Read existing monitoring files; ConfigMaps carry their contents into Pods.
    prometheus = { "prometheus.yml" = file("${path.module}/../monitoring/prometheus.yml") }
    grafana = {
      "datasource.yml"         = file("${path.module}/../monitoring/datasource.yml")
      "dashboard-provider.yml" = file("${path.module}/../monitoring/dashboard-provider.yml")
      "dashboard.json"         = file("${path.module}/../monitoring/dashboard.json")
    }
  }
  mounts = {
    # Map each configuration filename to the location expected inside its container.
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
  for_each = local.files
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  data = each.value # The filenames and text contents for this ConfigMap.
}

resource "kubernetes_persistent_volume_claim_v1" "data" {
  # Ask the cluster for separate persistent storage for each stateful service.
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
  for_each = local.services
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  # Data services and pods can start in parallel. Kubernetes retries API startup
  # while PostgreSQL starts; scripts wait for readiness before training/smoke tests.
  wait_for_rollout = false
  spec {
    # selector matches the labels on this Deployment's Pods.
    replicas = each.value.replicas
    selector { match_labels = { app = each.key } }
    # Stop old Pods before replacing them; small demo, not a zero-downtime rollout.
    strategy { type = "Recreate" }
    template {
      metadata {
        labels = { app = each.key }
        annotations = {
          # A configuration content change changes this hash, replacing the Pods
          # so their mounted configuration files are read again at startup.
          config_hash = sha256(jsonencode(lookup(local.files, each.key, {})))
        }
      }
      spec {
        container {
          name              = each.key
          image             = each.value.image
          image_pull_policy = "IfNotPresent" # Prefer the image already loaded into kind.
          command           = each.value.command
          dynamic "env" {
            # dynamic emits repeated env blocks, one for each key/value in the map.
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }
          resources {
            # requests guide scheduling; limits cap usage. 1000m CPU means one core.
            # Exceeding memory can terminate the container; exceeding CPU is throttled.
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "1000m", memory = each.value.memory }
          }
          dynamic "readiness_probe" {
            # Only API/MLflow get HTTP readiness checks in this small demo.
            # Kubernetes routes Service traffic to ready Pods.
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
            for_each = each.value.storage == null ? [] : [each.value.storage]
            content {
              name       = "data"
              mount_path = volume_mount.value
            }
          }
          dynamic "volume_mount" {
            # Mount ConfigMap files at their expected container paths.
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
  for_each = { for name, service in local.services : name => service if service.port != 0 }
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  spec {
    # Send traffic to Pods whose app label matches this service name.
    selector = { app = each.key }
    port {
      port        = each.value.port
      target_port = each.value.port # The destination port inside the selected Pod.
    }
  }
}
