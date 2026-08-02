# Setup — from nothing to a working vault

End-to-end deployment of a self-hosted Vaultwarden on GCP's always-free tier,
starting from no GCP project at all.

Roughly 30-40 minutes, most of it waiting on GCP.

**Cost:** $0/month within the free tier. The only reliable cost is a domain
(~$10/yr) if you choose one over the free sslip.io option in step 5.

---

## Before you start

Install and authenticate the two required tools:

```bash
# macOS
brew install terraform
brew install --cask google-cloud-sdk

terraform version    # >= 1.5
gcloud version
```

```bash
gcloud auth login
gcloud auth application-default login
```

Both logins are needed: the first is for the `gcloud` CLI, the second issues the
Application Default Credentials that Terraform uses.

---

## 1. Create the GCP project

Pick a globally-unique project ID (lowercase, digits, hyphens):

```bash
export PROJECT_ID="my-vaultwarden-1234"

gcloud projects create "$PROJECT_ID"
gcloud config set project "$PROJECT_ID"
```

A Firebase-created project works too — Firebase projects are ordinary GCP
projects underneath.

Verify:

```bash
gcloud projects describe "$PROJECT_ID"     # lifecycleState: ACTIVE
```

---

## 2. Enable billing

**This is mandatory even though everything here is free.** The always-free tier
requires an attached, open billing account; it simply doesn't charge for
in-allowance usage. Compute Engine cannot be enabled without it.

```bash
gcloud billing accounts list
```

```
ACCOUNT_ID            NAME                  OPEN
XXXXXX-XXXXXX-XXXXXX  My Billing Account    True
```

If the list is empty, create one at
<https://console.cloud.google.com/billing> (needs a credit card; it is not
charged for free-tier usage).

```bash
export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
```

Verify — this must print `billingEnabled: true`:

```bash
gcloud billing projects describe "$PROJECT_ID" --billing-project="$PROJECT_ID"
```

> **Note your billing account's currency.** Run
> `gcloud billing accounts describe "$BILLING_ACCOUNT"` and look at
> `currencyCode`. Terraform reads this automatically for the budget alert, but
> it's worth knowing: the Budgets API rejects a currency mismatch with an
> unhelpful `invalid argument`.

---

## 3. Set the ADC quota project

Without this, the Billing Budgets API call fails with `SERVICE_DISABLED`
against a shared Google-owned project, because it bills quota to the *calling*
project rather than the target one:

```bash
gcloud auth application-default set-quota-project "$PROJECT_ID"
```

---

## 4. Configure Terraform

```bash
cd /path/to/this/repo
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
project_id      = "my-vaultwarden-1234"
billing_account = "XXXXXX-XXXXXX-XXXXXX"
acme_email      = "you@example.com"

domain = "PLACEHOLDER"   # filled in at step 5

region = "us-west1"   # must be us-west1 / us-central1 / us-east1
zone   = "us-west1-a"

boot_disk_gb = 20        # boot + data must total <= 30
data_disk_gb = 10

signups_allowed   = false
enable_admin_page = true

budget_alert_emails = ["you@example.com"]
```

---

## 5. Reserve the IP and choose a domain

HTTPS is not optional — Bitwarden clients refuse plain HTTP and WebAuthn is
origin-bound. Caddy obtains a Let's Encrypt certificate automatically, but the
domain must resolve to the VM *before* it boots.

Reserve the static IP first:

```bash
terraform init
terraform apply -target=google_project_service.apis -auto-approve
terraform apply -target=google_compute_address.vault -auto-approve
terraform output -raw static_ip
```

### Option A — sslip.io (free, no DNS)

`sslip.io` resolves `<dashed-ip>.sslip.io` to that IP automatically. For a
static IP of `203.0.113.10` the hostname is `203-0-113-10.sslip.io`.

```hcl
domain = "203-0-113-10.sslip.io"    # substitute your own IP
```

Confirm it resolves before continuing:

```bash
dig +short 203-0-113-10.sslip.io    # must print your static IP
```

Trade-off: the hostname is derived from the IP, so if the IP ever changes you
must update `domain` and re-point every client.

### Option B — your own domain (~$10/yr, portable)

Set `domain` to e.g. `vault.example.com`, then create an A record at your
registrar pointing to the static IP. Wait for it to resolve before step 6.

**A Firebase Hosting domain (`*.web.app`) will not work** — its DNS is Google's,
so no A record can point at your VM, and it is HSTS-preloaded and pinned to
Google certificates.

---

## 6. Generate the admin token

The `/admin` page is protected by an Argon2id hash. Skipping this leaves a
random plain-text token, which Vaultwarden warns about on every start.

