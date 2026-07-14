# ── Módulo: IAM ────────────────────────────────────────────────────
# Workload Identity Federation para que GitHub Actions despliegue
# SIN claves estáticas (Vídeo 4). Service Accounts con scope mínimo.

variable "project_id" { type = string }
variable "env" { type = string }
variable "github_repository" { type = string } # formato "owner/repo"
variable "cloud_run_sa" { type = string }      # email del SA del runtime
variable "labels" { type = map(string) }

# ─── Workload Identity Pool ──────────────────────────────────────
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool-${var.env}"
  display_name              = "GitHub Actions — ${var.env}"
  description               = "Pool para que GHA impersone SAs sin claves estáticas."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  # Sin allowed_audiences explícito: por defecto GCP acepta como audiencia el
  # resource name completo de este provider, que es justo lo que envía
  # google-github-actions/auth. (Un error común copiado de tutoriales viejos
  # es poner aquí "sts.amazonaws.com" — eso es un artefacto de AWS STS y hace
  # que la validación del token OIDC falle contra GCP).
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # 🔒 Restricción CRÍTICA: solo workflows de este repo concreto
  # Y solo desde tags de release (refs/tags/v*).
  attribute_condition = <<-EOT
    assertion.repository == "${var.github_repository}" &&
    assertion.ref.startsWith("refs/tags/v")
  EOT
}

# ─── Service Account que asume el pipeline ────────────────────────
resource "google_service_account" "cicd" {
  account_id   = "oms-${var.env}-cicd"
  display_name = "OMS ${var.env} — CI/CD SA (impersonado vía WIF)"
}

# Permiso para que el pool impersone este SA (solo el repo correcto).
resource "google_service_account_iam_binding" "cicd_wif" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}",
  ]
}

# ─── Permisos del SA de CI/CD (principio de mínimo privilegio) ──
# Nunca roles/owner ni roles/editor. Cada rol está justificado en el README
# (sección Decisiones):
#   - roles/run.developer            despliega/actualiza revisiones de Cloud Run
#   - roles/iam.serviceAccountUser   necesario para desplegar un servicio que
#                                     corre "as" el SA de runtime (oms-<env>-runtime)
#   - roles/artifactregistry.writer  publica imágenes en el repo Docker
#   - roles/logging.logWriter        el propio workflow escribe logs de build/deploy
locals {
  cicd_roles = [
    "roles/run.developer",
    "roles/iam.serviceAccountUser",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
  ]
}

resource "google_project_iam_member" "cicd" {
  for_each = toset(local.cicd_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.cicd.email}"
}

# ─── Permisos del SA del Cloud Run runtime ───────────────────────
# El runtime SOLO necesita leer secretos y conectar a Cloud SQL.
resource "google_project_iam_member" "runtime_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${var.cloud_run_sa}"
}

resource "google_project_iam_member" "runtime_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${var.cloud_run_sa}"
}

# ─── Outputs ──────────────────────────────────────────────────────
output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
  # Formato consumible por google-github-actions/auth:
  # projects/<NUM>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>
}

output "cicd_service_account_email" {
  value = google_service_account.cicd.email
}
