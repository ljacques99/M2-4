# ── Módulo: NETWORK ────────────────────────────────────────────────
# Provisiona la VPC privada con dos subredes en zonas distintas (NFR-AVAIL-001).
# Sin IPs públicas en compute: salida a internet vía Cloud NAT.

variable "project_id" { type = string }
variable "region"     { type = string }
variable "env"        { type = string }
variable "vpc_cidr"   { type = string }
variable "labels"     { type = map(string) }

# ─── VPC ──────────────────────────────────────────────────────────
resource "google_compute_network" "main" {
  name                    = "oms-${var.env}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# ─── Subred privada para Cloud SQL / Memorystore / Cloud Run ──
# TODO(alumno): crea dos subredes (al menos en dos zonas) y declara
# secondary_ip_range si quieres correr GKE en algún momento.
resource "google_compute_subnetwork" "private" {
  name                     = "oms-${var.env}-private"
  ip_cidr_range            = cidrsubnet(var.vpc_cidr, 4, 0)  # /20 del /16
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true   # acceso a APIs de Google sin salir a internet
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
# TODO(alumno): crea un router y un Cloud NAT. Pista:
#   google_compute_router  + google_compute_router_nat
#   - nat_ip_allocate_option = "AUTO_ONLY"
#   - source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

# ─── Firewall: deny-all por defecto + reglas explícitas ───────────
# TODO(alumno): define al menos:
#   - allow-internal: tráfico dentro de la VPC (10.20.0.0/16)
#   - allow-iap-ssh:  SSH desde IAP a VMs con tag "iap-ssh" (bonus bastion)
#   - allow-lb-health-checks: GFE → puerto 8080 con source-ranges de health checks

# ─── Outputs ──────────────────────────────────────────────────────
output "network_id"        { value = google_compute_network.main.id }
output "network_self_link" { value = google_compute_network.main.self_link }
output "private_subnet_id" { value = google_compute_subnetwork.private.id }
output "private_subnet_cidr" { value = google_compute_subnetwork.private.ip_cidr_range }
