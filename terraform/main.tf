# Composition root del trabajo final.
# Cada módulo encapsula una capa de la arquitectura del OMS.

# ┌─────────────────────────────────────────────────────────┐
# │ Backend de estado en GCS.                                │
# │ El bloque backend no admite variables, así que el bucket │
# │ y el prefix se pasan en `terraform init -backend-config`:│
# │                                                            │
# │   terraform init \                                       │
# │     -backend-config="bucket=acmeoms-platform-tfstate" \  │
# │     -backend-config="prefix=oms-platform/staging"        │
# │                                                            │
# │   terraform init \                                       │
# │     -backend-config="bucket=acmeoms-platform-prod-tfstate" \│
# │     -backend-config="prefix=oms-platform/production"     │
# └─────────────────────────────────────────────────────────┘
# "bucket" tiene un valor placeholder porque `terraform validate` exige el
# argumento requerido del backend incluso con `init -backend=false` (falla
# con "Missing required argument" si se deja {} vacío). -backend-config lo
# sobrescribe igual en el init real de staging/producción.
terraform {
  backend "gcs" {
    bucket = "unconfigured"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Localización lógica del proyecto (etiquetas comunes).
locals {
  common_labels = {
    project    = "oms"
    env        = var.env
    managed_by = "terraform"
    module     = "platform"
  }
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa de red                                             │
# └─────────────────────────────────────────────────────────┘
module "network" {
  source = "./modules/network"

  project_id = var.project_id
  region     = var.region
  env        = var.env
  vpc_cidr   = var.vpc_cidr
  labels     = local.common_labels
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa de datos: Cloud SQL Postgres + Memorystore Redis   │
# └─────────────────────────────────────────────────────────┘
module "database" {
  source = "./modules/database"

  project_id                = var.project_id
  region                    = var.region
  env                       = var.env
  network_id                = module.network.network_id
  private_subnet_id         = module.network.private_subnet_id
  private_vpc_connection_id = module.network.private_vpc_connection_id
  db_tier                   = var.db_tier
  deletion_protection       = var.deletion_protection
  labels                    = local.common_labels
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa de cómputo: Cloud Run + Load Balancer + CDN        │
# └─────────────────────────────────────────────────────────┘
module "compute" {
  source = "./modules/compute"

  project_id               = var.project_id
  region                   = var.region
  env                      = var.env
  image_repo               = var.image_repo
  image_sha                = var.image_sha
  cloud_run_min_instances  = var.cloud_run_min_instances
  cloud_run_max_instances  = var.cloud_run_max_instances
  db_connection_name       = module.database.db_connection_name
  db_secret_id             = module.database.db_password_secret_id
  redis_host               = module.database.redis_host
  network_id               = module.network.network_id
  vpc_connector_id         = module.network.vpc_connector_id
  domain_name              = var.domain_name
  production_cicd_sa_email = var.production_cicd_sa_email
  labels                   = local.common_labels
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa IAM: Service Accounts + Workload Identity Federation│
# └─────────────────────────────────────────────────────────┘
module "iam" {
  source = "./modules/iam"

  project_id        = var.project_id
  env               = var.env
  github_repository = var.github_repository
  cloud_run_sa      = module.compute.cloud_run_service_account
  labels            = local.common_labels
}
