# Registro de trabajo y decisiones — OMS Platform

Este documento detalla, de forma más extensa que la sección "Decisiones" del README, todo lo que se hizo para completar el esqueleto del Trabajo final Bloque 4 y por qué. Está pensado como bitácora técnica, no como resumen de marketing.

## 0. Contexto de partida

Se partió de un esqueleto (`oms-platform/`) con 46 `TODO` repartidos en Terraform, Ansible, Dockerfile y sin ningún workflow de CI/CD escrito. El enunciado pedía además verificar si hacía falta una cuenta de Google y documentarlo — sí hace falta, y el proceso real (incluyendo un bug de `gcloud auth application-default login` con scopes de OAuth reutilizados) quedó documentado en el README.

Se decidió, de acuerdo con el usuario, hacer un despliegue **real** contra proyectos GCP nuevos, no solo escribir código IaC sin probarlo.

## 1. Cuenta de Google y proyectos GCP

- Cuenta usada: `laurent.jacques79@gmail.com`.
- Se instaló `gcloud` CLI 575.0.1 (no venía preinstalado) vía el instalador oficial en `~/google-cloud-sdk`, añadido al `PATH` en `~/.bashrc`.
- `gcloud auth login` falló la primera vez con `ERROR: gcloud crashed (Warning): Scope has changed from "...cloud-platform..." to "...userinfo.email..."`. Causa: Google reutilizó un consentimiento OAuth previo más limitado para el cliente "Google Cloud SDK". Solución real aplicada: revocar el acceso de esa app en `myaccount.google.com/permissions` y reautenticar aceptando todos los scopes.
- Proyectos creados:
  - `acmeoms-platform` (staging) — ya existía, creado por el usuario.
  - `acmeoms-platform-prod` (producción) — creado en esta sesión con `gcloud projects create`, vinculado a la misma cuenta de facturación (`0139AD-69B760-84198C`).
- APIs habilitadas en ambos: Cloud Run, Cloud SQL Admin, Redis (Memorystore), Compute Engine, Secret Manager, IAM + IAM Credentials, Cloud Resource Manager, Storage, Service Networking, VPC Access, Logging, Artifact Registry.
- Buckets de estado de Terraform creados con versioning: `acmeoms-platform-tfstate` y `acmeoms-platform-prod-tfstate`, ambos `europe-west3`, `uniform-bucket-level-access`.

## 2. Terraform — qué se completó módulo a módulo

### `variables.tf` / `outputs.tf`
- Validación de `region` endurecida: de "cualquier `europe-*`" a solo `europe-west3` (obligatoria) o `europe-central2` (solo DR bonus), que es literalmente lo que pide REG-GDPR-001.
- `domain_name` añadida como variable nueva (necesaria para el certificado SSL gestionado).
- Outputs añadidos: `artifact_registry_url`, `secret_manager_db_secret_id`, `cloud_run_service_name` — los consume Ansible.
- `main.tf`: se activó el backend `gcs {}` parametrizado por `-backend-config` (el bloque no admite variables).

### `modules/network`
- Segunda subred (`gke`, con rangos secundarios `gke-pods`/`gke-services`) y una tercera subred `/28` dedicada al VPC Access Connector — ninguna se solapa (se recalculó el particionado del `/16` a mano tras que un primer intento con `cidrsubnet` anidado sí solapara).
- `google_vpc_access_connector`: necesario para que Cloud Run (serverless, sin NIC en la VPC) llegue a Memorystore por red privada.
- Cloud NAT completo: `google_compute_router` + `google_compute_router_nat`.
- 3 reglas de firewall: `allow-internal` (10.20.0.0/16), `allow-iap-ssh` (rango fijo de IAP 35.235.240.0/20, nunca 0.0.0.0/0), `allow-lb-health-checks` (rangos oficiales de Google 130.211.0.0/22 y 35.191.0.0/16 → puerto 8080).
- Output nuevo `private_vpc_connection_id`, necesario para el fix de la carrera descrita en el punto 4.

