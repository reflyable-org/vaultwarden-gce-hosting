locals {
  # When Terraform creates the project, everything else must depend on that
  # resource rather than the raw var, so ordering is correct on a cold apply.
  project_id = var.create_project ? google_project.this[0].project_id : var.project_id
}

resource "google_project" "this" {
  count = var.create_project ? 1 : 0

  name            = var.project_id
  project_id      = var.project_id
  billing_account = var.billing_account
  org_id          = var.org_id != "" ? var.org_id : null
  folder_id       = var.folder_id != "" ? var.folder_id : null

  # Avoid the default network; this config builds its own VPC with a firewall
  # that does not expose SSH to the internet.
  auto_create_network = false

  lifecycle {
    precondition {
      condition     = var.billing_account != ""
      error_message = "billing_account is required when create_project = true."
    }
    precondition {
      condition     = !(var.org_id != "" && var.folder_id != "")
      error_message = "Set at most one of org_id / folder_id."
    }
  }
}

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iap.googleapis.com",
    "oslogin.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project = local.project_id
  service = each.value

  # Leave APIs enabled on destroy; disabling them can break unrelated resources
  # and they cost nothing.
  disable_on_destroy = false
}

resource "google_project_service" "billingbudgets" {
  count = var.enable_budget_alert ? 1 : 0

  project            = local.project_id
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}
