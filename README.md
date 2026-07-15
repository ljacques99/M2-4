# OMS Platform — Trabajo final Bloque 4

Infraestructura de **AcmeOMS** en Google Cloud Platform, provisionada con **Terraform** y operada con **Ansible**. El enunciado completo está en `Trabajo - enunciado.md`; este README documenta lo que se construyó, cómo arrancarlo y las decisiones tomadas.

Este trabajo **no implementa la aplicación OMS** — solo la infraestructura que la aloja (VPC, Cloud SQL, Redis, Cloud Run, Load Balancer, IAM/WIF, CI/CD). Para poder probar el pipeline de extremo a extremo se incluye en `app/` un stub HTTP mínimo (responde en `/healthz`) que NO es el OMS — es solo el "hola mundo" que viaja por Docker → Artifact Registry → Cloud Run → Ansible.

## Estado real de este entorno

Este repo se desplegó de verdad (no es un ejercicio solo-en-papel): infraestructura completa creada, imagen construida y publicada, y `ansible-playbook deploy.yml` ejecutado contra Cloud Run real en ambos entornos — con **el mismo digest de imagen** en los dos y `changed=0` en la segunda ejecución (idempotencia verificada, no solo declarada).

| Entorno | Proyecto GCP | Dominio | LB IP | Cloud Run URL |
|---|---|---|---|---|
| staging | `acmeoms-platform` | `oms-staging.evolversfr.com` | `136.69.49.66` | `oms-staging-ighncvzfpa-ey.a.run.app` |
| production | `acmeoms-platform-prod` | `oms.evolversfr.com` | `136.69.47.121` | `oms-production-agmmv3nfwq-ey.a.run.app` |

Ambos proyectos están vinculados a la misma cuenta de facturación y tienen las APIs necesarias habilitadas. El estado de Terraform vive en buckets GCS privados con versioning (`acmeoms-platform-tfstate` y `acmeoms-platform-prod-tfstate`), uno por proyecto — nunca en el repo.

> ⚠️ **Antes de cualquier `apply` contra producción**: verifica a qué backend apunta tu sesión con `cat terraform/.terraform/terraform.tfstate | grep bucket` (o revisa el mensaje de `terraform init`). En esta misma sesión, alternar entre `terraform init -reconfigure` de staging y de producción sin volver a reconfigurar antes de un `plan` casi provoca un `apply` que renombraba (destruía) los recursos de staging para "convertirlos" en los de producción — lo frenó `lifecycle.prevent_destroy` en Cloud SQL, no una revisión humana. Detalle completo en `DECISIONES.md` (sección 7, punto 5).

> ⚠️ **`/healthz` en el dominio público por defecto de Cloud Run (`*.a.run.app`) devuelve 404 siempre**, incluso con la app sana — el Google Frontend que sirve ese dominio intercepta esa ruta exacta antes de que llegue al contenedor. No es un bug de esta app: se reprodujo de forma determinista contra la URL principal y la URL con tag de revisión, con `/`, `/health`, `/healthcheck` y `/foo` respondiendo 200 con normalidad. Los probes internos de Cloud Run (`startup_probe`/`liveness_probe`) sí funcionan contra `/healthz` porque no pasan por ese borde público. El healthcheck externo de `ansible/playbooks/deploy.yml` por eso golpea `/`, no `/healthz`. Ver `DECISIONES.md` sección 7, punto 2.

## Pre-requisitos

| Herramienta | Versión usada aquí | Notas |
|---|---|---|
| `gcloud` | 575.0.1 | `gcloud auth login` + `gcloud auth application-default login` |
| `terraform` | 1.15.0 | `versions.tf` fija `>= 1.7.0` y providers `~> 5.20` |
| `ansible-core` | 2.16.3 | + `ansible-galaxy collection install -r ansible/requirements.yml` |
| `docker` | 28.2.2 | Para construir la imagen localmente |
| Node.js | 22 | Solo para el stub de `app/`, no para la infra |

### Cuenta de Google — ¿hace falta una?

Sí. Todo GCP se gestiona con una cuenta de Google normal (Gmail sirve) más una cuenta de **facturación** vinculada (usa el crédito gratuito de $300/90 días si es cuenta nueva). Pasos:

1. Entra en https://console.cloud.google.com con tu cuenta de Google.
2. Acepta el trial gratuito (pide tarjeta, no cobra dentro del free tier).
3. Crea un proyecto (o dos, uno por entorno — ver más abajo) y anota el **Project ID**.
4. `gcloud init` para vincular el proyecto por defecto.
5. `gcloud auth login` (sesión interactiva de usuario) y `gcloud auth application-default login` (credenciales que usa Terraform).

