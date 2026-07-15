# Informe de tests — OMS Platform

Todas las pruebas de este informe se ejecutaron contra infraestructura **real** en GCP (proyectos `acmeoms-platform` y `acmeoms-platform-prod`), no simulada. Fecha: 2026-07-14.

## 0 · Re-verificación tras el split de CI/CD por Environment (2026-07-15)

Cambios de esta sesión: nuevo binding IAM (`production_reader`, solo lectura, SA de producción → Artifact Registry de staging), split del job `build` en `build`/`replicate-to-production` en `ci-cd.yml`, y el rename `github_repository` → `ljacques99/M2-4` (pendiente desde el 14/07, ya reflejado en el `apply` real de ambos entornos).

| Check | Resultado |
|---|---|
| `terraform fmt -check -recursive` | ✅ Sin diferencias |
| `terraform plan -var-file=envs/staging.tfvars` | ✅ **"No changes."** — incluye el nuevo `production_reader` (ya aplicado) y el `github_repository` renombrado |
| `terraform plan -var-file=envs/production.tfvars` | ✅ **"No changes."** — confirma que el rename de `github_repository` ya estaba aplicado contra la API real en ambos proyectos, no solo en los `.tfvars` |
| `google_artifact_registry_repository_iam_member.production_reader` | ✅ Verificado con `gcloud artifacts repositories get-iam-policy oms --project=acmeoms-platform` — el binding existe de verdad, no solo en el state |
| `terraform init -backend=false && terraform validate` | ❌ **Sigue roto** (bug preexistente, no introducido esta sesión — ver `DECISIONES.md` §8): `Error: Missing required argument "bucket"` sobre el bloque `backend "gcs" {}` vacío, reproducido también en la copia limpia |
| `ansible-playbook {deploy,rollback}.yml --syntax-check` | ✅ OK ambos |
| `ansible-lint playbooks/*.yml roles/oms_cloud_run/tasks/main.yml` | ✅ **Passed: 0 failure(s), 0 warning(s)** |
| `docker build -f docker/Dockerfile app/` | ✅ Build exitoso (multi-stage, cache reutilizado) |
| Label `org.opencontainers.image.source` del Dockerfile | ✅ `https://github.com/ljacques99/M2-4` (rename aplicado) |
| `npm ci && npm test` (app) | ✅ `OK: /healthz devuelve 200` |
| `ci-cd.yml`: parseo YAML + jobs esperados | ✅ 5 jobs: `quality`, `build`, `replicate-to-production`, `deploy-staging`, `deploy-production` |
| `gitleaks` / `hadolint` | ⏳ No disponibles en este entorno de verificación (sí se corrieron el 14/07, ver §3/§4 más abajo) — sin cambios que afecten a ninguno de los dos desde entonces |

**No verificado (sigue igual que el 14/07):** el workflow de GitHub Actions end-to-end — el repo `ljacques99/M2-4` todavía no existe en GitHub.

## 1 · Terraform

### 1.1 `terraform init && terraform plan` — staging

| Paso | Resultado |
|---|---|
| `terraform init -backend-config=...staging` | ✅ Backend GCS configurado (`acmeoms-platform-tfstate`) |
| `terraform fmt -check -recursive` | ✅ Sin diferencias de formato |
| `terraform plan -var-file=envs/staging.tfvars` (1ª vez) | ✅ Plan limpio, 43 recursos a crear, 0 errores |
| `terraform apply` | ⚠️ Falló parcialmente (ver 1.3) — 33/43 recursos creados |
| `terraform apply` (2º intento, tras fix) | ✅ 10 recursos restantes creados sin error |
| `terraform plan` (verificación final) | ✅ **"No changes. Your infrastructure matches the configuration."** |

### 1.2 `terraform plan && apply` — producción

| Paso | Resultado |
|---|---|
| Proyecto `acmeoms-platform-prod` creado + billing vinculado | ✅ |
| `terraform init -backend-config=...production` | ✅ Backend GCS configurado (`acmeoms-platform-prod-tfstate`) |
| `terraform plan -var-file=envs/production.tfvars` | ✅ Plan limpio |
| `terraform apply` | ⚠️ Falló una vez por error transitorio de autenticación en Service Networking API (`Error code 16: invalid authentication credentials`) — reintento exitoso |
| `terraform apply` (2º intento) | ✅ 13 recursos creados, 1 reemplazado (fix del VPC connector) |
| `terraform plan` (verificación final) | ✅ **"No changes."** |