### `modules/database`
- Password de la app generada con `random_password` (32 chars, charset restringido para no romper connection strings) y escrita en `google_secret_manager_secret_version` — nunca en texto plano ni en `.tfvars`.
- `database_flags`: `log_statement=ddl` (audit trail REG-GDPR-003) y `log_min_duration_statement=500` (detectar queries lentas sin loguear cada SELECT).
- CMEK (bonus) **no implementada**: se documentó inline por qué (Cloud SQL usa la clave gestionada por Google, que ya cumple NFR-SEC-001 con AES-256; activar CMEK exige crear la clave KMS *antes* de la instancia, no se puede añadir después).

### `modules/compute`
- `startup_probe` y `liveness_probe` contra `/healthz` en el contenedor Cloud Run.
- `vpc_access` conectado al connector del módulo network, con `egress = PRIVATE_RANGES_ONLY` (solo el tráfico a rangos privados pasa por el connector).
- Cadena HTTPS completa: certificado gestionado (`google_compute_managed_ssl_certificate`), `google_compute_ssl_policy` MODERN (NFR-SEC-002 TLS), proxy HTTPS, forwarding rule 443, y un segundo par proxy/forwarding rule HTTP→HTTPS redirect en el puerto 80.
- `google_artifact_registry_repository` (no existía ningún recurso que creara el repo Docker que `image_repo` asumía).
- **Bug real encontrado con `terraform plan`**: el bloque `cdn_policy` en el provider `google` 5.45 exige explícitamente `cache_key_policy` o `signed_url_cache_max_age_sec` — se añadió `cache_key_policy` con `include_host/protocol/query_string = true`.
- **Bug real encontrado con `terraform plan`**: el atributo `managed[0].status` no existe en `google_compute_managed_ssl_certificate` (es `managed[0].domain_status`, un mapa, y aun así falló por otro motivo de schema) — se simplificó el output a `managed_cert_id` y se documentó consultar el estado con `gcloud compute ssl-certificates describe`.