> Nota real de esta sesión: si `gcloud auth application-default login` falla con `Scope has changed from "...cloud-platform..." to "...userinfo.email..."`, es porque Google reutilizó un consentimiento OAuth previo más limitado para el cliente "Google Cloud SDK". Solución: revocar el acceso de esa app en https://myaccount.google.com/permissions y volver a autenticar aceptando **todos** los permisos solicitados.

## Arquitectura

```
                    ┌─────────────────────┐
                    │   USUARIOS FINALES  │
                    └──────────┬──────────┘
                               │ HTTPS (TLS 1.2/1.3, SSL policy MODERN)
                               ▼
                    ┌─────────────────────┐
                    │ HTTPS Load Balancer │  ← Cloud LB + Cloud CDN + cert gestionado
                    │  (+ redirect 80→443)│
                    └──────────┬──────────┘
                               │
                               ▼
              ┌──────────────────────────────────┐
              │  Cloud Run — OMS app             │  ← stateless, autoescalado 0→5 (staging) / 2→25 (prod)
              │  (imagen por DIGEST, no tag)      │     probes /healthz, VPC connector
              └────────┬─────────────────┬───────┘
                       │                 │ (vía VPC Access Connector)
                       ▼                 ▼
              ┌─────────────┐  ┌──────────────────┐
              │ Memorystore │  │   Cloud SQL      │  ← REGIONAL (multi-zone HA), PITR 14d
              │   Redis     │  │   PostgreSQL 16  │     deletion_protection + prevent_destroy
              │ STANDARD_HA │  │                  │
              └─────────────┘  └──────────────────┘
                                        │
                                        ▼
                              Secret Manager (password DB)

     Todo dentro de una VPC privada (10.20.0.0/16), sin IPs públicas en compute.
     Salida a internet vía Cloud NAT. SSH solo por IAP (35.235.240.0/20).
     Región: europe-west3 (Frankfurt) — REG-GDPR-001
     CI/CD: GitHub Actions con Workload Identity Federation (sin claves JSON)
```

Los 4 módulos de Terraform (`network`, `database`, `compute`, `iam`) se componen en `terraform/main.tf` y se aplican de forma idéntica en staging y producción — la única diferencia son los `.tfvars`.

## Cómo arrancar

### 1. Buckets de estado (ya creados en este entorno)

```bash
gcloud storage buckets create gs://acmeoms-platform-tfstate \
  --project=acmeoms-platform --location=europe-west3 --uniform-bucket-level-access
gcloud storage buckets update gs://acmeoms-platform-tfstate --versioning

gcloud storage buckets create gs://acmeoms-platform-prod-tfstate \
  --project=acmeoms-platform-prod --location=europe-west3 --uniform-bucket-level-access
gcloud storage buckets update gs://acmeoms-platform-prod-tfstate --versioning
```

### 2. Terraform — staging

```bash
cd terraform
terraform init \
  -backend-config="bucket=acmeoms-platform-tfstate" \
  -backend-config="prefix=oms-platform/staging"

terraform plan  -var-file=envs/staging.tfvars
terraform apply -var-file=envs/staging.tfvars
```

### 3. Terraform — producción

Cambiar de entorno significa **reinicializar el backend** (bucket distinto, proyecto distinto):

```bash
terraform init -reconfigure \
  -backend-config="bucket=acmeoms-platform-prod-tfstate" \
  -backend-config="prefix=oms-platform/production"

terraform plan  -var-file=envs/production.tfvars
terraform apply -var-file=envs/production.tfvars
```

### 4. DNS

El Load Balancer necesita un registro DNS antes de que el certificado gestionado pase de `PROVISIONING` a `ACTIVE`. Tras el `apply`, obtén la IP:

```bash
terraform output load_balancer_ip
```

Y crea en tu proveedor DNS (para `evolversfr.com`) un registro **A** (valores reales de este despliegue):

| Host | Tipo | Valor |
|---|---|---|
| `oms-staging.evolversfr.com` | A | `136.69.49.66` |
| `oms.evolversfr.com` | A | `136.69.47.121` |

El certificado tarda entre unos minutos y ~1h en activarse tras propagar el DNS. Se puede comprobar con:

```bash
gcloud compute ssl-certificates describe oms-staging-cert --global --format="value(managed.domainStatus)"
```

### 5. Build y push de la imagen

