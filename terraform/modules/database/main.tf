# ── Módulo: DATABASE ───────────────────────────────────────────────
# Cloud SQL PostgreSQL multi-zone (NFR-AVAIL-001) + Memorystore Redis (NFR-PERF-001).
# Password gestionada en Secret Manager — NUNCA en variables ni en tfstate plano.

variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "network_id" { type = string }
variable "private_subnet_id" { type = string }
variable "private_vpc_connection_id" { type = string }
variable "db_tier" { type = string }
variable "deletion_protection" { type = bool }
variable "labels" { type = map(string) }

# ─── Password aleatoria gestionada por GCP en Secret Manager ──────
# Se genera con el provider `random` (nunca en texto plano en el repo ni en
# variables de CI) y se guarda como una versión del secreto. Terraform state
# la contendrá — por eso el state vive en un bucket GCS privado con
# uniform-bucket-level-access, no en el repo.
resource "random_password" "db" {
  length  = 32
  special = true
  # Postgres no admite todos los símbolos en connection strings por defecto;
  # restringimos a un set seguro de imprimir/parsear.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "oms-${var.env}-db-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  labels = var.labels
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# ─── Cloud SQL PostgreSQL ─────────────────────────────────────────
resource "google_sql_database_instance" "main" {
  name                = "oms-${var.env}-postgres"
  database_version    = "POSTGRES_16" # pin EXPLÍCITO — no dejar en mayor genérica
  region              = var.region
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.db_tier
    availability_type = "REGIONAL" # NFR-AVAIL-001 multi-zone HA
    disk_size         = 100
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14 # OPS-005: PITR 14d
      }
      start_time = "03:00" # backup nocturno
    }

    maintenance_window {
      day  = 7 # domingo
      hour = 4
    }

    ip_configuration {
      ipv4_enabled    = false # NUNCA expuesto a internet
      private_network = var.network_id
    }

    # Logging mínimo: DDL siempre (audit trail REG-GDPR-003) y queries lentas
    # (>500ms) para detectar regresiones de performance sin loguear cada SELECT.
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "500"
    }

    # CMEK propia (bonus): no implementada por defecto — Cloud SQL usa la clave
    # gestionada por Google (AES-256, cumple NFR-SEC-001 igualmente). Para
    # activar CMEK habría que crear un google_kms_crypto_key y referenciarlo
    # aquí como encryption_key_name antes de crear la instancia (no se puede
    # añadir a una instancia ya existente).

    user_labels = var.labels
  }

  lifecycle {
    prevent_destroy = true # defensa adicional contra terraform destroy
  }

  # La conexión de Private Service Access debe existir ANTES de crear la
  # instancia con IP privada, si no la API responde "network doesn't have
  # at least 1 private services connection" en una carrera con el peering.
  depends_on = [var.private_vpc_connection_id]
}

# ─── Base de datos para el OMS ────────────────────────────────────
resource "google_sql_database" "oms" {
  name     = "oms"
  instance = google_sql_database_instance.main.name
}

# ─── Usuario de aplicación con password gestionada ────────────────
# Cloud SQL puede generar y rotar la password automáticamente.
resource "google_sql_user" "oms" {
  name     = "oms_app"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}

# ─── Memorystore Redis Standard (HA) ──────────────────────────────
resource "google_redis_instance" "cache" {
  name           = "oms-${var.env}-redis"
  tier           = "STANDARD_HA" # NFR-AVAIL-001: replica automática
  memory_size_gb = var.env == "production" ? 5 : 1
  region         = var.region

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version           = "REDIS_7_2"
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  auth_enabled            = true

  labels = var.labels

  depends_on = [var.private_vpc_connection_id]
}

# ─── Outputs ──────────────────────────────────────────────────────
output "db_connection_name" { value = google_sql_database_instance.main.connection_name }
output "db_private_ip" { value = google_sql_database_instance.main.private_ip_address }
output "db_password_secret_id" { value = google_secret_manager_secret.db_password.secret_id }

output "redis_host" { value = google_redis_instance.cache.host }
output "redis_port" { value = google_redis_instance.cache.port }
output "redis_auth_secret" {
  value     = google_redis_instance.cache.auth_string
  sensitive = true
}
