# ── Módulo: NETWORK ────────────────────────────────────────────────
# Provisiona la VPC privada con dos subredes en zonas distintas (NFR-AVAIL-001).
# Sin IPs públicas en compute: salida a internet vía Cloud NAT.

variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "vpc_cidr" { type = string }
variable "labels" { type = map(string) }

# ─── VPC ──────────────────────────────────────────────────────────
resource "google_compute_network" "main" {
  name                    = "oms-${var.env}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# ─── Subredes privadas ─────────────────────────────────────────────
# Nota GCP: a diferencia de AWS, una subred es un recurso REGIONAL, no zonal —
# cada subred ya reparte tráfico entre las zonas disponibles de la región
# (europe-west3-a/b/c), que es justamente lo que le da su alta disponibilidad
# multi-zona a Cloud SQL REGIONAL y a Redis STANDARD_HA (NFR-AVAIL-001).
# Creamos dos subredes con propósitos distintos en vez de forzar un split
# artificial por zona:
#   - private: workloads principales (Cloud Run VPC connector, futuras VMs)
#   - gke:     reservada con rangos secundarios para el bonus GKE Autopilot
resource "google_compute_subnetwork" "private" {
  name                     = "oms-${var.env}-private"
  ip_cidr_range            = cidrsubnet(var.vpc_cidr, 4, 0) # /20 del /16
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true # acceso a APIs de Google sin salir a internet

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "gke" {
  name                     = "oms-${var.env}-gke"
  ip_cidr_range            = cidrsubnet(var.vpc_cidr, 4, 1) # /20 bloque 1: 10.20.16.0/20
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = cidrsubnet(var.vpc_cidr, 4, 3) # /20 bloque 3: 10.20.48.0/20
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = cidrsubnet(var.vpc_cidr, 4, 4) # /20 bloque 4: 10.20.64.0/20
  }
}

# ─── Subred dedicada al VPC Access Connector (Cloud Run → Redis) ──
# Debe ser /28 y exclusiva para el conector (requisito de Serverless VPC Access).
# Se reserva dentro del bloque 2 (10.20.32.0/20), que queda libre de las demás subredes.
resource "google_compute_subnetwork" "connector" {
  name                     = "oms-${var.env}-connector"
  ip_cidr_range            = cidrsubnet(cidrsubnet(var.vpc_cidr, 4, 2), 8, 0) # 10.20.32.0/28
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true
}

# ─── VPC Access Connector: Cloud Run (serverless) → red privada (Redis) ──
locals {
  connector_min_instances = 2
  connector_max_instances = var.env == "production" ? 6 : 3
}

resource "google_vpc_access_connector" "connector" {
  provider = google-beta
  name     = "oms-${var.env}-vpc-conn"
  region   = var.region
  subnet {
    name = google_compute_subnetwork.connector.name
  }
  machine_type  = "e2-micro"
  min_instances = local.connector_min_instances
  max_instances = local.connector_max_instances

  # El provider tiene un default propio para min/max_throughput (200/300)
  # que NO se recalcula solo a partir de min/max_instances — si no se fijan
  # aquí, la API sí deriva el throughput real de las instancias (100 Mbps
  # aprox. por instancia) y cada `terraform plan` posterior ve un diff falso
  # entre el default del provider y el valor real, forzando un replace.
  # Comprobado con un apply real: sin esto, min_throughput/max_throughput
  # generaban -/+ replace en cada plan.
  min_throughput = local.connector_min_instances * 100
  max_throughput = local.connector_max_instances * 100
}

# ─── Private Service Connect para Cloud SQL ───────────────────
# Cloud SQL necesita un rango privado reservado para crear su endpoint.
resource "google_compute_global_address" "private_service_range" {
  name          = "oms-${var.env}-sql-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

# ─── Cloud NAT para salida a internet (instancias sin IP pública) ──
resource "google_compute_router" "main" {
  name    = "oms-${var.env}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "oms-${var.env}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─── Firewall: deny-all implícito (default de la VPC) + reglas explícitas ──
resource "google_compute_firewall" "allow_internal" {
  name          = "oms-${var.env}-allow-internal"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [var.vpc_cidr]
  priority      = 1000

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
}

# SSH únicamente a través de Identity-Aware Proxy (nunca 0.0.0.0/0 directo).
# Rango fijo de Google para el proxy IAP: 35.235.240.0/20.
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "oms-${var.env}-allow-iap-ssh"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iap-ssh"]
  priority      = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# El Load Balancer (Google Front End) necesita alcanzar el puerto de la app
# para sus health checks. Rangos oficiales de GFE/health checks de Google.
resource "google_compute_firewall" "allow_lb_health_checks" {
  name          = "oms-${var.env}-allow-lb-health-checks"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  priority      = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

# ─── Outputs ──────────────────────────────────────────────────────
output "network_id" { value = google_compute_network.main.id }
output "network_self_link" { value = google_compute_network.main.self_link }
output "private_subnet_id" { value = google_compute_subnetwork.private.id }
output "private_subnet_cidr" { value = google_compute_subnetwork.private.ip_cidr_range }
output "vpc_connector_id" { value = google_vpc_access_connector.connector.id }
output "private_vpc_connection_id" {
  description = "ID de la conexión de Private Service Access. Cloud SQL y Memorystore deben esperar a que exista (depends_on) o su creación falla en carrera."
  value       = google_service_networking_connection.private_vpc_connection.id
}