```bash
cd app && npm ci && npm test && cd ..

gcloud auth configure-docker europe-west3-docker.pkg.dev

docker build -f docker/Dockerfile \
  --build-arg GIT_SHA=$(git rev-parse --short HEAD) \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  -t europe-west3-docker.pkg.dev/acmeoms-platform/oms/oms:dev \
  app/

docker push europe-west3-docker.pkg.dev/acmeoms-platform/oms/oms:dev

IMAGE_SHA=$(docker inspect --format='{{index .RepoDigests 0}}' \
  europe-west3-docker.pkg.dev/acmeoms-platform/oms/oms:dev | cut -d'@' -f2)

# Producción vive en OTRO proyecto ⇒ otro Artifact Registry. Se replica el
# MISMO digest (no se reconstruye la imagen) para garantizar bit-a-bit el
# mismo binario en ambos entornos:
docker tag europe-west3-docker.pkg.dev/acmeoms-platform/oms/oms:dev \
  europe-west3-docker.pkg.dev/acmeoms-platform-prod/oms/oms:dev
gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet  # revalida credenciales tras cambiar de proyecto
docker push europe-west3-docker.pkg.dev/acmeoms-platform-prod/oms/oms:dev
```

### 6. Ansible

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml -p .collections

gcloud config set project acmeoms-platform
ansible-playbook playbooks/deploy.yml -e env=staging -e image_sha=$IMAGE_SHA
# Repetir el mismo comando → changed=0 (idempotente)

gcloud config set project acmeoms-platform-prod
ansible-playbook playbooks/deploy.yml -e env=production -e image_sha=$IMAGE_SHA
```

> El role `oms_cloud_run` valida que `gcloud config get-value project` coincida con `gcp_project` del entorno — por eso el `gcloud config set project` antes de cada `ansible-playbook` es obligatorio, no cosmético.

### 7. CI/CD (GitHub Actions)

`.github/workflows/ci-cd.yml`:

- En cada push/PR a `main`: lint + validate (`terraform fmt/validate`, `ansible-lint`, `npm test`, `hadolint`). No toca GCP, no necesita credenciales.
- En un tag `v*`: `build` (environment `staging`) construye y publica la imagen por digest en el Artifact Registry de staging → `replicate-to-production` (environment `production`) hace `pull` por digest y `push` al Artifact Registry de producción, sin reconstruir → `deploy-staging` → `deploy-production`, ambos con el **mismo digest**.
- Autenticación 100% por **Workload Identity Federation** — cero secretos `GCP_SA_KEY_JSON`. 6 variables necesarias (no son secretas, son IDs), **scoped por GitHub Environment** (`staging` / `production`), no a nivel de repo — así un job con `environment: production` nunca puede leer las vars de staging y viceversa:
  `STAGING_WIF_PROVIDER`, `STAGING_CICD_SA`, `STAGING_PROJECT_ID` (Environment `staging`) y `PRODUCTION_WIF_PROVIDER`, `PRODUCTION_CICD_SA`, `PRODUCTION_PROJECT_ID` (Environment `production`) — los WIF provider/SA salen de `terraform output workload_identity_provider` / `cicd_service_account` en cada entorno.
- Como el job `replicate-to-production` necesita leer la imagen de staging sin tener credenciales de staging, el SA de CI/CD de producción tiene `roles/artifactregistry.reader` (solo lectura, un único sentido) sobre el Artifact Registry de staging — ver `production_cicd_sa_email` en `terraform/envs/staging.tfvars` y el binding en `terraform/modules/compute/main.tf`.
- El `attribute_condition` del pool WIF (`terraform/modules/iam/main.tf`) restringe el trust a `assertion.repository == "<owner>/<repo>"` y `assertion.ref.startsWith("refs/tags/v")` — ni siquiera un fork del repo puede desplegar.
- La protección real de "promote a producción" (aprobación manual) se configura en GitHub → Settings → Environments → `production` → Required reviewers. Sin esa protección activada en la UI, el job se dispara automáticamente tras `deploy-staging`.

## Decisiones

Se trabajó con Claude (Anthropic) como asistente para generar el borrador inicial de Terraform/Ansible sobre el esqueleto con TODOs, aplicando después contra proyectos GCP reales para verificar cada pieza. Los **3 cambios concretos** más significativos que se hicieron al borrador antes de darlo por bueno:

1. **Bug de seguridad/correctitud en WIF: `allowed_audiences = ["sts.amazonaws.com"]`.** El borrador copiaba un valor de un tutorial antiguo — `sts.amazonaws.com` es la audiencia de AWS STS, no de GCP, y con eso configurado el token OIDC de GitHub Actions habría sido rechazado por el pool de Workload Identity en el primer intento real de autenticación desde CI. Se eliminó `allowed_audiences` para dejar el valor por defecto (el resource name completo del provider), que es justo lo que `google-github-actions/auth` envía. Sin probar un `terraform apply` real este bug habría pasado desapercibido hasta el primer workflow de GitHub Actions fallido.

2. **Condición de carrera real entre `google_service_networking_connection` y Cloud SQL/Redis.** El primer `terraform apply` contra `acmeoms-platform` falló en producción de verdad con `Error: ... network doesn't have at least 1 private services connection`: Cloud SQL y Memorystore arrancaron su creación antes de que la conexión de Private Service Access terminara de propagarse, porque Terraform solo infiere dependencias de *referencias* directas y `network_id` no pasa por esa conexión. Se añadió un `depends_on` explícito cruzando el límite de módulo (se expone `private_vpc_connection_id` como output de `network` y se consume en `database`), algo que no se detecta con `terraform plan` — solo con un `apply` real contra la API de GCP.