```bash
docker run --rm -it docker.io/vaultwarden/server:1.37.1-alpine \
  /vaultwarden hash --preset owasp
```

Enter a strong random password twice. **Save the password you typed** — that is
what you enter at `/admin`. Only the hash goes in Terraform.

No Docker locally? Generate the hash with Python using the same OWASP
parameters:

```bash
pip3 install argon2-cffi
python3 -c "
import argon2, secrets
tok = secrets.token_urlsafe(36)
ph  = argon2.PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1,
                            hash_len=32, salt_len=16)
print('RAW TOKEN (save this):', tok)
print('HASH (put in tfvars):', ph.hash(tok))
"
```

> The container command needs an interactive TTY. Over `gcloud compute ssh` it
> panics with `No such device or address` — run it locally.

Add the hash to `terraform.tfvars` with **double quotes and no escaping**:

```hcl
admin_token_hash = "$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHQ$aGFzaGhhc2hoYXNo"
```

`.tfvars` values are literal. Writing `$$` stores the doubled characters
verbatim and the token will never validate.

---

## 7. Deploy

```bash
terraform apply
```

Roughly 3-5 minutes: API enablement, VM creation, disk format, image pulls, and
certificate issuance.

Wait for the service, then confirm HTTPS and the certificate:

```bash
until curl -sf -o /dev/null https://$(terraform output -raw vault_url | sed 's|https://||')/alive; do
  echo "waiting..."; sleep 15
done
echo "up"

curl -sS -o /dev/null -w "http=%{http_code} tls=%{ssl_verify_result}\n" \
  "$(terraform output -raw vault_url)/alive"
```

`http=200 tls=0` means serving correctly with a valid certificate. If TLS fails,
DNS almost certainly wasn't resolving at boot — fix DNS, then
`gcloud compute ssh vaultwarden --tunnel-through-iap --zone <zone> --command 'sudo systemctl restart caddy'`.

---

## 8. Register your account

The server ships with registration closed so a public URL can't be used by
strangers. Open it just long enough to create your account.

```bash
sed -i '' 's/signups_allowed = false/signups_allowed = true/' terraform.tfvars
terraform apply -auto-approve

gcloud compute ssh vaultwarden --project "$PROJECT_ID" --zone us-west1-a \
  --tunnel-through-iap --command 'sudo systemctl restart vaultwarden'
```

> The restart is required. `terraform apply` updates instance metadata, but the
> running container only re-reads it on service start.

Confirm registration is open:

```bash
curl -sS -o /dev/null -w "http=%{http_code}\n" -X POST \
  "$(terraform output -raw vault_url)/identity/accounts/register/send-verification-email" \
  -H 'Content-Type: application/json' \
  -d '{"email":"probe@example.com","name":null,"receiveMarketingEmails":false}'
```

`http=200` means open. Now visit your vault URL in a browser, choose **Create
account**, and register.

**Your master password cannot be recovered.** It is the encryption key for the
entire vault — there is no reset. Store it somewhere safe before continuing.

Then close registration again — **do not skip this**:

```bash
sed -i '' 's/signups_allowed = true/signups_allowed = false/' terraform.tfvars
terraform apply -auto-approve

gcloud compute ssh vaultwarden --project "$PROJECT_ID" --zone us-west1-a \
  --tunnel-through-iap --command 'sudo systemctl restart vaultwarden'
```

Verify it is closed — this must now return `http=400`:

```bash
curl -sS -o /dev/null -w "http=%{http_code}\n" -X POST \
  "$(terraform output -raw vault_url)/identity/accounts/register/send-verification-email" \
  -H 'Content-Type: application/json' \
  -d '{"email":"blocked@example.com","name":null,"receiveMarketingEmails":false}'
```

---

## 9. Connect the Bitwarden clients

