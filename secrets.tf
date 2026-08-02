resource "google_secret_manager_secret" "admin_token" {
  count = var.enable_admin_page ? 1 : 0

  project   = local.project_id
  secret_id = "vaultwarden-admin-token"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.apis]
}

# Fallback only. Current Vaultwarden expects an Argon2 PHC string; a raw token
# still works but is stored unhashed on the server. Prefer setting
# admin_token_hash — see the README for the hashing command.
resource "random_password" "admin_token" {
  count   = var.enable_admin_page && var.admin_token_hash == "" ? 1 : 0
  length  = 48
  special = false
}

resource "google_secret_manager_secret_version" "admin_token" {
  count = var.enable_admin_page ? 1 : 0

  secret      = google_secret_manager_secret.admin_token[0].id
  secret_data = var.admin_token_hash != "" ? var.admin_token_hash : random_password.admin_token[0].result
}

resource "google_secret_manager_secret_iam_member" "vault_accessor" {
  count = var.enable_admin_page ? 1 : 0

  project   = local.project_id
  secret_id = google_secret_manager_secret.admin_token[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vault.email}"
}
