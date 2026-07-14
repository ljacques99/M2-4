output "load_balancer_ip" {
  description = "IP global del HTTPS Load Balancer."
  value       = module.compute.load_balancer_ip
}

output "cloud_run_url" {
  description = "URL del servicio Cloud Run del OMS."
  value       = module.compute.cloud_run_url
}

output "db_connection_name" {
  description = "Connection name de Cloud SQL (proj:region:instance)."
  value       = module.database.db_connection_name
  sensitive   = false
}

output "redis_host" {
  description = "Host privado de Memorystore Redis."
  value       = module.database.redis_host
  sensitive   = false
}

output "workload_identity_provider" {
  description = "Provider de WIF para configurar en GitHub Actions."
  value       = module.iam.workload_identity_provider
}

output "cicd_service_account" {
  description = "Service Account que asumen los workflows de CI/CD."
  value       = module.iam.cicd_service_account_email
}

output "artifact_registry_url" {
  description = "URL del repositorio de Artifact Registry donde se publican las imágenes del OMS."
  value       = module.compute.artifact_registry_url
}

output "secret_manager_db_secret_id" {
  description = "ID del secreto en Secret Manager con la password de la app DB."
  value       = module.database.db_password_secret_id
}

output "cloud_run_service_name" {
  description = "Nombre del servicio Cloud Run (lo consume ansible/group_vars vía cloud_run_service)."
  value       = "oms-${var.env}"
}