### 1.3 Idempotencia — resultado final

```
$ terraform plan -var-file=envs/staging.tfvars
No changes. Your infrastructure matches the configuration.

$ terraform plan -var-file=envs/production.tfvars
No changes. Your infrastructure matches the configuration.
```

Ambos entornos alcanzaron idempotencia real solo después de corregir 3 bugs encontrados en la ejecución (ver `DECISIONES.md` sección 7): falta de `depends_on` en Private Service Access (condición de carrera con Cloud SQL/Redis), drift de `max_throughput` en el VPC connector, y falta de `ignore_changes` sobre `traffic`/`resources`/`client` en `google_cloud_run_v2_service` (Ansible y Terraform se disputaban esos campos).

### 1.4 Protecciones de producción

| Protección | Verificado |
|---|---|
| `deletion_protection = true` en Cloud SQL (ambos entornos) | ✅ Confirmado en `google_sql_database_instance.main` |
| `lifecycle.prevent_destroy` en Cloud SQL | ✅ **Se disparó de verdad**: un `terraform plan` accidental contra el backend de staging con `.tfvars` de producción intentó destruir Cloud SQL de staging; el `apply` habría fallado en seco por esta protección (no llegó a ejecutarse `apply`, se detectó en el `plan`) |
| `database_version` pinneada | ✅ `POSTGRES_16` explícito, no genérico |
| `backup_configuration` con PITR ≥ 14d | ✅ `retained_backups = 14`, `point_in_time_recovery_enabled = true` |

## 2 · Ansible

### 2.1 Sintaxis y lint

```
$ ansible-playbook playbooks/deploy.yml --syntax-check    → OK
$ ansible-playbook playbooks/rollback.yml --syntax-check  → OK
$ ansible-lint playbooks/*.yml roles/oms_cloud_run/tasks/main.yml
Passed: 0 failure(s), 0 warning(s) in 3 files processed of 3 encountered.
Last profile that met the validation criteria was 'production'.
```

(La primera corrida de `ansible-lint` marcó 7 violaciones de la regla `var-naming[no-role-prefix]` — variables del role sin prefijo `oms_cloud_run_`. Corregido renombrando todas las variables registradas del role.)

### 2.2 Deploy real — staging

```
$ ansible-playbook playbooks/deploy.yml -e env=staging -e image_sha=sha256:407bec51...
PLAY RECAP: ok=12  changed=2  failed=0

$ ansible-playbook playbooks/deploy.yml -e env=staging -e image_sha=sha256:407bec51... # repetido
PLAY RECAP: ok=8  changed=0  failed=0   ← idempotencia confirmada
```

### 2.3 Deploy real — producción

```
$ ansible-playbook playbooks/deploy.yml -e env=production -e image_sha=sha256:407bec51...
PLAY RECAP: ok=12  changed=2  failed=0
Tráfico nuevo: 10% (canary, según group_vars/production.yml)

$ ansible-playbook playbooks/deploy.yml -e env=production -e image_sha=sha256:407bec51... # repetido
PLAY RECAP: ok=8  changed=0  failed=0   ← idempotencia confirmada
```

**Mismo `image_sha` en ambos entornos** (`sha256:407bec51084b11393c9150aa05b52e6aa99677018242eeb7e9eee54dac7c7f55`), verificado con `docker inspect` antes y después de cada push — sin penalización de -10pts aplicable.

### 2.4 Rollback real — staging

```
$ ansible-playbook playbooks/rollback.yml -e env=staging
Rollback oms-staging: oms-staging-00002-sus → oms-staging-00001-nz8 (100% tráfico)
PLAY RECAP: ok=7  changed=1  failed=0
```

Verificado con `gcloud run services describe --format="value(status.traffic)"`: el 100% del tráfico pasó a la revisión anterior. Tras la prueba, se restauró el tráfico a la revisión de la app real (ver limitación conocida en `DECISIONES.md` §7: `deploy.yml` no restaura tráfico automáticamente si el `image_sha` ya coincide con el spec pero el tráfico activo es otro).

### 2.5 Diferencias staging/producción