### `modules/iam`
- **Bug de seguridad real**: `allowed_audiences = ["sts.amazonaws.com"]` en el provider OIDC — audiencia de AWS STS, no de GCP. Se quitó para usar el default correcto (ver README, decisión #1).
- Rol añadido al SA de CI/CD: `roles/logging.logWriter` (el propio workflow necesita escribir logs).
- Se documentó explícitamente, rol por rol, por qué cada uno es necesario (principio de mínimo privilegio, nunca `owner`/`editor`).

## 3. Bug real de infraestructura descubierto en el primer `apply`

El primer `terraform apply` contra `acmeoms-platform` (43 recursos) falló en dos recursos reales:

```
Error: Error, failed to create instance because the network doesn't have at least 1 private
services connection.
  with module.database.google_sql_database_instance.main
Error: Unable to create instance. Enable private service access for the authorized network
  with module.database.google_redis_instance.cache
```

Causa: `google_service_networking_connection.private_vpc_connection` no había terminado de propagarse cuando Cloud SQL y Redis empezaron a crearse — Terraform no infiere esa dependencia automáticamente porque ninguno de los dos recursos *referencia* la conexión, solo el `network_id`. Se corrigió exponiendo `private_vpc_connection_id` como output del módulo `network`, pasándolo al módulo `database`, y añadiendo `depends_on = [var.private_vpc_connection_id]` en ambos recursos. Un segundo `apply` con solo los 10 recursos pendientes completó sin errores (Redis ~4m35s, Cloud SQL ~6m30s).

## 4. Dockerfile y stub de aplicación

- `app/`: servidor Node.js mínimo (sin dependencias) con `/healthz` — usado únicamente para poder construir una imagen real y probar Docker → Artifact Registry → Cloud Run → Ansible de punta a punta. No es la app OMS.
- **Bug real encontrado al construir la imagen**: con cero dependencias, `npm ci --omit=dev` no crea `node_modules/`, y el `COPY --from=deps /app/node_modules` de la segunda etapa fallaba con "not found". Se añadió `mkdir -p node_modules` tras el `npm ci`.
- Verificado: la imagen corre como usuario `oms` (no root) y `/healthz` responde 200.
- Labels OCI completados (`title`, `description`, `vendor`, `revision` y `created` parametrizados por `ARG` que inyecta el CI).

## 5. Ansible

- `deploy.yml`: healthcheck post-deploy real contra la URL pública del servicio (`ansible.builtin.uri` con retries), y bloque de notificación Slack dejado como `debug` formateado (sin webhook real disponible en este ejercicio).
- `rollback.yml`: lista las 2 últimas revisiones con `gcloud run revisions list --sort-by=~metadata.creationTimestamp`, valida que exista una N-1, y redirige el 100% del tráfico con `gcloud run services update-traffic --to-revisions`.
- `roles/oms_cloud_run`: se investigó la colección `google.cloud` 1.13.0 instalada (`ansible-galaxy collection install` + inspección de `plugins/modules/`) y se confirmó que **no existe** ningún módulo `gcp_run_service`/`gcp_cloudrun_*` — Cloud Run nunca tuvo soporte GA ahí. Se documentó explícitamente y se mantuvo `command` + `gcloud run deploy`, pero con idempotencia real basada en comparar la imagen actual contra la deseada, más un paso nuevo que espera a que la revisión esté `Ready` antes de mover tráfico.
- `group_vars/{staging,production}.yml`: `gcp_project` relleno con los IDs reales; `pagerduty_routing_key` de producción se dejó vacío a propósito (string vacía, no un placeholder falso) porque no hay integración PagerDuty real en este ejercicio.

## 6. CI/CD

`.github/workflows/ci-cd.yml` (no existía, se escribió desde cero):

- Job `quality` (matriz terraform/ansible/app): corre en cada push y PR a `main`, sin tocar GCP.
- Job `build`: solo en tags `v*`. `environment: staging`. Autentica por WIF contra el proyecto de staging, construye y publica la imagen por digest en el Artifact Registry de staging.
- Job `replicate-to-production`: `environment: production`, `needs: build`. Autentica por WIF contra producción, hace `docker pull` **por digest** desde el registry de staging (solo lectura) y `docker push` al registry de producción — **replica el mismo digest** sin reconstruir la imagen (dos proyectos aislados ⇒ dos registries, contenido idéntico).
- Jobs `deploy-staging` / `deploy-production`: ambos llaman a `ansible-playbook playbooks/deploy.yml` con el mismo `image_sha` que devolvió el job `build`. La protección de "requiere aprobación humana antes de producción" se apoya en la función nativa de GitHub Environments (`environment: production` + Required reviewers en la configuración del repo), no en lógica custom del workflow.
- `permissions: id-token: write` a nivel de workflow; cero secretos de tipo `GCP_SA_KEY_JSON` — todo son `vars` (IDs de proyecto, WIF provider, emails de SA), que no son sensibles.
- **Aislamiento de credenciales por Environment**: las 6 `vars` (`{STAGING,PRODUCTION}_{WIF_PROVIDER,CICD_SA,PROJECT_ID}`) están scoped por Environment en GitHub, no a nivel de repo — un job con `environment: production` nunca ve las vars de staging y viceversa. Esto obligó a partir en dos el job `build` original (que autenticaba primero como staging y luego como producción en el mismo job): el job de producción ya no puede tener credenciales de staging para hacer `pull` de la imagen. Se resolvió dándole al SA de CI/CD de producción `roles/artifactregistry.reader` (**solo lectura, un único sentido**) sobre el Artifact Registry de staging — `google_artifact_registry_repository_iam_member.production_reader` en `modules/compute/main.tf`, condicionado a `production_cicd_sa_email` (solo seteado en `staging.tfvars`). Aplicado con `terraform apply` real contra `acmeoms-platform`.

## 7. Bugs adicionales encontrados durante el despliegue y deploy reales (post-apply)

Tras el primer `apply` limpio, se hizo un ciclo completo real: build de imagen → push a Artifact Registry → `ansible-playbook deploy.yml` contra Cloud Run de verdad. Esto sacó a la luz bugs que ni `terraform plan` ni `ansible --syntax-check` pueden detectar, porque solo aparecen al ejecutar contra la API real:

1. **Cloud Run es privado por defecto — faltaba el invoker público.** El primer `curl` a la URL del servicio devolvió `403 Forbidden` de "Google Frontend" aunque los health/liveness probes internos de Cloud Run ya estaban en verde (contenedor sano). Causa: nunca se creó el binding IAM `roles/run.invoker` → `allUsers`. Se añadió `google_cloud_run_v2_service_iam_member.public_invoker` en `modules/compute/main.tf`. Se documentó explícitamente el trade-off de seguridad: la app es pública de cara a usuarios finales (un SaaS de pedidos), la protección real vive en el LB/WAF, no en IAM de Cloud Run.

2. **`/healthz` está reservado por el borde público de Google (`*.a.run.app`).** Después de arreglar el IAM, `/healthz` seguía devolviendo 404 — pero con la página de error genérica de `www.google.com` (el logo/robot de Google), no un 404 de Cloud Run ni de la app. Se probó exhaustivamente: `/`, `/foo`, `/health`, `/healthcheck` devuelven 200 (la app real, sin ninguna ruta que devuelva 404 en su código); solo la cadena exacta `/healthz` falla, de forma reproducible en la URL principal Y en la URL con tag de revisión. Conclusión: el Google Frontend que sirve el dominio público por defecto de Cloud Run intercepta esa ruta concreta antes de que llegue al contenedor. Los probes internos de `google_cloud_run_v2_service` (que sí usan `/healthz`) no se ven afectados porque no pasan por ese borde público — solo el tráfico de internet real. Se cambió el healthcheck externo de `ansible/playbooks/deploy.yml` para golpear `/` en vez de `{{ health_path }}`, dejando `/healthz` intacto como contrato interno de Cloud Run/LB.

3. **El `google_vpc_access_connector` generaba un `-/+ replace` fantasma en cada plan.** El recurso mezclaba escalado por instancias (`min/max_instances`) con el campo legacy `max_throughput`, que el provider por defecto fija en 300 sin recalcularlo a partir de las instancias — mientras que la API sí deriva el throughput real (~100 Mbps/instancia). Resultado: `terraform plan` veía sistemáticamente `max_throughput: 600 -> 300 # forces replacement` aunque nada hubiera cambiado de verdad. Se fijaron `min_throughput`/`max_throughput` explícitamente a partir de las mismas variables que ya controlan `min/max_instances`, eliminando el diff sin necesidad de recrear el conector (el valor real ya coincidía).

4. **`google_cloud_run_v2_service` necesitaba más campos en `ignore_changes`.** Con un deploy real de por medio, `terraform plan` intentaba revertir cada vez: el `image` (esperado, ya cubierto), el reparto de `traffic` (Ansible lo mueve con `--to-tags`), los `resources.limits` de cpu/memoria (Ansible los varía por entorno vía `group_vars/{env}.yml`, distintos a los que trae el módulo por defecto) y hasta `client`/`client_version` (metadatos que `gcloud` escribe solo en cada deploy) y `template.revision`. Sin ampliar `ignore_changes` a todo eso, la "idempotencia" de Terraform y la de Ansible se pisaban mutuamente — cada sistema deshacía lo que hizo el otro en su último `apply`/`deploy`.

5. **Casi se aplica un plan de producción contra el *state* de staging.** Al volver a `terraform plan -var-file=envs/production.tfvars` después de trabajar en el backend de staging, se me olvidó `terraform init -reconfigure` de vuelta al bucket de producción. El plan resultante mostraba renombrar TODOS los recursos de `oms-staging-*` a `oms-production-*` — es decir, intentaba destruir la infraestructura de staging para "convertirla" en la de producción. `lifecycle.prevent_destroy` en `google_sql_database_instance` cortó el `apply` en seco con un error explícito. Aquí es exactamente donde esa protección (pedida en la rúbrica) demostró su valor: sin ella, este habría sido un incidente real de pérdida de datos. Lección operativa añadida al README: verificar SIEMPRE con `cat .terraform/terraform.tfstate | grep bucket` (o el output de `terraform init`) a qué backend apunta la sesión actual antes de un `apply` contra producción.

6. **`image_repo` de Ansible no incluía el nombre de la imagen dentro del repositorio.** `group_vars/all.yml` construía `image_repo` como `.../PROJECT/REPO` cuando Artifact Registry necesita `.../PROJECT/REPO/IMAGE` — `gcloud run deploy` fallaba con `Image ... parsing failed`. Se corrigió a `.../oms/oms` (repo "oms", imagen "oms" dentro de ese repo).

7. **`docker push` falló con "Unauthenticated" pese a `gcloud auth configure-docker`.** La causa no fue de configuración sino de `PATH`: el binario `docker-credential-gcloud` vive en `google-cloud-sdk/bin`, y ese directorio no estaba en el `PATH` de la shell concreta donde corrió `docker push` (cada comando de esta sesión es una shell nueva). Docker, al no encontrar el helper, empujó la imagen sin credenciales. Se corrigió exportando el `PATH` en el mismo comando que ejecuta `docker push`.

Ambos entornos quedaron verificados end-to-end tras estos fixes: `terraform plan` limpio ("No changes") en staging y producción, y `ansible-playbook deploy.yml` idempotente (`changed=0` en la segunda ejecución) en ambos, con el **mismo digest de imagen** (`sha256:407bec51...`) desplegado en los dos.

También se probó `rollback.yml` de verdad contra staging: movió el 100% del tráfico a la revisión anterior (la imagen `hello` de bootstrap) correctamente. Al volver a correr `deploy.yml` con el mismo `image_sha` de antes del rollback, el role detectó que el `spec.template` ya declaraba esa imagen y se saltó el redeploy (`changed=0`) — pero **no restauró el tráfico**, porque `oms_cloud_run_current_image` compara el spec, no a qué revisión apunta el tráfico activo. Es una limitación real y conocida (no corregida): el role asume que "imagen correcta en el spec" implica "tráfico correcto", lo cual deja de ser cierto justo después de un rollback manual. Documentado aquí en vez de parcheado a última hora para no introducir una lógica de idempotencia más compleja sin poder probarla a fondo.

## 8. Pendiente / fuera de alcance de esta sesión

- El repo de GitHub aún no existe (`ljacques99/M2-4` es el nombre reservado en `github_repository` de las `tfvars`, a confirmar cuando se cree). Como el repo GitLab actual tiene `oms-platform/` como subcarpeta, hace falta decidir cómo se crea el repo GitHub para que `.github/workflows/` quede en su raíz (GitHub Actions no detecta workflows anidados).
- **Bug de `terraform validate` — encontrado y arreglado.** `terraform init -backend=false && terraform validate` (paso `quality` del workflow) fallaba con `Error: Missing required argument "bucket"` sobre el bloque `backend "gcs" {}` vacío. Investigado a fondo: el fallo es **dependiente de la versión de Terraform**, no universal — se reproduce con 1.15.0 (la instalada en el entorno local) pero **no** con 1.7.5, que es justo la versión que fija el workflow (`hashicorp/setup-terraform@v3`, `terraform_version: "1.7.5"`), confirmado descargando y ejecutando ambos binarios contra el mismo checkout. Es decir, el job `quality` de CI nunca estuvo realmente roto — pero dejarlo así era frágil: un bump futuro del pin de versión lo habría roto en silencio. Se arregló igualmente por robustez: `main.tf` ahora declara `backend "gcs" { bucket = "unconfigured" }` con un valor placeholder literal en vez de `{}` vacío. Satisface el chequeo de esquema de `validate` bajo `-backend=false` en ambas versiones probadas, y sigue siendo sobrescrito limpiamente por el `-backend-config="bucket=..."` real en `init` (verificado con un `init` real contra el bucket de staging con el placeholder presente).
- Bonus no implementados: multi-region DR, Cloud CDN con políticas finas más allá de lo básico, bastion VM con Datadog, CMEK propia, runbook de expand-and-contract. Se priorizó el 100% de la rúbrica base con infraestructura real y verificada antes que sumar bonus sobre una base sin probar.
