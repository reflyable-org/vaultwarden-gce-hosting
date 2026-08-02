# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform that deploys **upstream Vaultwarden** (Bitwarden-compatible server) to a
GCP always-free `e2-micro` VM, at $0/month.

**There is no application source here.** The repo previously contained a
Vaultwarden Rust checkout; it was deleted deliberately. An earlier design ran
Vaultwarden on Cloud Run with SQLite snapshots in Firestore, which required
forking the server. That was dropped: on a VM with a persistent disk, SQLite
works exactly as upstream intends, so the official Docker image runs unmodified.
**Do not reintroduce a fork or patch Vaultwarden** — if something needs changing,
it is a Terraform or cloud-init change, or an upstream version bump.

A stray `target/` directory may remain from the deleted Rust checkout. It is
gitignored; ignore it.

## Commands

There is no build, lint, or test suite — this is infrastructure. The verification
loop is `plan` → `apply` → probe the live service.

```bash
terraform fmt -recursive
terraform validate
terraform plan
terraform apply

# Drift check: exit 0 = clean, 2 = changes pending
terraform plan -detailed-exitcode -input=false >/dev/null 2>&1; echo $?
```

`terraform validate` only checks syntax and references. It does **not** render
`files/cloud-init.yaml`. Use `terraform plan` to catch template errors, or
inspect the rendered output directly:

```bash
echo 'local.cloud_init' | terraform console
```

### Operating the deployed VM

```bash
terraform output ssh_command          # SSH via IAP; port 22 is not public
terraform output logs_command
terraform output admin_token_command

gcloud compute ssh vaultwarden --project "$PROJECT_ID" --zone us-central1-a \
  --tunnel-through-iap --command 'sudo systemctl status vaultwarden caddy'

# Backup on demand
gcloud compute ssh vaultwarden --zone us-central1-a --tunnel-through-iap \
  --command 'sudo systemctl start vaultwarden-backup.service'
```

Right after a VM rebuild, SSH becomes reachable ~30s *after* the web service.
Retry rather than assuming failure.

### Verifying a change actually worked

Infrastructure that applies cleanly is not infrastructure that works. Every bug
found in this repo so far passed `terraform apply` and failed on the box.

```bash
curl -sS -o /dev/null -w "http=%{http_code} tls=%{ssl_verify_result}\n" \
  "$(terraform output -raw vault_url)/alive"          # want: http=200 tls=0

# Signups: 200 = open, 400 = closed
curl -sS -o /dev/null -w "%{http_code}\n" -X POST \
  "$(terraform output -raw vault_url)/identity/accounts/register/send-verification-email" \
  -H 'Content-Type: application/json' \
  -d '{"email":"probe@example.com","name":null,"receiveMarketingEmails":false}'
```

Caddy's JSON access log is the best debugging tool for client problems — it shows
the `Bitwarden-Client-Name` header, so you can tell the browser extension
(`browser`) from the web vault (`web`):

```bash
sudo docker logs caddy 2>&1 | python3 -c "
import sys,json
for line in sys.stdin:
    i=line.find('{')
    if i<0: continue
    try: d=json.loads(line[i:])
    except: continue
    r=d.get('request',{})
    c=r.get('headers',{}).get('Bitwarden-Client-Name',['-'])[0]
    print(c, r.get('method'), r.get('uri','').split('?')[0], '->', d.get('status'))
"
```

## Architecture

```
Terraform ──> instance metadata ──> cloud-init (FIRST BOOT ONLY) ──> systemd
                    │                                                   ├── caddy         :80/:443 TLS
                    └── vw-domain, vw-signups-allowed                   ├── vaultwarden   :8080 internal
                        (re-read on EVERY service start)                └── backup.timer  nightly → GCS
```

`cloudinit.tf` renders `files/cloud-init.yaml` via `templatefile()` into
`local.cloud_init`, which `compute.tf` sets as the `user-data` metadata key. The
template's `${...}` variables and the map in `cloudinit.tf` must stay in sync —
a missing key is a plan-time error, an unused one is silent.

### The two-tier config split — most important thing to understand

**cloud-init runs only on first boot.** Anything substituted into a systemd unit
at render time is frozen for that VM's life. A `terraform apply` updates
metadata but does *not* change a running VM. This caused a real bug: changing
`signups_allowed` appeared to work and silently did nothing.

So config is split:

