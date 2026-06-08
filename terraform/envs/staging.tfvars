# ── Entorno: STAGING ────────────────────────────────────────────────
# Tier reducido, autoscaling mínimo, deletion_protection sigue ACTIVADO
# (es buena práctica protegerlo también en staging).

project_id = "TODO-acme-oms-staging"   # ⚠ TODO(alumno): tu proyecto GCP de staging
region     = "europe-west3"            # REG-GDPR-001
env        = "staging"

vpc_cidr   = "10.20.0.0/16"

db_tier    = "db-custom-2-7680"        # 2 vCPU, 7.5 GB RAM

cloud_run_min_instances = 0            # escala a cero cuando no hay tráfico
cloud_run_max_instances = 5            # tope conservador para staging

image_repo = "europe-west3-docker.pkg.dev/TODO-project/oms"
image_sha  = "sha256:TODO_PEGA_AQUI_EL_SHA_CONSTRUIDO_POR_CI"

deletion_protection = true             # también en staging

github_repository = "TODO-org/oms-platform"
