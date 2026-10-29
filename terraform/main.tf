terraform {
  required_version = ">= 1.6, < 2.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.36.0"
    }
  }
}

variable "kube_config" {
  type    = string
  default = "~/.kube/config"
}
variable "kube_context" {
  type    = string
  default = "kind-mini-mlops"
}
variable "image" {
  type    = string
  default = "mini-mlops:local"
}
variable "worker_replicas" {
  type    = number
  default = 1
}

provider "kubernetes" {
  config_path    = pathexpand(var.kube_config)
  config_context = var.kube_context
}

resource "kubernetes_namespace_v1" "demo" {
  metadata { name = "mini-mlops" }
}

locals {
  namespace = kubernetes_namespace_v1.demo.metadata[0].name
  app_env = {
    DATABASE_URL        = "postgresql+psycopg2://demo:demo@postgres:5432/demo"
    REDIS_URL           = "redis://redis:6379/0"
    MLFLOW_TRACKING_URI = "http://mlflow:5000"
  }
  services = {
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
      env     = { GF_SECURITY_ADMIN_USER = "admin", GF_SECURITY_ADMIN_PASSWORD = "demo-admin" }
      storage = null, memory = "256Mi", replicas = 1
    }
  }
  files = {
    prometheus = { "prometheus.yml" = file("${path.module}/../monitoring/prometheus.yml") }
    grafana = {
      "datasource.yml"         = file("${path.module}/../monitoring/datasource.yml")
      "dashboard-provider.yml" = file("${path.module}/../monitoring/dashboard-provider.yml")
      "dashboard.json"         = file("${path.module}/../monitoring/dashboard.json")
    }
  }
  mounts = {
    prometheus = { "prometheus.yml" = "/etc/prometheus/prometheus.yml" }
    grafana = {
      "datasource.yml"         = "/etc/grafana/provisioning/datasources/default.yml"
      "dashboard-provider.yml" = "/etc/grafana/provisioning/dashboards/default.yml"
      "dashboard.json"         = "/var/lib/grafana/dashboards/iris.json"
    }
  }
}

resource "kubernetes_config_map_v1" "monitoring" {
  for_each = local.files
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  data = each.value
}

resource "kubernetes_persistent_volume_claim_v1" "data" {
  for_each = toset(["postgres", "redis", "mlflow"])
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "1Gi" } }
  }
}

resource "kubernetes_deployment_v1" "service" {
  for_each = local.services
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  # Data services and pods can start in parallel. Kubernetes retries API startup
  # while PostgreSQL starts; scripts wait for readiness before training/smoke tests.
  wait_for_rollout = false
  spec {
    replicas = each.value.replicas
    selector { match_labels = { app = each.key } }
    strategy { type = "Recreate" }
    template {
      metadata {
        labels = { app = each.key }
        annotations = {
          config_hash = sha256(jsonencode(lookup(local.files, each.key, {})))
        }
      }
      spec {
        container {
          name              = each.key
          image             = each.value.image
          image_pull_policy = "IfNotPresent"
          command           = each.value.command
          dynamic "env" {
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "1000m", memory = each.value.memory }
          }
          dynamic "readiness_probe" {
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
            for_each = each.value.storage == null ? [] : [each.value.storage]
            content {
              name       = "data"
              mount_path = volume_mount.value
            }
          }
          dynamic "volume_mount" {
            for_each = lookup(local.mounts, each.key, {})
            content {
              name       = "config"
              mount_path = volume_mount.value
              sub_path   = volume_mount.key
              read_only  = true
            }
          }
        }
        dynamic "volume" {
          for_each = each.value.storage == null ? [] : [each.key]
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.data[each.key].metadata[0].name
            }
          }
        }
        dynamic "volume" {
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
  for_each = { for name, service in local.services : name => service if service.port != 0 }
  metadata {
    name      = each.key
    namespace = local.namespace
  }
  spec {
    selector = { app = each.key }
    port {
      port        = each.value.port
      target_port = each.value.port
    }
  }
}
