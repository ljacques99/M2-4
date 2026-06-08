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
    # TODO(alumno): añade una validación que prohíba regiones fuera de la UE.
    condition     = startswith(var.region, "europe-")
    error_message = "REG-GDPR-001 exige una región europea (europe-*)."
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
  description = "Tier de Cloud SQL. Cambia entre entornos."
  # TODO(alumno): elige tier sensato por entorno (ej. db-custom-2-7680 en staging,
  # db-custom-4-15360 en producción) y reflexiona en el README por qué.
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
