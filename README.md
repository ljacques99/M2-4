# OMS Platform — Trabajo final Bloque 4

Esqueleto del trabajo final del **Bloque 4 · Plataforma e infraestructura**.
El enunciado completo está en `Trabajo - enunciado.md`.

## Pre-requisitos

| Herramienta | Versión mínima | Notas |
|---|---|---|
| `gcloud` | 470 | `gcloud auth login` + `gcloud config set project <tu-proyecto>` |
| `terraform` | 1.7 | Usa `tfenv` si necesitas varias versiones |
| `ansible-core` | 2.16 | + `ansible-galaxy collection install -r ansible/requirements.yml` |
| `docker` | 24+ | Para construir la imagen del OMS localmente |
| Python | 3.10+ | El plugin GCP de Ansible lo necesita |

## Estructura

Ver árbol completo en `Trabajo - enunciado.md` (sección 4).

## Cómo arrancar

1. **Crea un proyecto GCP** (o usa la sandbox del curso) y habilita las APIs:
   ```bash
   gcloud services enable compute.googleapis.com sqladmin.googleapis.com \
     run.googleapis.com redis.googleapis.com secretmanager.googleapis.com \
     iamcredentials.googleapis.com
   ```

2. **Crea el bucket de estado de Terraform:**
   ```bash
   gcloud storage buckets create gs://<tu-proyecto>-tfstate \
     --location=europe-west3 --uniform-bucket-level-access
   gcloud storage buckets update gs://<tu-proyecto>-tfstate --versioning
   ```

3. **Configura el backend** en `terraform/main.tf` con tu bucket.

4. **Init + plan + apply** (empieza por staging):
   ```bash
   cd terraform
   terraform init
   terraform plan  -var-file=envs/staging.tfvars
   terraform apply -var-file=envs/staging.tfvars
   ```

5. **Configura el WIF** para GitHub Actions (ver `terraform/modules/iam/main.tf`).

6. **Despliega con Ansible** (después de tener una imagen construida y subida a Artifact Registry):
   ```bash
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ansible-playbook playbooks/deploy.yml -e env=staging \
     -e image_sha=sha256:<TU-SHA>
   ```

## Decisiones (rellénalo tú)

Esta sección la completas al final con los **3 trade-offs principales** que tomaste durante el trabajo. Ejemplos del tipo de decisión que esperamos ver documentada:

- "Elegí Cloud Run y no GKE Autopilot porque..."
- "Activé `availability_type = REGIONAL` en Cloud SQL aunque encarece un 50% porque la spec NFR-AVAIL-001..."
- "Borré X líneas del borrador inicial que generó la IA porque..."

## Verificación final

```bash
# Estado limpio
terraform plan -var-file=envs/staging.tfvars      # No changes
ansible-playbook playbooks/deploy.yml -e env=staging --check  # No changes

# Búsqueda de credenciales filtradas
gitleaks detect --source . --no-banner

# Estructura
find . -name "TODO*" -o -path "*TODO*"            # debería estar vacío
```

## Si te bloqueas

- Vuelve al vídeo correspondiente (mapeo en `Trabajo - enunciado.md` sección 7)
- Canal Slack `#trabajo-modulo-1`
- Buena costumbre: si pasas más de 30 min bloqueado, pregunta
