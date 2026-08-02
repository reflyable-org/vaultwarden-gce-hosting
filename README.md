# Vaultwarden on GCP always-free e2-micro

Terraform for a single-user, $0/month self-hosted [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
(Bitwarden-compatible server), using the **official upstream Docker image**.

There is no Vaultwarden source in this repo and no fork to maintain — SQLite sits
on a persistent disk exactly as upstream intends, so no application changes are
needed.

```
GCP project
└── us-central1-a
    └── e2-micro VM  (always-free)
        ├── Container-Optimized OS
        ├── 20GB pd-standard boot disk
        ├── 10GB pd-standard data disk  ── /mnt/disks/data
        │     ├── vaultwarden/  SQLite + rsa_key.pem + attachments
        │     └── caddy/        TLS certs
        └── Docker
            ├── vaultwarden/server   :8080  (internal only)
            └── caddy                :80/:443  automatic HTTPS
                    │
                    └── nightly backup → GCS bucket (5GB free tier)
```

Deploying from scratch? Start with **[SETUP.md](SETUP.md)**.

## Prerequisites

### Billing

The always-free tier still requires an active billing account attached — it
simply doesn't charge for in-allowance usage. Compute Engine cannot be enabled
without it.

```bash
gcloud billing accounts list
gcloud billing projects link <project> --billing-account=ACCOUNT_ID
```

### Domain

The simplest option is **sslip.io**: `<dashed-ip>.sslip.io` resolves to that IP
automatically — for a static IP of `203.0.113.10` the hostname is
`203-0-113-10.sslip.io`. There is no DNS to configure and Let's Encrypt's
HTTP-01 challenge works on first boot.

The hostname is derived from the static IP. **If that IP ever changes, `domain`
must change with it** and every client must be re-pointed. To move to a real
domain later, set `domain`, create an A record at the static IP, re-apply, and
update the server URL in each client.

**A Firebase Hosting domain (`*.web.app`) cannot be used.** Its DNS is controlled
by Google, so no A record can point at the VM; it is also HSTS-preloaded and
pinned to Google-issued certificates. Firebase Hosting serves static files from a
CDN and cannot front a Compute Engine VM.

HTTPS is not optional: Bitwarden clients refuse plain HTTP, and WebAuthn/2FA is
origin-bound.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in: project_id, domain, billing_account, acme_email

terraform init
terraform apply
```

With sslip.io there is no DNS step — the hostname already resolves to the static
IP. If you switch to a real domain, create the A record that
`terraform output dns_record_required` prints, **before the VM finishes booting**:
Caddy requests a certificate on start, and if the name doesn't resolve to the VM
the challenge fails and Let's Encrypt applies rate limits. If you miss the window,
fix DNS then `sudo systemctl restart caddy`.

First boot takes 2-3 minutes (image pulls, disk format, cert issuance).

Because cloud-init only runs on first boot, changing anything under `files/`
requires replacing the instance:

```bash
terraform apply                              # push new metadata
terraform taint google_compute_instance.vault
terraform apply                              # rebuild
```

This is safe: the vault lives on a separate `prevent_destroy` disk that is
detached and remounted.

## Register your account

The server ships with signups disabled so a public URL can't be used by strangers.

```bash
# 1. open registration
sed -i '' 's/signups_allowed = false/signups_allowed = true/' terraform.tfvars
terraform apply -auto-approve
gcloud compute ssh vaultwarden --zone us-central1-a --tunnel-through-iap \
  --command 'sudo systemctl restart vaultwarden'

# 2. visit https://<your domain> and create your account

# 3. close registration again — do not skip
sed -i '' 's/signups_allowed = true/signups_allowed = false/' terraform.tfvars
terraform apply -auto-approve
gcloud compute ssh vaultwarden --zone us-central1-a --tunnel-through-iap \
  --command 'sudo systemctl restart vaultwarden'
```

**The restart is required.** `terraform apply` updates instance metadata, but the
running container only re-reads it on service start — without the restart,
registration silently stays closed and the web vault reports
"Registration not allowed or user already exists".

Verify the state actually changed before and after:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -X POST \
  "https://<your domain>/identity/accounts/register/send-verification-email" \
  -H 'Content-Type: application/json' \
  -d '{"email":"probe@example.com","name":null,"receiveMarketingEmails":false}'
# 200 = open, 400 = closed
```

Then connect your clients — see [Bitwarden Chrome extension](#bitwarden-chrome-extension).

For a complete first-time walkthrough including project creation and billing,
see [SETUP.md](SETUP.md).

## Bitwarden Chrome extension

Vaultwarden implements the Bitwarden API, so the **official** extension works
unmodified. There is nothing custom to install.

Install it from the Chrome Web Store — "Bitwarden Password Manager", extension
ID `nngceckbapebfimnlniiiahkandclblb`. That ID is allow-listed in the server's
`Content-Security-Policy` (`frame-ancestors`), so a fork or clone will not work.

> **Keep the server reasonably current.** The clients auto-update and will call
> endpoints older servers don't implement, producing an opaque
> "unexpected error" at login rather than a version message. This config
> pins `1.37.1`; `1.34.1` was too old for the current extension.

### Point it at your server *before* logging in

This is the step people miss. The extension defaults to Bitwarden's cloud, and
the server cannot be changed once you are logged in — you would have to log out
and lose local state.

1. Click the Bitwarden icon.
2. On the login screen, click the **⚙ settings gear** (top-left) — or the
   **Region / Self-hosted** dropdown on newer builds.
3. Choose **Self-hosted**.
4. Set **Server URL** to your vault URL, including `https://`:
   ```
   https://203-0-113-10.sslip.io
   ```
   Leave the other per-service URL fields blank — the server advertises them via
   `/api/config`.
5. **Save**, then log in with your email and master password.

### Verify it is actually connected

- The extension shows your email and unlocks with your master password.
- Add a test item in the extension, then reload the web vault in a browser tab —
  it should appear.
- Edit it in the web vault; the extension should reflect the change within a few
  seconds. Live updates arrive over a WebSocket to `/notifications/hub`, which
  Caddy proxies.

### Everyday use

- **Unlock:** the extension locks on a timer; unlock with your master password.
- **Autofill:** `Ctrl+Shift+L` (`Cmd+Shift+L` on macOS) fills the matching login.
- **Save on login:** the extension offers to save new credentials automatically.
- **Manual sync:** Settings → Sync → **Sync vault now**, if something looks stale.

### Extension troubleshooting

| Symptom | Cause |
|---|---|
| **"An unexpected error has occurred" on entering your password** | The extension is newer than the server. Modern extensions call `POST /identity/accounts/prelogin/password`, which Vaultwarden only implements from ~1.35; on 1.34.1 it 404s and the extension surfaces a generic error. Upgrade `vaultwarden_image` and rebuild. Confirm with `curl -o /dev/null -w "%{http_code}" -X POST https://<domain>/identity/accounts/prelogin/password -H 'Content-Type: application/json' -d '{"email":"you@example.com"}` — must be 200, not 404. |
| "Cannot connect to server" | URL is missing `https://`, or has a trailing slash or `/api` suffix. Use the bare origin. |
| Certificate / connection errors | The Let's Encrypt certificate isn't valid yet. Check `curl -I https://<domain>/alive` succeeds first. |
| Login says "username or password incorrect" | Registration was never completed on *this* server, or you are pointed at Bitwarden's cloud rather than your own. |
| Items don't sync between clients | Force **Sync vault now**. Each client keeps a local cache; WebSocket updates are best-effort. |
| Can't change the server URL | You are logged in. Log out, then set it on the login screen. |

Mobile and desktop clients follow the same pattern: choose **Self-hosted** and
enter the server URL on the login screen, before the first login.

## Operating

```bash
terraform output ssh_command          # SSH via IAP (port 22 is not public)
terraform output logs_command         # tail Vaultwarden logs
terraform output admin_token_command  # read the /admin token

sudo systemctl status vaultwarden caddy
sudo systemctl start vaultwarden-backup.service   # run a backup now
```

### Admin token

Generate a proper Argon2 hash rather than relying on the random plain-text
fallback (Vaultwarden logs a warning for the latter):

```bash
docker run --rm -it docker.io/vaultwarden/server:1.37.1-alpine /vaultwarden hash --preset owasp
```

This needs an interactive TTY. Over `gcloud compute ssh` it panics with
`No such device or address`; run it locally, or generate the hash with
`argon2-cffi` using the same OWASP parameters (`m=19456, t=2, p=1`).

Put the `$argon2id$...` string in `admin_token_hash` in `terraform.tfvars` using
**double quotes and no escaping**:

```hcl
admin_token_hash = "$argon2id$v=19$m=19456,t=2,p=1$...$..."
```

`.tfvars` values are literal — writing `$$` there stores the doubled characters
verbatim and the token will never validate. Keep the _raw_ token (what you type
into `/admin`) in your own password manager; only the hash lives here.

## Backups

A disk is not a backup. A nightly timer runs `vaultwarden backup`, which performs
`VACUUM INTO` for a transactionally consistent SQLite copy, then archives it to
GCS. (The CLI is used rather than the `SIGUSR1` signal because it is synchronous
and exits non-zero on failure — a fire-and-forget signal makes a failed backup
look identical to a successful one.)

The archive deliberately includes more than the database:

| File                     | Why it matters                                                                  |
| ------------------------ | ------------------------------------------------------------------------------- |
| `db.sqlite3`             | The vault                                                                       |
| `rsa_key.pem`            | JWT signing key — **without it every client session is invalidated on restore** |
| `config.json`            | Admin-panel settings                                                            |
| `attachments/`, `sends/` | File attachments                                                                |

Retention is 30 days with a lifecycle rule, keeping the bucket inside the 5GB free
tier. The VM's service account has `objectCreator` only — it can write new backups
but cannot read or delete existing ones, so a compromised VM can't destroy history.

### Restore drill — do this once

An untested backup is not a backup.

```bash
gcloud storage ls gs://$(terraform output -raw backup_bucket)/
gcloud storage cp gs://<bucket>/vaultwarden-<stamp>.tar.gz .
tar -tzf vaultwarden-<stamp>.tar.gz     # confirm rsa_key.pem is present
```

To restore: stop Vaultwarden, extract the archive over `/mnt/disks/data/vaultwarden`,
rename `db.sqlite3` into place, start it, and confirm an existing client logs in
_without_ being forced to re-authenticate.

## Staying at $0

### Running cost: **$0.00/month**

What this config provisions, against the always-free allowances it has to fit
inside.

| Resource       | Provisioned                          | Always-free allowance                 | Headroom      |
| -------------- | ------------------------------------ | ------------------------------------- | ------------- |
| VM             | `e2-micro`, `us-central1-a`, standard | 1× `e2-micro` in us-west1/central1/east1 | exact fit     |
| Disks          | `pd-standard` 20GB + 10GB = **30GB** | 30GB `pd-standard`, project-wide total | **at limit**  |
| Static IP      | attached, `IN_USE`                   | free while attached to a running VM   | fine          |
| Backup bucket  | regional, a single vault's backups   | 5GB-months regional                   | negligible    |
| Secret Manager | 1 secret                             | 6 active versions                     | fine          |
| Egress         | personal client sync                 | 200GB/month North America             | negligible    |

No load balancers, Cloud NAT, PD snapshots, or custom images — the usual silent
billers are all absent, and PD snapshots are deliberately avoided in favour of
the GCS backup bucket.

The domain (~$10/yr) is the only reliable cost, and only if you move off the free
sslip.io hostname.

### Rules the config enforces

- `e2-micro` only, in `us-west1` / `us-central1` / `us-east1` (validated).
- `pd-standard` disks totalling ≤30GB (validated as a precondition).
- Regional backup bucket — multi-region `US` is **not** free.
- A **$1 budget alert** at 50%/100% actual and 100% forecast spend. This is the
  real safety net — free-tier rules change and mistakes are quiet.

### The two ways this starts billing

1. **Disks are exactly at the 30GB ceiling.** Any increase to `boot_disk_gb` or
   `data_disk_gb` bills immediately. The precondition fails the plan, so it takes
   a deliberate override.
2. **A reserved-but-unattached static IP is billed** (~$0.50/mo) — it is free only
   while attached to a *running* instance. If you `terraform destroy` the VM,
   release the address too.

Verify actual spend in the billing console after ~48 hours of runtime; the
config being correct is not the same as the invoice being zero. Free-tier terms
change — treat the table above as what to check, not a guarantee.

## Security posture

- Port 22 is **not** exposed; SSH is brokered by IAP (`35.235.240.0/20`) and
  governed by IAM. OS Login on, project-wide SSH keys blocked.
- Dedicated VPC — avoids the default network's `default-allow-ssh` from `0.0.0.0/0`.
- Explicit logged catch-all deny at priority 65535.
- Shielded VM: secure boot, vTPM, integrity monitoring.
- Admin token in Secret Manager, fetched at boot — never in instance metadata,
  which is readable by anyone with `compute.instances.get`.
- Data disk is `prevent_destroy`; `terraform destroy` fails rather than deleting
  the vault.

Note that `terraform.tfstate` contains the admin token in plaintext — it is
gitignored. Consider migrating state to the GCS backend (commented in
`versions.tf`) once the project exists.

## Gotchas hit during deployment

Non-obvious failures already fixed in this config — recorded so they aren't
rediscovered on a rebuild.

| Symptom                                               | Cause                                                                                                                                                                                                              |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Budget: `Error 400: invalid argument`                 | The budget currency must match the **billing account's** currency, which is not necessarily USD. The API gives no hint. Now read from `data.google_billing_account`.                                               |
| Budget: `SERVICE_DISABLED` for project `764086051850` | The Budgets API bills quota to the _calling_ project; user ADC falls back to a shared Google project. Fixed with `billing_project` + `user_project_override` on the provider.                                      |
| Scripts exit `2/INVALIDARGUMENT` under systemd        | COS mounts `/etc` as an overlay that does not honour the shebang. Units invoke `/bin/bash <script>` explicitly.                                                                                                    |
| `admin.env` written as 0 bytes                        | Secret Manager returns pretty-printed multi-line JSON; the line-oriented `sed` never matched. Now parsed with `python3`.                                                                                           |
| Backup uploaded nothing, no error                     | `set -e` plus a `for` loop whose final test returns non-zero killed the script silently. Replaced with the synchronous `vaultwarden backup` CLI, which exits non-zero on failure — unlike fire-and-forget SIGUSR1. |
| Upload: `403 storage.objects.get denied`              | `gcloud storage cp` does a preflight GET, requiring read access to all backups. Replaced with a raw JSON-API POST needing only `objects.create`.                                                                   |
| Admin token never validates                           | `$$` was written in `.tfvars`. Those values are literal — escaping stores the doubled characters verbatim.                                                                                                         |
| `signups_allowed` change had no effect | cloud-init runs only on first boot, so values baked into the unit file went stale. `DOMAIN` and `SIGNUPS_ALLOWED` are now read from instance metadata on every service start — `terraform apply` plus `systemctl restart vaultwarden` applies them without a rebuild. |
| WebSocket probe returned 404 | Not a defect. `curl` over HTTP/2 strips `Connection: Upgrade`; the same request over HTTP/1.1 returns 401 (auth required), which is correct. Real clients use HTTP/1.1 for WebSockets. |

## Files

| File                    | Purpose                                             |
| ----------------------- | --------------------------------------------------- |
| `project.tf`            | API enablement, optional project creation           |
| `network.tf`            | VPC, subnet, static IP, firewall                    |
| `compute.tf`            | e2-micro, disks, service account                    |
| `storage.tf`            | Backup bucket + lifecycle                           |
| `secrets.tf`            | Admin token                                         |
| `budget.tf`             | $1 billing alert                                    |
| `cloudinit.tf`          | Renders `files/cloud-init.yaml`                     |
| `files/cloud-init.yaml` | Disk mount, systemd units, Caddyfile, backup script |
| `SETUP.md`              | First-time deployment from an empty GCP account     |
