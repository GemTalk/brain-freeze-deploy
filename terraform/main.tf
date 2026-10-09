# Ice Cream Brain Freeze Insurance on Google Cloud.
#
#   visitors ─▶ global HTTPS load balancer (static IP, managed certificate,
#               Cloud Armor rate limits)
#           ─▶ one VM, in whichever of two zones `active_zone` names
#               HAProxy :8080 ─▶ N Flask instances, one request at a time each
#                              ─▶ GemDB (GemStone 4.0.0) on a regional disk
#
# The VM is disposable: everything that matters is on the regional disk,
# which is replicated synchronously into both zones, snapshotted, and backed
# up to Cloud Storage. README.md is the runbook.

locals {
  # The disk the VM serves from: Terraform's, unless a restore says otherwise.
  data_disk = var.data_disk_override != "" ? var.data_disk_override : google_compute_region_disk.data.name

  apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(concat(local.apis, var.dns_managed_zone == "" ? [] : ["dns.googleapis.com"]))
  service            = each.value
  disable_on_destroy = false
}
