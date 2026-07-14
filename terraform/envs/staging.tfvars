# ── Entorno: STAGING ────────────────────────────────────────────────
# Tier reducido, autoscaling mínimo, deletion_protection sigue ACTIVADO
# (es buena práctica protegerlo también en staging).

project_id = "acmeoms-platform"
region     = "europe-west3" # REG-GDPR-001
env        = "staging"

vpc_cidr = "10.20.0.0/16"

db_tier = "db-custom-2-7680" # 2 vCPU, 7.5 GB RAM

cloud_run_min_instances = 0 # escala a cero cuando no hay tráfico
cloud_run_max_instances = 5 # tope conservador para staging

# image_repo/image_sha SOLO se usan para el bootstrap inicial del servicio
# Cloud Run (compute/main.tf tiene lifecycle.ignore_changes sobre la imagen,
# así que terraform nunca la vuelve a tocar tras el primer apply). Usamos la
# imagen oficial de quickstart de Cloud Run (responde 200 en cualquier ruta,
# incluida /healthz) para que el primer `terraform apply` levante una
# revisión sana. El deploy real de la app lo hace ansible/playbooks/deploy.yml
# apuntando a europe-west3-docker.pkg.dev/acmeoms-platform/oms@<sha-real>.
image_repo = "us-docker.pkg.dev/cloudrun/container/hello"
image_sha  = "sha256:3beb8d6dd8bac1c597d10f3ddf59f5f684d6054ab589c4334c0486dad07a3f97"

deletion_protection = true # también en staging

github_repository = "ljacques99/oms-platform"

domain_name = "oms-staging.evolversfr.com"
