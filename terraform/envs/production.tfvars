# ── Entorno: PRODUCTION ─────────────────────────────────────────────
# Tier mayor, autoscaling con piso mínimo > 0 (latencia consistente),
# deletion_protection OBLIGATORIO.
#
# ⚠ La ÚNICA diferencia legítima respecto a staging.tfvars debería ser:
#    - project_id (otro proyecto)
#    - db_tier (más capacidad)
#    - cloud_run_min/max_instances (más réplicas)
#    - image_sha (cuando promocionas, este valor cambia)
#
# Si te encuentras cambiando algo más, replantéatelo.

project_id = "acmeoms-platform-prod"
region     = "europe-west3" # REG-GDPR-001
env        = "production"

vpc_cidr = "10.20.0.0/16"

db_tier = "db-custom-4-15360" # 4 vCPU, 15 GB RAM

cloud_run_min_instances = 2  # nunca a cero: latencia consistente
cloud_run_max_instances = 25 # NFR-SCAL-001: pico 5× del normal

# Igual que en staging.tfvars: imagen de bootstrap oficial de Cloud Run,
# ignorada por terraform tras el primer apply (ver comentario en staging.tfvars).
# El SHA REAL que llega a producción lo decide ansible/playbooks/deploy.yml
# -e image_sha=... y DEBE ser el mismo que se validó en staging.
image_repo = "us-docker.pkg.dev/cloudrun/container/hello"
image_sha  = "sha256:3beb8d6dd8bac1c597d10f3ddf59f5f684d6054ab589c4334c0486dad07a3f97"

deletion_protection = true # innegociable

github_repository = "ljacques99/oms-platform"

domain_name = "oms.evolversfr.com"
