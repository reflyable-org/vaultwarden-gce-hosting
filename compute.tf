data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_service_account" "vault" {
  project      = local.project_id
  account_id   = "vaultwarden-vm"
  display_name = "Vaultwarden VM"
  description  = "Runtime identity for the Vaultwarden instance."

  depends_on = [google_project_service.apis]
}

# Least privilege: write-only on the backup bucket (see storage.tf), read on the
# admin token secret (secrets.tf), plus logging/monitoring. No project-level
# roles are granted.
resource "google_project_iam_member" "vault_logging" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vault.email}"
}

resource "google_project_iam_member" "vault_monitoring" {
  project = local.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.vault.email}"
}

# Vault data lives on its own disk so the VM can be rebuilt or the boot disk
# replaced without risking the vault. prevent_destroy makes an accidental
# `terraform destroy` fail rather than delete the vault.
resource "google_compute_disk" "data" {
  project = local.project_id
  name    = "vaultwarden-data"
  type    = "pd-standard"
  zone    = var.zone
  size    = var.data_disk_gb

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.boot_disk_gb + var.data_disk_gb <= 30
      error_message = "boot_disk_gb + data_disk_gb must be <= 30; the always-free pd-standard allowance is 30GB total across the project."
    }
  }
}

resource "google_compute_instance" "vault" {
  project      = local.project_id
  name         = "vaultwarden"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["vaultwarden"]

  # Required so Terraform can change machine type / metadata in place.
  allow_stopping_for_update = true

  # WireGuard NATs tunnel traffic out through this NIC. Without this, GCP's
  # network drops any packet whose source address is not the instance's own —
  # which is every packet arriving from a VPN peer. Changing it replaces the
  # instance; the data disk is unaffected (prevent_destroy + ignore_changes).
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = var.boot_disk_gb
      type  = "pd-standard"
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "vaultwarden-data"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.vault.id

    # Ephemeral NAT would change on every restart and break DNS; pin the static IP.
    access_config {
      nat_ip = google_compute_address.vault.address
    }
  }

  service_account {
    email = google_service_account.vault.email
    # cloud-platform is scoped down by the IAM roles above; this is the
    # documented pattern for COS instances using gcloud on-box.
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # COS reads cloud-init from user-data.
    user-data = local.cloud_init

    # Runtime settings, read by fetch-runtime-config.sh on every service start.
    # Changing these takes effect with `terraform apply` followed by
    # `systemctl restart vaultwarden` — no VM rebuild. cloud-init runs only on
    # first boot, so values baked into the unit file would otherwise be stale.
    vw-domain          = "https://${var.domain}"
    vw-signups-allowed = var.signups_allowed ? "true" : "false"

    # Same two-tier pattern for WireGuard: read by wg-runtime-config.sh on every
    # start, so the port or tunnel subnet can change with
    # `terraform apply` + `systemctl restart wireguard`, no rebuild.
    wg-port   = tostring(var.wireguard_port)
    wg-subnet = var.wireguard_subnet

    # Block project-wide SSH keys; access is via IAP + OS Login only.
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"

    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # e2-micro is not preemptible-eligible for free-tier purposes; keep standard.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  # Replacing the instance must never take the data disk with it.
  lifecycle {
    ignore_changes = [attached_disk]
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.admin_token,
  ]
}