See the **Chrome extension** section in [README.md](README.md#bitwarden-chrome-extension)
for the detailed walkthrough.

> If the extension shows "An unexpected error has occurred" when you enter
> your master password, the server is older than the client. Check
> `POST /identity/accounts/prelogin/password` returns 200 rather than 404,
> and bump `vaultwarden_image` if it doesn't. In short: install the official extension, and
**before logging in** open the settings gear and set the server URL to your
vault URL.

Repeat on mobile and desktop as needed — every client has the same
self-hosted-URL step, and it must be done before the first login.

---

## 10. Verify backups

A nightly timer at 02:30 UTC archives the vault to GCS. Test it now rather than
discovering a problem when you need a restore:

```bash
gcloud compute ssh vaultwarden --project "$PROJECT_ID" --zone us-west1-a \
  --tunnel-through-iap --command 'sudo systemctl start vaultwarden-backup.service && echo OK'

gcloud storage ls -l "gs://$(terraform output -raw backup_bucket)/"
```

Then do a restore drill — an untested backup is not a backup:

```bash
cd /tmp
gcloud storage cp "gs://$(cd - >/dev/null && terraform output -raw backup_bucket)/vaultwarden-<stamp>.tar.gz" .
tar -tzf vaultwarden-<stamp>.tar.gz     # must list db.sqlite3 AND rsa_key.pem
mkdir -p drill && tar -xzf vaultwarden-<stamp>.tar.gz -C drill
sqlite3 drill/db.sqlite3 "PRAGMA integrity_check;"    # must print: ok
```

`rsa_key.pem` matters as much as the database: it signs JWTs, and restoring
without it invalidates every client session.

---

## 11. Confirm $0

```bash
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
  --format="table(displayName,amount.specifiedAmount.units)"
```

The config encodes the free-tier rules as plan-time validations, but check the
billing report after 48 hours anyway. The budget alert fires at 50% and 100% of
actual spend and 100% of forecast.

Confirm every resource is actually within the free tier — machine type, disk
types and total size, and that the static IP is `IN_USE`:

```bash
gcloud compute instances describe vaultwarden --zone "$ZONE" \
  --format="value(machineType.basename(),status)"
gcloud compute disks list --format="table(name,type.basename(),sizeGb)"
gcloud compute addresses list --format="table(name,status)"
gcloud storage buckets describe "gs://$(terraform output -raw backup_bucket)" \
  --format="value(location,locationType)"
```

See the cost breakdown table in
[README.md](README.md#running-cost-000month) for the expected values and
remaining headroom.

Common ways to accidentally start paying:

- A region other than `us-west1` / `us-central1` / `us-east1`
- `pd-balanced` / `pd-ssd`, or disks totalling more than 30GB
- A multi-region backup bucket instead of regional
- **A reserved static IP left unattached** — free while attached to a running
  instance, billed once it isn't. If you tear down the VM, release the address.

---

## Day-2 operations

```bash
terraform output ssh_command          # SSH via IAP; port 22 is not public
terraform output logs_command         # tail Vaultwarden logs
terraform output admin_token_command  # read the stored admin hash
```

**Changing runtime settings** (`domain`, `signups_allowed`) — no rebuild needed:

```bash
terraform apply
gcloud compute ssh vaultwarden --zone us-west1-a --tunnel-through-iap \
  --command 'sudo systemctl restart vaultwarden'
```

**Changing anything under `files/`** — cloud-init only runs on first boot, so the
VM must be replaced:

```bash
terraform apply
terraform taint google_compute_instance.vault
terraform apply
```

This is safe. The vault lives on a separate `prevent_destroy` disk that is
detached and remounted; the account and TLS certificates survive.

**Upgrading Vaultwarden:** bump `vaultwarden_image` in `terraform.tfvars`, take a
backup first, then rebuild as above.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Registration not allowed or user already exists` while signups should be open | The container hasn't re-read metadata. `sudo systemctl restart vaultwarden`. |
| Budget: `Error 400: invalid argument` | Currency mismatch — the budget must use the billing account's currency. Terraform reads it automatically; check `billing_account` is correct. |
| Budget: `SERVICE_DISABLED` for an unfamiliar project number | Step 3 was skipped: `gcloud auth application-default set-quota-project`. |
| TLS fails / certificate warning | DNS wasn't resolving at boot. Fix DNS, then `sudo systemctl restart caddy`. Let's Encrypt rate-limits repeated failures. |
| `/admin` rejects the token | You're entering the hash. Enter the **raw** token from step 6. Check `$$` wasn't written into `.tfvars`. |
| SSH hangs or refuses | Port 22 is IAP-only by design — `--tunnel-through-iap` is required. Right after a rebuild, SSH lags the web service by ~30s. |
| Backup service fails | `sudo journalctl -u vaultwarden-backup.service -n 30`. Run `sudo bash /etc/vaultwarden/backup.sh` for full output. |

---

## Tearing down

```bash
# Back up first — the data disk is prevent_destroy and will block the destroy.
gcloud compute ssh vaultwarden --zone us-west1-a --tunnel-through-iap \
  --command 'sudo systemctl start vaultwarden-backup.service'
gcloud storage cp "gs://$(terraform output -raw backup_bucket)/*" ./final-backup/

terraform destroy
```

`google_compute_disk.data` has `prevent_destroy = true`, so `terraform destroy`
**fails by design** rather than deleting your vault. Remove that lifecycle block
only when you genuinely intend to destroy the data.

Afterwards, confirm no static IP is left reserved but unattached — that is the
one resource here that quietly bills.