3. **`google.cloud.gcp_run_service` no existe.** El enunciado y el borrador inicial de Ansible asumían un módulo `google.cloud.gcp_cloudrun_*` "preferido" sobre `command`. Tras instalar la colección real (`google.cloud` v1.13.0) y revisar sus módulos (`ansible-galaxy collection install` + inspección de `plugins/modules/`), se confirmó que Cloud Run nunca llegó a tener soporte GA en esa colección. Se documentó explícitamente en `roles/oms_cloud_run/tasks/main.yml` y se mantuvo `ansible.builtin.command` con `gcloud run deploy`, pero con idempotencia genuina: se compara la imagen desplegada actual contra la deseada *antes* de decidir si ejecutar el comando (no solo un `changed_when` sobre el texto de salida).

Otras decisiones de diseño (más pequeñas, documentadas inline en el código):

- **Dos proyectos GCP separados** (`acmeoms-platform` / `acmeoms-platform-prod`) en vez de uno compartido: aislamiento real de IAM, cuotas y radio de explosión entre entornos, al coste de duplicar buckets de estado y Artifact Registry.
- **`db_tier` staging vs producción** (`db-custom-2-7680` vs `db-custom-4-15360`): staging no necesita absorber picos de tráfico real; producción sí, y NFR-SCAL-001 pide holgura para 5× el pico medido.
- **Redis `STANDARD_HA`** en ambos entornos (no `BASIC`) para no diverger comportamiento entre staging y producción — solo cambia `memory_size_gb` (1GB vs 5GB), no la topología.
- **Cloud NAT + sin IPs públicas en compute**: todo el tráfico saliente de Cloud Run/futuras VMs pasa por NAT; ninguna instancia tiene IP pública.
- **`google_cloud_run_v2_service` con `lifecycle.ignore_changes` sobre la imagen**: el `image_sha` de arranque en los `.tfvars` (imagen oficial `cloudrun/container/hello`, digest fijo) es solo un *bootstrap* para que el primer `apply` tenga algo real que ejecutar y pase los health checks; el ciclo de vida real de la imagen lo controla `ansible/playbooks/deploy.yml`, no `terraform apply`.

## Verificación final

```bash
# Estado limpio (segunda vez debe decir "No changes")
terraform plan -var-file=envs/staging.tfvars

# Ansible idempotente
ansible-playbook playbooks/deploy.yml -e env=staging -e image_sha=$IMAGE_SHA --check

# Búsqueda de credenciales filtradas
gitleaks detect --source . --no-banner

# Estructura sin TODOs pendientes
grep -r "TODO" . --include="*.tf" --include="*.yml" --include="Dockerfile" || echo "sin TODOs"
```

Resultados reales de estas verificaciones están en `INFORME-TESTS.md`.

## Runbooks operativos

### Restauración PITR (OPS-005, ejercicio mensual documentado, no automatizado)

```bash
gcloud sql backups list --instance=oms-staging-postgres
gcloud sql instances clone oms-staging-postgres oms-staging-postgres-restore-test \
  --point-in-time="2026-07-01T03:00:00Z"
# Verificar datos en la instancia clonada, luego borrarla:
gcloud sql instances delete oms-staging-postgres-restore-test --quiet
```

### Rollback de un despliegue

```bash
cd ansible
ansible-playbook playbooks/rollback.yml -e env=production
```

### Degradación de Redis (OPS-007)

No hay un mecanismo de Terraform/Ansible que "simule" la caída de Redis — es responsabilidad de la app leer con fallback a la base de datos si el cliente Redis falla (fuera del alcance de este bloque, que no implementa la app). Lo que sí garantiza esta infraestructura es que Redis nunca es una dependencia dura a nivel de red: Cloud Run sigue pudiendo alcanzar Cloud SQL aunque el VPC connector o Redis fallen, porque son recursos independientes en la misma VPC.

## Apagar el entorno (evitar costes)

```bash
terraform destroy -var-file=envs/staging.tfvars     # fallará por deletion_protection en Cloud SQL — es intencional
# Para destruir de verdad: primero pon deletion_protection=false en el .tfvars, apply, y LUEGO destroy.
```

## Si te bloqueas

- Vuelve al vídeo correspondiente (mapeo en `Trabajo - enunciado.md` sección 7)
- Canal Slack `#trabajo-modulo-1`
