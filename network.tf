resource "google_compute_network" "vault" {
  project                 = local.project_id
  name                    = "vaultwarden-vpc"
  auto_create_subnetworks = false
  description             = "Dedicated VPC for Vaultwarden; avoids the permissive default network rules."

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "vault" {
  project       = local.project_id
  name          = "vaultwarden-subnet"
  region        = var.region
  network       = google_compute_network.vault.id
  ip_cidr_range = "10.10.0.0/24"

  # Lets the VM reach Google APIs (Secret Manager, GCS) over internal routing.
  private_ip_google_access = true
}

# Static regional external IP. A regional IP attached to a running instance is
# within free usage; an IP left reserved but unattached is billed. Do not
# `terraform destroy` the instance and leave this behind indefinitely.
resource "google_compute_address" "vault" {
  project      = local.project_id
  name         = "vaultwarden-ip"
  region       = var.region
  address_type = "EXTERNAL"

  depends_on = [google_project_service.apis]
}

# --- Firewall -----------------------------------------------------------------
# Ingress is deny-by-default on a custom VPC. Only what is opened below applies.

resource "google_compute_firewall" "allow_http_https" {
  project     = local.project_id
  name        = "vaultwarden-allow-web"
  network     = google_compute_network.vault.name
  description = "Public HTTPS for Bitwarden clients; HTTP is needed for the ACME challenge and redirects to HTTPS."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["vaultwarden"]
}

# SSH is NOT open to the internet. IAP TCP forwarding brokers the connection, so
# access is governed by IAM rather than by source IP.
#   gcloud compute ssh vaultwarden --tunnel-through-iap --zone <zone>
resource "google_compute_firewall" "allow_iap_ssh" {
  project     = local.project_id
  name        = "vaultwarden-allow-iap-ssh"
  network     = google_compute_network.vault.name
  description = "SSH only from Google's IAP forwarding range."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Fixed, Google-owned range for IAP TCP forwarding.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["vaultwarden"]
}

resource "google_compute_firewall" "allow_health_checks" {
  project     = local.project_id
  name        = "vaultwarden-allow-health-checks"
  network     = google_compute_network.vault.name
  description = "Google health-check probe ranges."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["vaultwarden"]
}

# The only port this configuration newly exposes. WireGuard is silent by design:
# a packet that does not carry a valid key exchange gets no response at all, so
# the listener is not discoverable by scanning the way a TCP service is.
resource "google_compute_firewall" "allow_wireguard" {
  project     = local.project_id
  name        = "vaultwarden-allow-wireguard"
  network     = google_compute_network.vault.name
  description = "WireGuard VPN listener. UDP only; unauthenticated probes are dropped by WireGuard itself."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "udp"
    ports    = [tostring(var.wireguard_port)]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["vaultwarden"]
}

resource "google_compute_firewall" "deny_all_ingress" {
  project     = local.project_id
  name        = "vaultwarden-deny-all-ingress"
  network     = google_compute_network.vault.name
  description = "Explicit catch-all deny, logged, so unexpected probes are visible."
  direction   = "INGRESS"
  priority    = 65535

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
