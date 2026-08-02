output "vault_url" {
  description = "URL to enter in the Bitwarden clients as the self-hosted server."
  value       = "https://${var.domain}"
}

output "static_ip" {
  description = "Point a DNS A record for var.domain at this address BEFORE first boot, or the ACME challenge fails."
  value       = google_compute_address.vault.address
}

output "dns_record_required" {
  description = "The DNS record that must exist."
  value       = "${var.domain}. IN A ${google_compute_address.vault.address}"
}

output "ssh_command" {
  description = "SSH via IAP; port 22 is not exposed to the internet."
  value       = "gcloud compute ssh vaultwarden --project ${var.project_id} --zone ${var.zone} --tunnel-through-iap"
}

output "backup_bucket" {
  description = "GCS bucket holding nightly backup archives."
  value       = google_storage_bucket.backups.name
}

output "admin_token_command" {
  description = "Read the admin page token."
  value       = var.enable_admin_page ? "gcloud secrets versions access latest --secret=${google_secret_manager_secret.admin_token[0].secret_id} --project=${var.project_id}" : "admin page disabled"
}

output "logs_command" {
  description = "Tail the Vaultwarden container logs."
  value       = "gcloud compute ssh vaultwarden --project ${var.project_id} --zone ${var.zone} --tunnel-through-iap --command 'sudo docker logs -f vaultwarden'"
}
