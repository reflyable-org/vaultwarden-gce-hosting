# The single most important guardrail in this config. Everything here is
# designed to sit inside the always-free tier, but a stray region, disk type or
# forgotten reserved IP will quietly start billing. This makes that loud.
resource "google_billing_budget" "vault" {
  count = var.enable_budget_alert ? 1 : 0

  billing_account = var.billing_account
  display_name    = "Vaultwarden free-tier guard"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      # MUST match the billing account's own currency (AUD here) — the API
      # rejects any mismatch with a bare "invalid argument". Derived rather
      # than hardcoded so this keeps working on a different billing account.
      currency_code = data.google_billing_account.this.currency_code
      units         = tostring(var.budget_amount)
    }
  }

  # Fire at 50% and 100% of actual spend, and on forecast, so there is warning
  # before the threshold is actually crossed.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  dynamic "all_updates_rule" {
    for_each = length(var.budget_alert_emails) > 0 ? [1] : []
    content {
      monitoring_notification_channels = [
        for c in google_monitoring_notification_channel.budget : c.id
      ]
      disable_default_iam_recipients = false
    }
  }

  lifecycle {
    precondition {
      condition     = var.billing_account != ""
      error_message = "billing_account is required when enable_budget_alert = true."
    }
  }

  depends_on = [google_project_service.billingbudgets]
}

resource "google_monitoring_notification_channel" "budget" {
  for_each = var.enable_budget_alert ? toset(var.budget_alert_emails) : toset([])

  project      = local.project_id
  display_name = "Vaultwarden budget alert: ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.apis]
}

data "google_project" "this" {
  project_id = local.project_id

  depends_on = [google_project.this]
}

# The billing account's currency is fixed at creation and cannot be changed.
# Budgets must be denominated in it.
data "google_billing_account" "this" {
  billing_account = var.billing_account
}