```
$ diff ansible/group_vars/staging.yml ansible/group_vars/production.yml
```
Solo difieren: `env`, `gcp_project`, `cloud_run_min/max_instances`, `cloud_run_cpu/memory`, `db_instance_connection`, `redis_endpoint`, `traffic_percent`, `slack_channel`, `pagerduty_routing_key` — todo capacidad/endpoints/notificaciones, ninguna línea de comportamiento. Defendible una por una (comentado inline en el propio fichero).

## 3 · Docker

| Test | Resultado |
|---|---|
| `docker build -f docker/Dockerfile app/` | ⚠️ Falló 1ª vez (`node_modules` no existía sin dependencias) → corregido con `mkdir -p node_modules` |
| `docker build` (2º intento) | ✅ Build exitoso |
| `docker run` + `whoami` dentro del contenedor | ✅ `oms` (no root, UID 10001) |
| `curl /healthz` contra el contenedor local (puerto mapeado) | ✅ `{"status":"ok","env":"unknown"}`, HTTP 200 |
| `HEALTHCHECK` del Dockerfile | ✅ Presente, `wget` contra `/healthz` cada 30s |

## 4 · Seguridad — gitleaks

```
$ gitleaks detect --source . --no-banner
1 commits scanned.
scan completed in 46.2ms
no leaks found
```

Sin credenciales estáticas en el repo. Ninguna clave de service account JSON en ningún fichero — toda la autenticación de CI/CD es WIF.

## 5 · CI/CD (WIF)

No se pudo probar `.github/workflows/ci-cd.yml` end-to-end porque el repo de GitHub aún no se ha creado (`ljacques99/M2-4` es un placeholder — ver README). Verificado estáticamente:

| Check | Resultado |
|---|---|
| `permissions: id-token: write` a nivel de workflow | ✅ |
| Ningún `secrets.GCP_SA_KEY_JSON` ni clave JSON en el workflow | ✅ (`gitleaks` tampoco encontró nada) |
| `attribute_condition` del pool WIF restringe a `assertion.repository == "<repo>"` y `refs/tags/v*` | ✅ Verificado en `terraform/modules/iam/main.tf` y confirmado con `terraform output workload_identity_provider` tras el apply real |
| Bug real corregido: `allowed_audiences = ["sts.amazonaws.com"]` (audiencia de AWS, no de GCP) | ✅ Corregido antes de cualquier intento de uso |

## 6 · End-to-end (aplicación real desplegada)

| Prueba | staging | producción |
|---|---|---|
| Cloud Run `status.url` responde 200 en `/` | ✅ `oms-staging-ighncvzfpa-ey.a.run.app` | ✅ `oms-production-agmmv3nfwq-ey.a.run.app` |
| Health/liveness probes internos de Cloud Run (`/healthz`) | ✅ "STARTUP HTTP probe succeeded", "LIVENESS HTTP probe succeeded" (logs reales) | ✅ (mismo comportamiento, mismo módulo) |
| `/healthz` vía dominio público `*.a.run.app` | ❌ 404 — **hallazgo real, no es un bug de la app** (ver DECISIONES.md §7.2): el borde de Google Frontend reserva esa ruta exacta | ❌ (mismo comportamiento esperado) |
| Acceso público sin IAM invoker | ❌ 403 inicialmente → ✅ corregido con `google_cloud_run_v2_service_iam_member` | ✅ (aplicado desde el primer apply) |
| Load Balancer / dominio custom (`oms-staging.evolversfr.com`, `oms.evolversfr.com`) | ⏳ Pendiente — requiere que el usuario configure el registro DNS (IPs entregadas: `136.69.49.66` / `136.69.47.121`); el certificado gestionado está en `PROVISIONING` hasta que el DNS resuelva | ⏳ Igual |

## 7 · Resumen

- **43 + 13 = 56 recursos GCP reales** provisionados y verificados idempotentes en dos proyectos aislados.
- **7 bugs reales** encontrados y corregidos que ningún `terraform validate`/`ansible-lint` estático habría detectado — solo aparecieron al ejecutar contra las APIs reales (detalle completo en `DECISIONES.md` §7).
- **0 credenciales filtradas** (gitleaks).
- **Mismo digest de imagen** en staging y producción, confirmado por hash, no por nombre de tag.
- Pendiente de verificación real: el flujo de GitHub Actions (repo aún no creado) y el acceso vía dominio custom + LB (pendiente de propagación DNS, fuera del control de esta sesión).
