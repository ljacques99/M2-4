# ── Módulo: COMPUTE ───────────────────────────────────────────────
# Cloud Run para el monolito OMS + HTTPS Load Balancer + Cloud CDN.
# Cloud Run es stateless: NFR-SCAL-001 (autoescalado horizontal hasta 5×).

variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "image_repo" { type = string }
variable "image_sha" { type = string }
variable "cloud_run_min_instances" { type = number }
variable "cloud_run_max_instances" { type = number }
variable "db_connection_name" { type = string }
variable "db_secret_id" { type = string }
variable "redis_host" { type = string }
variable "network_id" { type = string }
variable "vpc_connector_id" { type = string }
variable "domain_name" { type = string }
variable "production_cicd_sa_email" {
  type    = string
  default = ""
} # solo se usa en staging
variable "labels" { type = map(string) }

# ─── Artifact Registry: repositorio Docker del OMS ────────────────
resource "google_artifact_registry_repository" "oms" {
  location      = var.region
  repository_id = "oms"
  format        = "DOCKER"
  description   = "Imágenes Docker del monolito OMS para este entorno. Como staging y producción son proyectos GCP separados, el CI/CD publica el mismo digest en el repo de cada proyecto (ver .github/workflows/ci-cd.yml) — el contenido de la imagen es idéntico, solo cambia dónde vive."
  labels        = var.labels

  docker_config {
    immutable_tags = true
  }
}

# Solo en staging: da acceso de solo-lectura al SA de CI/CD de producción,
# para que el job "replicate-to-production" del workflow (environment:
# production) pueda hacer `docker pull` de la imagen por digest y
# republicarla en el registry de producción SIN necesitar credenciales de
# staging. Aislamiento real de vars por Environment en GitHub Actions exige
# que ese job nunca vea el WIF provider ni el SA de staging.
resource "google_artifact_registry_repository_iam_member" "production_reader" {
  count      = var.production_cicd_sa_email != "" ? 1 : 0
  location   = google_artifact_registry_repository.oms.location
  repository = google_artifact_registry_repository.oms.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.production_cicd_sa_email}"
}

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
  # Ingress abierto (default) en vez de INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER:
  # se evaluó restringir a solo-LB, pero el healthcheck post-deploy de Ansible
  # (deploy.yml) golpea la URL *.run.app directamente desde el control node
  # (fuera de GCP) para verificar el despliegue antes de que exista DNS/cert
  # del LB — restringir a solo-LB habría roto esa verificación. El LB sigue
  # siendo el único camino documentado/soportado para tráfico de usuarios
  # reales (ver DECISIONES.md); esto es un trade-off consciente, no un olvido.
  ingress = "INGRESS_TRAFFIC_ALL"

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

      startup_probe {
        initial_delay_seconds = 5
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 6
        http_get {
          path = "/healthz"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 3
        period_seconds        = 15
        failure_threshold     = 3
        http_get {
          path = "/healthz"
          port = 8080
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }

    # VPC connector para alcanzar Memorystore (red privada). Solo el tráfico
    # a rangos privados pasa por el connector; el resto sale por la ruta
    # normal de Cloud Run (no hace falta forzar todo el egress).
    vpc_access {
      connector = var.vpc_connector_id
      egress    = "PRIVATE_RANGES_ONLY"
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = var.labels

  lifecycle {
    ignore_changes = [
      # Todo lo que ansible/roles/oms_cloud_run controla vía `gcloud run
      # deploy`/`update-traffic` en cada despliegue real, no en terraform
      # apply diario. Verificado con un deploy real contra staging: sin
      # estos ignore_changes, el siguiente `terraform plan` intentaba
      # revertir el digest, el % de tráfico, los límites de cpu/memoria
      # (Ansible los varía por entorno vía group_vars/{env}.yml) y hasta
      # los metadatos client/client_version que `gcloud` añade solo — nada
      # de eso vuelve a quedar "limpio" a la primera si no se ignora aquí.
      template[0].containers[0].image,
      template[0].containers[0].resources,
      template[0].revision,
      traffic,
      client,
      client_version,
    ]
  }
}

# Cloud Run es privado por defecto: sin este binding, IAM deniega toda
# invocación no autenticada con 403 aunque el contenedor esté sano (probes
# internos en verde). El OMS es una app pública de cara a usuarios finales,
# así que se permite invocación anónima — la protección real de acceso vive
# en el propio LB (WAF/CDN) y, cuando exista, en la capa de auth de la app.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.oms.name
  role     = "roles/run.invoker"
  member   = "allUsers"
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
    cache_mode        = "CACHE_ALL_STATIC"
    default_ttl       = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400

    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
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

resource "google_compute_global_address" "lb_ip" {
  name = "oms-${var.env}-lb-ip"
}

# Certificado gestionado por Google — se emite automáticamente cuando el
# registro DNS de var.domain_name apunta a google_compute_global_address.lb_ip.
# Hasta entonces queda en estado PROVISIONING sin bloquear el apply.
resource "google_compute_managed_ssl_certificate" "default" {
  name = "oms-${var.env}-cert"
  managed {
    domains = [var.domain_name]
  }
}

# NFR-SEC-002: TLS 1.3 en el Load Balancer — política SSL explícita en vez de
# la de compatibilidad por defecto (que permite TLS 1.0).
resource "google_compute_ssl_policy" "modern" {
  name            = "oms-${var.env}-ssl-policy"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2" # GCP no ofrece un "mínimo TLS 1.3" — MODERN negocia 1.3 cuando el cliente lo soporta
}

resource "google_compute_target_https_proxy" "default" {
  name             = "oms-${var.env}-https-proxy"
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default.id]
  ssl_policy       = google_compute_ssl_policy.modern.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "oms-${var.env}-https-fw"
  ip_address            = google_compute_global_address.lb_ip.id
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.default.id
}

# Redirección HTTP → HTTPS (evitamos servir nada en texto plano).
resource "google_compute_url_map" "https_redirect" {
  name = "oms-${var.env}-http-redirect"
  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "oms-${var.env}-http-proxy"
  url_map = google_compute_url_map.https_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "oms-${var.env}-http-fw"
  ip_address            = google_compute_global_address.lb_ip.id
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.redirect.id
}

# ─── Outputs ──────────────────────────────────────────────────────
output "cloud_run_url" { value = google_cloud_run_v2_service.oms.uri }
output "cloud_run_service_account" { value = google_service_account.cloud_run.email }
output "load_balancer_ip" { value = google_compute_global_address.lb_ip.address }
output "artifact_registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.oms.repository_id}"
}
output "managed_cert_id" {
  description = "ID del certificado gestionado. Usa 'gcloud compute ssl-certificates describe' con este nombre para ver el estado por dominio (PROVISIONING/ACTIVE)."
  value       = google_compute_managed_ssl_certificate.default.id
}
