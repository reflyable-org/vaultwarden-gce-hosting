resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Backups. This protects against accidental deletion,
# a corrupted vault, or losing the zone. PD snapshots are NOT free, so archives
# go to a regional bucket inside the 5GB-month always-free allowance.
#
# Regional (var.region), NOT multi-region "US" — multi-region is not free tier.
resource "google_storage_bucket" "backups" {
  project  = local.project_id
  name     = "${var.project_id}-vw-backups-${random_id.bucket_suffix.hex}"
  location = upper(var.region)

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  storage_class               = "STANDARD"

  versioning {
    enabled = true
  }

  # Without this, versioning would accumulate old archives indefinitely and
  # eventually push the bucket past the free tier.
  lifecycle_rule {
    condition {
      age        = var.backup_retention_days
      with_state = "ANY"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

# createObject only — the VM can write new backups but cannot read or delete
# existing ones. If the VM is compromised, prior backups survive.
resource "google_storage_bucket_iam_member" "vault_backup_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.vault.email}"
}
