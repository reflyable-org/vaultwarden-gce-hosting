variable "project_id" {
  description = "GCP project ID hosting Vaultwarden."
  type        = string
}

variable "create_project" {
  description = <<-EOT
    Whether Terraform should create the project. If false, the project must
    already exist and have billing enabled. If true, billing_account and one of
    org_id/folder_id are required.
  EOT
  type        = bool
  default     = false
}

variable "billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). Required if create_project or the budget alert is enabled."
  type        = string
  default     = ""
}

variable "org_id" {
  description = "Organization ID to create the project under. Mutually exclusive with folder_id."
  type        = string
  default     = ""
}

variable "folder_id" {
  description = "Folder ID to create the project under. Mutually exclusive with org_id."
  type        = string
  default     = ""
}

variable "domain" {
  description = <<-EOT
    Fully-qualified domain for the vault, e.g. vault.example.com. An A record
    must point at the static IP this config creates BEFORE the first boot, or
    Caddy's Let's Encrypt challenge will fail.
  EOT
  type        = string
}

variable "acme_email" {
  description = "Contact email for Let's Encrypt expiry notices."
  type        = string
}

# --- Free-tier critical -------------------------------------------------------
# GCP's always-free e2-micro is limited to us-west1, us-central1 and us-east1.
# Any other region bills. Validation below makes a costly typo fail at plan time.

variable "region" {
  description = "Region. Must be a free-tier-eligible region for e2-micro."
  type        = string
  default     = "us-west1"

  validation {
    condition     = contains(["us-west1", "us-central1", "us-east1"], var.region)
    error_message = "Free-tier e2-micro is only available in us-west1, us-central1 or us-east1."
  }
}

variable "zone" {
  description = "Zone within the region."
  type        = string
  default     = "us-west1-a"
}

variable "machine_type" {
  description = "Machine type. e2-micro is the only always-free option."
  type        = string
  default     = "e2-micro"

  validation {
    condition     = var.machine_type == "e2-micro"
    error_message = "Only e2-micro is covered by the always-free tier. Change deliberately if you accept the cost."
  }
}

# The 30GB always-free allowance is the TOTAL of all pd-standard disks in the
# project, not per disk. boot + data must sum to <= 30.
variable "boot_disk_gb" {
  description = "Boot disk size in GB (pd-standard)."
  type        = number
  default     = 20
}

variable "data_disk_gb" {
  description = "Vault data disk size in GB (pd-standard). Kept separate so the VM can be rebuilt without touching vault data."
  type        = number
  default     = 10
}

variable "vaultwarden_image" {
  description = <<-EOT
    Vaultwarden container image. Pinned to an explicit version tag rather than a
    floating one such as :latest, so a rebuild can't silently pull a different
    server version. Update deliberately after reading the upstream release
    notes. Pin by @sha256 digest instead if you want byte-exact reproducibility.
  EOT
  type        = string
  default     = "docker.io/vaultwarden/server:1.37.1-alpine"
}

variable "caddy_image" {
  description = "Caddy image used for automatic HTTPS."
  type        = string
  default     = "docker.io/library/caddy:2-alpine"
}

variable "wireguard_image" {
  description = <<-EOT
    WireGuard container image. Runs with --network host so it can own a real wg0
    in the host network namespace; it does NOT join vaultwarden-net and has no
    path to the Vaultwarden container. Falls back to userspace boringtun if the
    kernel module is absent, which matters because Secure Boot is enabled and
    would block an out-of-tree module build.
  EOT
  type        = string
  default     = "docker.io/linuxserver/wireguard:1.0.20250521"
}

variable "wireguard_port" {
  description = "UDP port for the WireGuard listener. The only port this config newly exposes."
  type        = number
  default     = 51820

  validation {
    condition     = var.wireguard_port > 1024 && var.wireguard_port < 65536
    error_message = "wireguard_port must be an unprivileged port between 1025 and 65535."
  }
}

variable "wireguard_subnet" {
  description = <<-EOT
    CIDR for the VPN tunnel itself. The server takes the first host address
    (e.g. 10.8.0.1) and peers are allocated upward from there. Must not overlap
    the VPC subnet 10.10.0.0/24 — an overlap silently blackholes the tunnel
    rather than producing an error.
  EOT
  type        = string
  default     = "10.8.0.0/24"

  validation {
    condition     = can(cidrhost(var.wireguard_subnet, 1))
    error_message = "wireguard_subnet must be a valid IPv4 CIDR, e.g. 10.8.0.0/24."
  }

  # Two CIDRs overlap iff their network addresses agree under the shorter of the
  # two masks. Comparing at that width covers either range containing the other,
  # regardless of which prefix is longer.
  validation {
    condition = (
      cidrhost("${cidrhost(var.wireguard_subnet, 0)}/${min(tonumber(split("/", var.wireguard_subnet)[1]), 24)}", 0)
      !=
      cidrhost("10.10.0.0/${min(tonumber(split("/", var.wireguard_subnet)[1]), 24)}", 0)
    )
    error_message = "wireguard_subnet must not overlap the VPC subnet 10.10.0.0/24."
  }
}

variable "signups_allowed" {
  description = <<-EOT
    Leave false. Set true only long enough to register your single account via
    the web vault, then set back to false and re-apply. An internet-facing
    Vaultwarden with signups open lets anyone create an account.
  EOT
  type        = bool
  default     = false
}

variable "enable_admin_page" {
  description = "Expose /admin, protected by an Argon2-hashed ADMIN_TOKEN in Secret Manager."
  type        = bool
  default     = true
}

variable "admin_token_hash" {
  description = <<-EOT
    Argon2 PHC string for the admin page, e.g. '$argon2id$v=19$m=65540,...'.
    Generate with:
      docker run --rm -it docker.io/vaultwarden/server:1.37.1-alpine /vaultwarden hash
    A raw (unhashed) value is rejected by current Vaultwarden. Leave empty to
    have Terraform generate a random raw token instead (less secure at rest).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_retention_days" {
  description = "Days to keep backup archives in GCS. Keeps the bucket inside the 5GB free tier."
  type        = number
  default     = 30
}

variable "backup_schedule" {
  description = "systemd OnCalendar expression for the nightly backup timer."
  type        = string
  default     = "02:30"
}

variable "budget_amount" {
  description = <<-EOT
    Budget alert threshold, denominated in the billing account's own currency
    (read automatically — the Budgets API rejects any other currency). The only
    real safety net against a misconfiguration quietly accruing cost.
  EOT
  type        = number
  default     = 1
}

variable "enable_budget_alert" {
  description = "Create a billing budget. Requires billing_account and the billingbudgets API."
  type        = bool
  default     = true
}

variable "budget_alert_emails" {
  description = "Email addresses to notify on budget threshold breach. Empty falls back to billing account admins."
  type        = list(string)
  default     = []
}
