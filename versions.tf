terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State lives locally on first apply because the state bucket would otherwise
  # have to exist inside the project this config creates. Once the project and
  # bucket exist, uncomment this and run `terraform init -migrate-state`.
  #
  # backend "gcs" {
  #   bucket = "PLACEHOLDER-tf-state"
  #   prefix = "vaultwarden"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # The Billing Budgets API bills quota to the calling project rather than the
  # target project. Without this, user ADC falls back to Google's shared default
  # project and the budget resource fails with SERVICE_DISABLED.
  billing_project       = var.project_id
  user_project_override = true
}
