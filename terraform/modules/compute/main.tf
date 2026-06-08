# ── Módulo: COMPUTE ───────────────────────────────────────────────
# Cloud Run para el monolito OMS + HTTPS Load Balancer + Cloud CDN.
# Cloud Run es stateless: NFR-SCAL-001 (autoescalado horizontal hasta 5×).

variable "project_id"              { type = string }
variable "region"                  { type = string }
variable "env"                     { type = string }
variable "image_repo"              { type = string }
variable "image_sha"               { type = string }
variable "cloud_run_min_instances" { type = number }
variable "cloud_run_max_instances" { type = number }
variable "db_connection_name"      { type = string }
variable "db_secret_id"            { type = string }
variable "redis_host"              { type = string }
variable "labels"                  { type = map(string) }

# ─── Service Account dedicada al runtime ──────────────────────────
resource "google_service_account" "cloud_run" {
  account_id   = "oms-${var.env}-runtime"
  display_name = "OMS ${var.env} — Cloud Run runtime SA"
  description  = "Identidad del servicio Cloud Run. Bindings mínimos en módulo iam."
}

# ─── Cloud Run service ────────────────────────────────────────────
# Despliega la imagen referenciada por DIGEST (image_sha) — nunca por tag mutable.
resource "google_cloud_run_v2_service" "oms" {
  name     = "oms-${var.env}"
  location = var.region

  template {
    service_account = google_service_account.cloud_run.email

    scaling {
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances
    }

    # Cloud SQL connection via socket (no necesita IP pública)
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.db_connection_name]
      }
    }

    containers {
      # Imagen por DIGEST inmutable: garantía de que prod === staging
      image = "${var.image_repo}@${var.image_sha}"

      resources {
        limits = {
          cpu    = "1000m"
          memory = "2Gi"
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "ENV"
        value = var.env
      }
      env {
        name  = "DB_INSTANCE"
        value = var.db_connection_name
      }
      env {
        name  = "REDIS_HOST"
        value = var.redis_host
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = var.db_secret_id
            version = "latest"
          }
        }
      }

      # TODO(alumno): añade startup_probe y liveness_probe contra /healthz
      # (la spec del Vídeo 1 los pide).

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }

    # VPC connector para alcanzar Memorystore (red privada)
    # TODO(alumno): crea un vpc_access connector y referéncialo aquí.
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = var.labels

  lifecycle {
    ignore_changes = [
      # El image_sha lo controla el pipeline de despliegue, no terraform apply diario.
      # Si lo dejas sin ignore_changes, cada apply puede revertir un deploy reciente.
      template[0].containers[0].image,
    ]
  }
}

# ─── HTTPS Load Balancer + Cloud CDN ──────────────────────────────
# Estructura: serverless NEG → Backend Service → URL map → HTTPS proxy → Forwarding rule

resource "google_compute_region_network_endpoint_group" "cloud_run_neg" {
  name                  = "oms-${var.env}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.oms.name
  }
}

resource "google_compute_backend_service" "default" {
  name                  = "oms-${var.env}-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  enable_cdn            = true

  backend {
    group = google_compute_region_network_endpoint_group.cloud_run_neg.id
  }

  cdn_policy {
    cache_mode                   = "CACHE_ALL_STATIC"
    default_ttl                  = 3600
    max_ttl                      = 86400
    negative_caching             = true
    serve_while_stale            = 86400
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "default" {
  name            = "oms-${var.env}-url-map"
  default_service = google_compute_backend_service.default.id
}

# TODO(alumno): genera un certificado managed para tu dominio.
# resource "google_compute_managed_ssl_certificate" "default" { ... }
# resource "google_compute_target_https_proxy" "default" { ... }
# resource "google_compute_global_forwarding_rule" "https" { ... }

resource "google_compute_global_address" "lb_ip" {
  name = "oms-${var.env}-lb-ip"
}

# ─── Outputs ──────────────────────────────────────────────────────
output "cloud_run_url"             { value = google_cloud_run_v2_service.oms.uri }
output "cloud_run_service_account" { value = google_service_account.cloud_run.email }
output "load_balancer_ip"          { value = google_compute_global_address.lb_ip.address }