| Tier | Where | To change it |
|---|---|---|
| `DOMAIN`, `SIGNUPS_ALLOWED` | `vw-*` metadata keys, read by `fetch-runtime-config.sh` on **every** service start | `terraform apply` + `systemctl restart vaultwarden` |
| Everything else (image, ports, `DATA_FOLDER`, Caddyfile, scripts) | baked into the unit at cloud-init time | `terraform apply`, then `terraform taint google_compute_instance.vault`, then `terraform apply` |

**Any edit to `files/cloud-init.yaml` requires a VM rebuild to take effect.**
This is safe and verified: the vault lives on a separate `prevent_destroy` disk
that detaches and remounts. The account and TLS certificates survive.

Prefer adding a `vw-*` metadata key over baking a value in, if it is something
that might plausibly change.

### Persistence

`google_compute_disk.data` is mounted at `/mnt/disks/data` and holds
`vaultwarden/` (SQLite, `rsa_key.pem`, attachments, sends) and `caddy/` (TLS
certs). It has `prevent_destroy = true`, so `terraform destroy` **fails by
design**. The instance also sets `ignore_changes = [attached_disk]`.

`rsa_key.pem` matters as much as the database: it signs JWTs. A database-only
backup restores to a server that invalidates every client session, which is why
`backup.sh` archives it alongside `db.sqlite3`.

### Backup

`vaultwarden-backup.timer` → `backup.sh`, which runs `vaultwarden backup`
(`VACUUM INTO`, transactionally consistent), tars the DB plus `rsa_key.pem`,
`config.json`, `attachments/`, `sends/`, and uploads to GCS.

Two deliberate choices, both load-bearing:

- The **CLI**, not the `SIGUSR1` signal. The signal is fire-and-forget, so a
  failed backup looks identical to a successful one. The CLI is synchronous and
  exits non-zero.
- A **raw JSON-API POST**, not `gcloud storage cp`. `gcloud` does a preflight GET
  requiring `storage.objects.get`, which would mean read access to every
  existing backup. The service account has `objectCreator` only, so a compromised
  VM can add backups but cannot read or destroy history.

## Constraints that will silently cost money or break things

`variables.tf` encodes the free-tier rules as plan-time validations. Two more are
enforced only by comment and care:

- **Region** must be `us-west1` / `us-central1` / `us-east1` (validated).
- **`machine_type`** must be `e2-micro` (validated).
- **Disks** must be `pd-standard`, and `boot + data <= 30` GB — the free
  allowance is the project-wide total, enforced as a `precondition`.
- **Backup bucket must be regional**, never multi-region `US`.
- **A static IP is free only while attached to a running instance.** Tearing down
  the VM and leaving the address reserved bills.

The `$1` budget alert in `budget.tf` is the real safety net. Its currency is read
from `data.google_billing_account` — the Budgets API rejects a mismatch with a
bare `invalid argument` and no hint.

## Environment gotchas

Recorded because each cost real debugging time; see the README's gotchas table
for the full list.

- **Container-Optimized OS mounts `/etc` as an overlay that ignores the shebang.**
  systemd units must invoke `/bin/bash /etc/vaultwarden/<script>` explicitly, or
  they fail with `status=2/INVALIDARGUMENT`.
- **Parse Google API JSON with `python3`, not `sed`.** Secret Manager returns
  pretty-printed multi-line JSON; a line-oriented `sed` matches nothing and
  produces an empty file with no error.
- **`.tfvars` values are literal.** Never escape `$` as `$$` there (correct
  inside `templatefile`, wrong in a variables file) — the doubled characters are
  stored verbatim, and an Argon2 `admin_token_hash` will never validate.
- **In `files/cloud-init.yaml`, escape a literal `%` as `%%`** — `templatefile`
  interprets `%{...}`. Relevant to `curl -w '%%{http_code}'`.
- **Terraform needs an ADC quota project**
  (`gcloud auth application-default set-quota-project`) or the Budgets API fails
  against a shared Google-owned project.

## Client compatibility

Bitwarden clients auto-update and will call endpoints an older server does not
implement, surfacing a generic "An unexpected error has occurred" at login rather
than a version message. This happened with `1.34.1` and the Chrome extension's
`POST /identity/accounts/prelogin/password` (404). Keep `vaultwarden_image`
reasonably current; probe that endpoint for 200 when a client misbehaves.

## Secrets

`terraform.tfvars` (holds the Argon2 admin hash) and `terraform.tfstate` (holds
the secret in plaintext) are gitignored. Only `terraform.tfvars.example` is
tracked. Before committing, confirm nothing sensitive is staged.

`versions.tf` has a commented-out GCS backend for migrating state off local disk.
