locals {
  cloud_init = templatefile("${path.module}/files/cloud-init.yaml", {
    domain            = var.domain
    acme_email        = var.acme_email
    project_id        = local.project_id
    vaultwarden_image = var.vaultwarden_image
    caddy_image       = var.caddy_image
    signups_allowed   = var.signups_allowed ? "true" : "false"
    enable_admin_page = var.enable_admin_page ? "true" : "false"
    admin_secret_id   = var.enable_admin_page ? google_secret_manager_secret.admin_token[0].secret_id : ""
    backup_bucket     = google_storage_bucket.backups.name
    backup_schedule   = var.backup_schedule
  })
}
