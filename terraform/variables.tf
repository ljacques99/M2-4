# Variables del módulo raíz. Se sobreescriben con envs/<env>.tfvars

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se crea la infraestructura."
}

variable "region" {
  type        = string
  description = "Región principal. REG-GDPR-001 limita a regiones europeas."
  default     = "europe-west3"
  validation {
    # REG-GDPR-001: europe-west3 es la región obligatoria; europe-central2
    # solo se admite para la réplica DR del bonus multi-región.
    condition     = contains(["europe-west3", "europe-central2"], var.region)
    error_message = "REG-GDPR-001 exige europe-west3 (obligatoria) o europe-central2 (solo DR)."
  }
}

variable "env" {
  type        = string
  description = "Nombre del entorno: staging | production."
  validation {
    condition     = contains(["staging", "production"], var.env)
    error_message = "env debe ser 'staging' o 'production'."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR /16 de la VPC."
  default     = "10.20.0.0/16"
}

variable "db_tier" {
  type        = string
  description = "Tier de Cloud SQL. staging usa db-custom-2-7680 (2 vCPU/7.5GB); producción usa db-custom-4-15360 (4 vCPU/15GB) — ver 'Decisiones' en el README."
}

variable "cloud_run_min_instances" {
  type        = number
  description = "Mínimo de instancias de Cloud Run."
  default     = 0
}

variable "cloud_run_max_instances" {
  type        = number
  description = "Máximo de instancias (NFR-SCAL-001 — pico 5×)."
  default     = 10
}

variable "image_repo" {
  type        = string
  description = "Repositorio de Artifact Registry (ej. europe-west3-docker.pkg.dev/<proj>/oms)."
}

variable "image_sha" {
  type        = string
  description = "SHA256 de la imagen a desplegar (formato sha256:abc...). MISMO valor en staging y producción."
}

variable "deletion_protection" {
  type        = bool
  description = "Habilita deletion_protection en Cloud SQL. SIEMPRE true en producción."
  default     = true
}

variable "github_repository" {
  type        = string
  description = "Repo GitHub que puede impersonar el SA vía WIF (formato owner/repo)."
  default     = "acme-org/oms-platform"
}

variable "production_cicd_sa_email" {
  type        = string
  description = "Email del SA de CI/CD de producción. Solo se usa en staging.tfvars: le da acceso de solo lectura al Artifact Registry local, para que el job 'replicate-to-production' del workflow pueda hacer pull por digest sin necesitar credenciales de staging. Vacío ('') en producción — no crea ningún binding."
  default     = ""
}

variable "domain_name" {
  type        = string
  description = "Dominio público servido por el Load Balancer (usado en el certificado SSL gestionado)."
}
