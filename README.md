# brain-freeze-deploy

Runs [Ice Cream Brain Freeze Insurance](https://github.com/GemTalk/brain-freeze)
as a public website on Google Cloud. The app is a Flask app that runs inside
GemDB. This repository holds the Terraform that builds the cloud side, the
scripts that set up and run the server, and the script that releases new
versions.

Part 1 says what the deployment does and why. Part 2 is a runbook written to
be followed step by step, by a person or an agent.

**Part 1: what this does**

- [The shape of it](#the-shape-of-it)
- [What each piece does](#what-each-piece-does)
- [Where the data lives](#where-the-data-lives)
- [What happens when something fails](#what-happens-when-something-fails)
- [Monitoring](#monitoring)
- [What the app must provide](#what-the-app-must-provide)
- [Limits](#limits)
- [What has been tested](#what-has-been-tested)

**Part 2: runbook**

- [R0. Rules](#r0-rules)
- [R1. Preconditions](#r1-preconditions)
- [R2. First deploy](#r2-first-deploy)
- [R3. Verify](#r3-verify)
- [R4. Release](#r4-release)
- [R5. Resize](#r5-resize)
- [R6. Fail over to the other zone](#r6-fail-over-to-the-other-zone)
- [R7. Restore](#r7-restore)
- [R8. Troubleshooting](#r8-troubleshooting)
- [R9. Reference](#r9-reference)

---

# Part 1: what this does

## The shape of it

```
 visitors ──▶ HTTPS load balancer ── static IP, managed certificate, Cloud Armor
                 │
                 ▼   one VM, in whichever of two zones `active_zone` names
              HAProxy :8080 ── queues requests; sends each instance one at a time
                 │
                 ├──▶ brainfreeze-app@1  :5051 ┐
                 ├──▶ brainfreeze-app@2  :5052 ├─ each is one GemDB session
                 └──▶ brainfreeze-app@3  :5053 ┘
                                 │
                                 ▼
                    GemDB stone (GemStone 4.0.0.a4) on a regional disk
                    ── written to both zones at once, snapshotted every 4
                       hours, backed up daily to Cloud Storage
```

The VM is disposable. Everything that matters is on one data disk, which
Google writes to two zones at once. If the VM is replaced, whether because it
failed, its settings changed, or you moved zones, the new VM attaches that
disk at boot and carries on from the last commit.

## What each piece does

| Path                     | What it does                                                                                                                                                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `terraform/`             | Everything in Google Cloud: network, NAT, firewall, the data disk, its snapshot schedule, the backups bucket, the VM template, one instance group per zone, the load balancer and certificate, Cloud Armor, the dashboard, the uptime check, the alerts. |
| `node/startup.sh`        | The VM's boot script, run on every boot. Attaches the data disk, taking it from a dead VM if it must. Mounts it, clones both repositories onto it the first time, then runs `provision.sh`.                                       |
| `node/provision.sh`      | Makes the VM serve. On a blank disk it installs GemDB with GemDB Code 1.6.0's own setup. It writes settings, systemd units, the HAProxy config and the monitoring agent's config. It starts the database, loads the app's code, seeds the book if there is none, and starts the instances one at a time. Safe to run again. |
| `node/bin/`              | What the units and `provision.sh` run: `gemdb-ctl` (stone and NetLDI), `run-instance`, `wait-healthy`, `instances` (start or rolling restart), `haproxy-config`, `backup`, `collect-garbage`, `watchdog`, `release`.             |
| `node/systemd/`          | `gemdb.service`, `brainfreeze-app@.service`, and the backup (daily), garbage-collection (daily) and watchdog (every minute) timers.                                                                                             |
| `node/ops-agent.yaml`    | What the Ops Agent sends to Cloud Monitoring and Cloud Logging.                                                                                                                                                               |
| `deploy.sh`              | Releases new versions from your machine, over SSH through IAP, with no downtime.                                                                                                                                               |
| `tests/`                 | Checks that the pieces agree: ports, health-check paths, the log lines the alerts count, unit paths, and the VM settings Terraform passes in. These tests deploy nothing.                                                      |

HAProxy, not nginx, sits in front of the instances. Each instance is a
single-threaded Flask server, a limit of the Python runtime GemDB uses, so
each can answer only one request at a time. HAProxy's `maxconn 1` gives each
instance one request and queues the rest until an instance is free.
Open-source nginx cannot queue like that, and answers 502 when every
instance is busy.

## Where the data lives

On the VM, the data disk is mounted at `/var/lib/brainfreeze`. That is also
the home directory of the `brainfreeze` account, which runs the database and
the app.

```
/var/lib/brainfreeze/
  GemDB/      the engine, the database (db/), Grail, the gemdb command
  app/        brain-freeze, at the release being served
  deploy/     this repository, at the release being served
  backups/    a backup on its way to Cloud Storage
```

| Copy            | How often                       | Kept                        | Used for                                    |
| --------------- | ------------------------------- | --------------------------- | ------------------------------------------- |
| The regional disk | every commit, in both zones    | always                      | VM and zone failures                        |
| Disk snapshots  | every `snapshot_every_hours` (4) | `snapshot_retention_days` (14) | a bad release, a mistake in the data     |
| Full backups in Cloud Storage | daily, 03:30 UTC       | `backup_retention_days` (30) | losing the disk and its snapshots          |
| Transaction logs in Cloud Storage | with each backup     | `backup_retention_days` (30) | replaying commits made after a backup      |

Persistent links: every link to the site is `https://<domain>/...`, for
example `https://<domain>/policies/BF-100539/card`. The domain points at a
static IP that Terraform will not delete. IDs are issued from one counter in
the database, so no ID is ever issued twice, even with several instances
writing at once. The book is seeded only when the database holds none, so
no boot, release or restore ever replaces what customers have bought.

## What happens when something fails

| What fails           | What happens                                                                                                                         | Downtime                  |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------- |
| An app instance      | systemd restarts it. HAProxy sends its requests to the others meanwhile.                                                               | none                      |
| The database process | `brainfreeze-watchdog` notices within a minute. It restarts the stone, which recovers from its transaction logs, then the instances. | about 2 min               |
| The VM               | Autohealing replaces it after 5 minutes with no healthy instance. The new VM takes the disk over and recovers as after a crash.      | 5 to 10 min               |
| A zone               | No commit is lost, because the disk is written to both zones at once. Failing over is one Terraform change ([R6](#r6-fail-over-to-the-other-zone)). | until you fail over |
| The data             | Restore a snapshot or a backup ([R7](#r7-restore)).                                                                                  | minutes                   |

Two instances can write the same object at once. The database then refuses
the second commit, and the app runs that request again (brain-freeze's
`web/conflicts.py`). A few of these a minute is normal. Each one appears on
the dashboard as a commit conflict.

## Monitoring

Everything appears in Cloud Monitoring and Cloud Logging. `terraform output
dashboard` links the dashboard.

| Source                    | What it shows                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------------ |
| The load balancer         | requests by status class, latency percentiles                                              |
| HAProxy (`haproxy_*`)     | responses by code, response time per instance, healthy instances, requests queued          |
| The app (`brainfreeze_*`) | policies on the book, quotes given and sold, claims by outcome                             |
| The database (`gemdb_*`)  | extent size and free space (10 GB cap), sessions logged in (10 allowed)                     |
| The VM                    | CPU, memory, disk                                                                          |
| The logs                  | commit conflicts a second, backups finished                                                |

The app publishes its numbers at `/metrics`, and HAProxy publishes its own
on port 8405. The Ops Agent on the VM reads both and sends them to Cloud
Monitoring. Visitors cannot read `/metrics`: HAProxy answers 404 to it on
the public port.

Alerts go to `alert_email` when:
- the uptime check on `https://<domain>/healthz` fails;
- fewer instances are healthy than configured;
- more than 5% of responses are 5xx;
- requests have been queueing for more than 5 minutes;
- the database has less than 1.5 GB free;
- there has been no backup in 26 hours.

## What the app must provide

This repository deploys brain-freeze and depends on these parts of it. A
change to any of them in brain-freeze needs a matching change here.

| What                                                    | Used by                                     |
| ------------------------------------------------------- | ------------------------------------------- |
| `web/app.py`, serving on `BRAINFREEZE_PORT`             | `node/bin/run-instance`                     |
| `GET /healthz` → 200 `ok` (`web/routes_ops.py`)         | HAProxy's checks, the uptime check          |
| `GET /metrics` in Prometheus text format                | the Ops Agent                               |
| the log line `commit conflict` (`web/conflicts.py`)     | the commit-conflicts metric                 |
| `tools/load.py`, `tools/seed.py`                        | `node/provision.sh`                         |
| `ci/setup-gemdb/run.js`, GemDB Code's setup without an editor | `node/provision.sh`, first boot only  |
| `serve()` exits 1 if another instance compiled the app at the same moment | systemd restarts it              |

The app needs the `/healthz`, `/metrics` and conflict handling that came with
this deployment. A brain-freeze ref without `web/routes_ops.py` will never
pass a health check.

## Limits

- **The free GemStone license** allows 10 sessions and 10 GB. Each instance
  is one session, the database's own processes use 2, and a backup or
  release needs 1 more while it runs. That is why `app_instances` stops at 6.
  GemDB reserves the full 10 GB on disk when it first starts. Cloud Armor
  limits writes from each client IP (`writes_per_minute`, 20 by default),
  because every quote is stored and counts against the 10 GB.
- **The engine is an alpha**: GemStone 4.0.0.a4, as GemDB Code 1.6.0 ships it.
- **One VM**: replacing the VM, failing over, or changing any VM setting
  means a few minutes of downtime. The data survives all of them.
- **Stock passwords**: the stone runs with GemDB Code's stock DataCurator
  password. The VM has no external IP, and the firewall admits only the load
  balancer (to port 8080) and IAP (to SSH), so nothing outside can reach it.
- **Public repositories**: the VM clones both repositories without
  credentials, so both must be public.
- **Cost**: roughly $140 a month at the defaults in `us-central1`. Most of
  that is the VM, then the load balancer's forwarding rules, the regional
  disk and Cloud Armor.

## What has been tested

| Tested                                                                                                                       | Where                                |
| ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| Three instances on one database under constant concurrent writes: no duplicate IDs, no 500s. 2 of 450 writes got a 503 when the first run started; none did on the second. | macOS, GemStone 4.0.0.a4, older Grail (84821c1) |
| The HAProxy config as generated: queueing 30 concurrent requests over 3 instances, draining, `/metrics` refused publicly, the exporter's metric names | macOS, HAProxy 3.4                   |
| `gemdb.admin.backup` writing a backup, and that backup restored into a stock extent with every policy, claim and counter intact | macOS, the same engine               |
| `terraform validate`, shellcheck, this repository's tests                                                                     | macOS                                |

**Never run:**
- anything on GCP, so `terraform plan` and `apply` too;
- `provision.sh` on Ubuntu, including GemDB Code's setup on Linux (brain-freeze's CI runs it on macOS only);
- the systemd units and the Ops Agent config;
- the log filters and PromQL names in `terraform/monitoring.tf`;
- replaying transaction logs after a restore;
- Grail `beef473`, the version GemDB Code 1.6.0 ships.

Expect the first real deploy to find problems. [R8](#r8-troubleshooting)
lists the likely ones.

---

# Part 2: runbook

Conventions: `$PROJECT`, `$REGION`, `$ZONE` (the active zone) and `$VM` are
set like this, after the first apply:

```sh
out() { terraform -chdir=terraform output -raw "$1"; }
PROJECT=$(out project_id); REGION=$(out region); ZONE=$(out active_zone)
VM=$(gcloud compute instance-groups managed list-instances $(out active_group) \
       --project $PROJECT --zone $ZONE --format='value(instance.basename())')
```
 Run every command from the root of this repository unless the step
says otherwise. "Poll" means: repeat every 30 to 60 seconds until the step's
success condition holds or its time limit passes, then go to
[R8](#r8-troubleshooting).

## R0. Rules

These protect data and the links customers already have.

1. **Never run `tools/seed.py` on the VM**, and never delete
   `gemdb.root["brainfreeze"]`. Seeding replaces the whole book.
   `provision.sh` seeds only an empty database.
2. **Never delete the data disk (`brainfreeze-data`), the static IP, or the
   backups bucket.** Terraform refuses to (`prevent_destroy`), so do not
   remove that setting to make an apply succeed. A restore makes a new disk
   and leaves the old one alone.
3. **Never set `force_attach = true` unless the old zone is down.** It takes
   the disk away from a running VM, which crashes that VM's database.
4. **Never edit files the scripts write**: `/etc/haproxy/haproxy.cfg`,
   `/etc/brainfreeze/*`, `/etc/systemd/system/brainfreeze-*`. The next boot or
   release rewrites them. Change this repository and release it instead.
5. **Never set `app_instances` above 6** on the free license. Instances
   beyond the session limit cannot log in.
6. **Never change `domain` casually.** Every link anyone has saved uses it.
7. Ask a person before you: fail over (R6), restore (R7), run `terraform
   apply` with a plan that destroys anything, or stop the database.

## R1. Preconditions

Check each of these, and stop at the first that fails.

```sh
terraform version             # 1.6 or later
gcloud version                # any recent version
gcloud auth list              # an active account
gcloud config get-value project
```

- [ ] The account can administer the project (Owner, or Editor plus Project
      IAM Admin and Service Account Admin) and billing is enabled:
      `gcloud billing projects describe $PROJECT --format='value(billingEnabled)'`
      prints `True`.
- [ ] Both repositories are public and pushed, including the refs you will
      deploy: `git ls-remote https://github.com/GemTalk/brain-freeze.git main`
      and the same for this repository's URL both print a commit.
- [ ] The app ref has the deployment's endpoints. This must find the file:
      `curl -sfI https://raw.githubusercontent.com/GemTalk/brain-freeze/<app ref>/web/routes_ops.py`.
- [ ] You control DNS for the domain, or it is in a Cloud DNS zone in this
      project.
- [ ] Tests pass:
      `BRAIN_FREEZE_APP=<path to a brain-freeze checkout> python3 -m unittest discover`.

## R2. First deploy

1. **Configure.**

   ```sh
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```

   Set `project_id`, `domain`, `alert_email` and `deploy_repo` (this
   repository's clone URL). `app_ref` and `deploy_ref` default to `main`.
   Set them to what you checked in R1. `terraform/variables.tf` describes
   every other variable, and they all have working defaults.

2. **Plan, then apply.**

   ```sh
   terraform -chdir=terraform init
   terraform -chdir=terraform plan -var prometheus_alerts=false -out=tfplan
   terraform -chdir=terraform apply tfplan
   ```

   `prometheus_alerts=false` leaves out the four alerts on HAProxy's and the
   app's metrics: Cloud Monitoring refuses an alert on a metric it has never
   received, and those arrive only once the VM has booted. Step 6 makes them.

   A first plan creates about 50 resources and destroys none. If the plan
   destroys anything, stop and ask (R0.7). The apply takes about 5 minutes.
   On success it prints `static_ip`, `url`, `dashboard`, `active_group`,
   `active_zone`, `data_disk` and `backups_bucket`.

   If the apply fails with an API not enabled, or with a permission error on
   a service that was just enabled, wait 2 minutes and run the same apply
   again. Enabling an API takes time to take effect.

3. **Point DNS at it.** With `dns_managed_zone` set, Terraform already made
   the record. Otherwise create an A record for `domain` with the value of
   `terraform -chdir=terraform output -raw static_ip`. Check it with
   `dig +short <domain>`, which must print that IP. Do the same for each of
   `extra_domains`, whatever `dns_managed_zone` is set to.

4. **Wait for the first boot.** Expect about 15 minutes. Poll this until
   success, giving up after 30 minutes:

   Set the [conventions](#part-2-runbook)' variables first. `$VM` is empty
   for the first minute or so, until the instance group has made the VM.

   ```sh
   gcloud compute ssh $VM --project $PROJECT --zone $ZONE --tunnel-through-iap \
       --command 'sudo journalctl -u google-startup-scripts --no-pager \
                  | grep -E "brainfreeze-(startup|provision)|exit status" | tail -5'
   ```

   It has succeeded when the output contains
   `brainfreeze-provision: serving 3 instances`. On the way you will see:
   - `cloning`;
   - `setting GemDB Code 1.6.0 up on the data disk`;
   - `no book in the database: seeding it`.

   `startup-script exit status` followed by anything but 0 means it failed:
   go to R8, and read the whole log with `journalctl -u google-startup-scripts`.

5. **Wait for the certificate.** Google issues it only after DNS resolves to
   the static IP, which takes 15 to 60 minutes. Each of `extra_domains` has
   its own certificate, issued once its own DNS resolves. Poll this until
   every line prints `ACTIVE`, giving up after 90 minutes:

   ```sh
   gcloud compute ssl-certificates list --global \
       --filter="name~^brainfreeze-" --format='value(name,managed.status)'
   ```

6. **Make the remaining alerts.** Once step 4 has succeeded, wait 2 minutes
   for the first metrics to arrive, then plan and apply without the variable:

   ```sh
   terraform -chdir=terraform plan -out=tfplan
   terraform -chdir=terraform apply tfplan
   ```

   The plan creates 4 alert policies and changes nothing else. If the apply
   says `The following PromQL metric(s) are invalid`, the metrics have not
   arrived yet: wait 2 minutes and apply again.

## R3. Verify

Run all of these. Each line says what success looks like.

```sh
curl -s https://<domain>/healthz                    # prints: ok
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/          # 200
curl -s -o /dev/null -w '%{http_code}\n' http://<domain>/           # 301 (to https)
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/metrics   # 404 (private)
gcloud compute backend-services get-health brainfreeze-app --global \
    --format='value(status.healthStatus[].healthState)'             # HEALTHY
gcloud storage ls $(terraform -chdir=terraform output -raw backups_bucket)/backups/
                                       # one backup, made when the first boot finished
```

On the VM (`gcloud compute ssh $VM --zone $ZONE --tunnel-through-iap`):

```sh
systemctl is-active gemdb 'brainfreeze-app@1' 'brainfreeze-app@2' 'brainfreeze-app@3' haproxy
                                                    # active, five times
curl -s localhost:8081/metrics | grep ^brainfreeze_policies     # brainfreeze_policies 900
systemctl list-timers 'brainfreeze-*' --no-pager    # backup, gc, watchdog listed
```

Metrics reach the dashboard within about 5 minutes of the first boot
finishing. Some tiles stay empty until there is traffic.

To check writes end to end, buy a policy in the browser. Start a quote on
the home page and take a plan. The result is an ID card at
`https://<domain>/policies/BF-.../card`. Open it again in a new session: it
must still be there.

## R4. Release

Push both refs first, because the VM fetches them itself.

```sh
./deploy.sh <app ref>                  # this repo at its pushed HEAD
./deploy.sh <app ref> <deploy ref>     # or name both
```

It succeeds when it ends with `brainfreeze-provision: serving N instances`
and exits 0. The site stays up throughout: the instances restart one at a
time, and each one is drained first. Run R3 afterwards.

`deploy.sh` refuses when this repository's HEAD is not on a pushed branch.
Push it, or name a pushed ref.

A release never rebuilds the database. `tools/load.py` loads the new code,
and objects already stored keep working, as in the tutorial's step 3. To go
back, release the previous refs.

## R5. Resize

Set `machine_type` or `app_instances` (1 to 6) in `terraform.tfvars`, then
plan and apply as in R2. The plan shows the instance template replaced and
the instance group updated in place. The VM is then replaced, with about 5
minutes of downtime. Run R3 afterwards.

## R6. Fail over to the other zone

Do this only when the active zone is down or degraded, and ask a person
first (R0.7).

1. Check the disk is healthy:
   `gcloud compute disks describe $(terraform -chdir=terraform output -raw data_disk) --region $REGION --format='value(status)'`
   must print `READY`.
2. Apply, naming the zone that is up:

   ```sh
   terraform -chdir=terraform apply \
       -var active_zone=<the other zone> -var force_attach=true
   ```

3. Do R2 step 4 against the new zone. This boot takes 2 to 3 minutes, not 15,
   because GemDB is already on the disk. A line saying `taking
   brainfreeze-data from ...` is expected.
4. Put `active_zone = "<the other zone>"` in `terraform.tfvars`, then apply
   again with `force_attach` back at false.
5. Run R3.

Without `force_attach`, the new VM refuses to take the disk from a VM the API
still reports as RUNNING. It logs `... is RUNNING. Waiting.` every 30
seconds.

## R7. Restore

Ask a person first (R0.7). Both kinds of restore build a new disk and leave
the current one alone.

### From a snapshot (minutes; loses commits since the snapshot)

```sh
gcloud compute snapshots list --filter="sourceDisk~brainfreeze-data" \
    --sort-by=~creationTimestamp --format='table(name,creationTimestamp)'
gcloud compute disks create brainfreeze-data-restored --region $REGION \
    --replica-zones <zone a>,<zone b> --type pd-balanced \
    --source-snapshot <snapshot name>
terraform -chdir=terraform apply -var data_disk_override=brainfreeze-data-restored
```

Then put `data_disk_override = "brainfreeze-data-restored"` in
`terraform.tfvars`, so the next apply keeps it, and run R3. The stone
recovers the snapshot as it would after a crash.

### From a backup in Cloud Storage (when the disk and snapshots are gone)

1. Create an empty regional disk, as above but without `--source-snapshot`
   and with `--size 50`. Apply with `data_disk_override` set to it. Wait for
   R2 step 4 to succeed: it installs GemDB and seeds a sample book, which
   the next step replaces.
2. On the VM:

   ```sh
   sudo systemctl stop 'brainfreeze-app@*' gemdb
   sudo -iu brainfreeze
   set -a; . /etc/brainfreeze/gemdb.env; set +a
   cp "$GEMSTONE/bin/extent0.dbf" ~/GemDB/db/data/extent0.dbf
   rm -f ~/GemDB/db/data/tranlog*.dbf
   gcloud storage ls gs://<bucket>/backups/          # pick the newest
   gcloud storage cp gs://<bucket>/backups/<backup>.dbf.gz ~/backups/
   startstone -l ~/GemDB/db/log/gemdb.log gemdb
   topaz -l -q <<TPZ
   set user DataCurator pass swordfish gemstone gemdb
   login
   run
   SystemRepository restoreFromBackup: '$HOME/backups/<backup>.dbf.gz'
   %
   TPZ
   ```

   Success prints `The restore from backup completed, with N objects
   restored.`

3. Optional, and never tested: to recover commits made after the backup,
   copy the later logs from `gs://<bucket>/tranlogs/` into a directory, then
   run `SystemRepository restoreFromArchiveLogs: '<directory>'` the same way.
4. Finish:

   ```sh
   topaz -l -q <<TPZ
   set user DataCurator pass swordfish gemstone gemdb
   login
   run
   SystemRepository commitRestore
   %
   TPZ
   stopstone gemdb DataCurator swordfish
   exit
   sudo /var/lib/brainfreeze/deploy/node/provision.sh
   ```

5. Run R3. `brainfreeze_policies` should match the backup's book, not 900.

## R8. Troubleshooting

On the VM, start with `sudo journalctl -u google-startup-scripts -e` for the
boot, and `sudo journalctl -u 'brainfreeze-app@*' -e` for the app. The
database's own logs are in `/var/lib/brainfreeze/GemDB/db/log/`.

| Symptom                                                           | Likely cause → fix                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `terraform apply`: API not enabled, or 403 just after enabling    | Enabling APIs takes time to take effect → wait 2 minutes, apply again.                                                                                                                                                                              |
| `terraform apply`: `The following PromQL metric(s) are invalid`   | Cloud Monitoring has never received that metric: the VM hasn't finished its first boot, or the Ops Agent isn't sending → finish R2.4 and apply again. If it persists, `sudo systemctl status google-cloud-ops-agent` on the VM. On a first deploy, apply with `-var prometheus_alerts=false` (R2.2). |
| `terraform apply`: custom role `brainfreeze_disk_takeover` already exists | A deleted custom role keeps its ID for 7 days → set `name` to something else, or undelete it: `gcloud iam roles undelete brainfreeze_disk_takeover --project $PROJECT`.                                                                       |
| Boot log stops at `cloning`                                       | A repository is private or a ref doesn't exist → make it public, or fix `app_ref`/`deploy_ref`. A VM that has already booted keeps its clone, so fix it by hand: on the VM, `sudo rm -rf /var/lib/brainfreeze/{app,deploy}` and reboot. |
| Boot log: `could not attach <disk> yet: ...`, repeating          | The rest of the line is gcloud's reason. `does not have access to service account` or `Required 'compute...' permission` → the VM's grants in `terraform/compute.tf` are missing or still propagating: apply, and wait 2 minutes. |
| Boot log: `... is RUNNING. Waiting.`, repeating                   | Another VM holds the data disk. Expected for a few minutes during a replacement. If it lasts more than 10 minutes, find the holder with `gcloud compute disks describe <data_disk output> --region $REGION --format='value(users)'` and ask (R6).                        |
| First boot fails during `setting GemDB Code ... up`               | GemDB Code's setup has not been run on Linux before → read its `[GemDB]` lines in the boot log. A rerun repeats only the parts not yet done: `sudo /var/lib/brainfreeze/deploy/node/provision.sh`.                                                   |
| `tools/load.py failed three times`                                | The app ref doesn't load into the database. To see the error, run `sudo -iu brainfreeze`, then `cd app && ../GemDB/bin/gemdb tools/load.py`.                                                                                                                       |
| `instance N did not answer /healthz`                              | The instance can't start → `journalctl -u brainfreeze-app@N -e`. A ref without `web/routes_ops.py` answers 404 there (R1).                                                                                                                         |
| `can't start: something is already using 127.0.0.1:505N`         | A leftover process holds the port → `sudo systemctl restart brainfreeze-app@N`, which stops its whole process group first.                                                                                                                           |
| Certificate stuck in `PROVISIONING`, or `FAILED_NOT_VISIBLE`      | DNS doesn't resolve to `static_ip` → fix the A record and wait. Google keeps retrying.                                                                                                                                                              |
| 503 `Too many people are writing to the book at once`             | Five commit conflicts in a row on one request → happens only under heavy simultaneous writes. Check the conflicts tile. Rare by design.                                                                                                             |
| Alert: fewer app instances than configured                        | One instance is crashing → `journalctl -u brainfreeze-app@N`. If all 10 of the database's sessions are in use, an instance cannot log in: check `gemdb_sessions` on the dashboard.                                                                                               |
| Alert: no backup in 26 hours                                      | `journalctl -u brainfreeze-backup -e`. Usually bucket permissions or a full disk.                                                                                                                                                                  |
| Alert: database filling up                                        | `sudo systemctl start brainfreeze-gc`, then look at what is writing. The cap is the license's 10 GB.                                                                                                                                               |
| Dashboard tiles empty                                             | Before traffic, empty is normal. If they stay empty, check the agent with `sudo systemctl status google-cloud-ops-agent*`, then check the scrape targets: `curl localhost:8405/metrics`, `curl localhost:8081/metrics`.                                      |

## R9. Reference

**Terraform outputs**: `static_ip`, `url`, `dashboard`, `backups_bucket`,
`data_disk`, `active_group`, `active_zone`, `zones`, `region`, `project_id`.

**Resource names**, with the default `name = "brainfreeze"`:
- data disk: `brainfreeze-data`;
- instance groups: `brainfreeze-<zone>`;
- backend service: `brainfreeze-app`;
- health checks: `brainfreeze-lb`, `brainfreeze-autoheal`;
- Cloud Armor policy: `brainfreeze-edge`;
- bucket: `<project>-brainfreeze-backups`;
- service account: `brainfreeze-vm@<project>.iam.gserviceaccount.com`.

**Ports on the VM**:

| Port                  | What                                                                   |
| --------------------- | ---------------------------------------------------------------------- |
| 8080                  | HAProxy, public: what the load balancer sends traffic to. `/lb-health` is HAProxy's own check. |
| 127.0.0.1:8081        | HAProxy, local only: the agent reads `/metrics` here.                  |
| 127.0.0.1:8405        | HAProxy's own metrics.                                                 |
| 127.0.0.1:5051…       | the app instances, one each.                                           |

**Settings on the VM**:
- `/etc/brainfreeze/node.env`: instance count, ports, bucket, paths;
- `/etc/brainfreeze/gemdb.env`: the database's environment, as GemDB Code
  sets it.

Both are written on every boot from the instance metadata (`bf-*`
attributes, set in `terraform/compute.tf`).

**Useful commands on the VM**:

```sh
sudo systemctl status gemdb 'brainfreeze-app@*' haproxy
sudo /var/lib/brainfreeze/deploy/node/bin/instances restart   # rolling restart
sudo systemctl start brainfreeze-backup                       # back up now
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,5,18
sudo -iu brainfreeze GemDB/bin/gemdb -c 'import gemdb; print(len(gemdb.root["brainfreeze"]))'
```

**Logs in Cloud Logging** (log name `journal`):

```
logName="projects/<project>/logs/journal" jsonPayload._SYSTEMD_UNIT:"brainfreeze-app@"
logName="projects/<project>/logs/journal" jsonPayload.MESSAGE:"Traceback"
logName="projects/<project>/logs/journal" jsonPayload.MESSAGE:"commit conflict"
```
