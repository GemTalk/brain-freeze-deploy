# Where the data lives, apart from any VM.
#
# 1. The regional disk: the engine, the database and its transaction logs,
#    and the app's checkout. Written synchronously in both zones, so losing a
#    zone loses no commit. Never destroyed by Terraform.
# 2. Snapshots of it, every few hours: the quick way back from a bad release
#    or a mistake in a notebook.
# 3. Daily GemStone backups and every transaction log, in a bucket: the way
#    back if the disk and its snapshots are both gone.

resource "google_compute_region_disk" "data" {
  name                      = "${var.name}-data"
  region                    = var.region
  replica_zones             = var.zones
  type                      = "pd-balanced"
  size                      = var.data_disk_size_gb
  physical_block_size_bytes = 4096

  depends_on = [google_project_service.apis]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_resource_policy" "snapshots" {
  name   = "${var.name}-snapshots"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      hourly_schedule {
        hours_in_cycle = var.snapshot_every_hours
        start_time     = "00:00"
      }
    }
    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      labels            = { app = var.name }
      storage_locations = [var.region]
    }
  }
}

# On whichever disk is serving, so a restored disk is snapshotted too.
resource "google_compute_region_disk_resource_policy_attachment" "snapshots" {
  name   = google_compute_resource_policy.snapshots.name
  disk   = local.data_disk
  region = var.region
}

resource "google_storage_bucket" "backups" {
  name                        = "${var.project_id}-${var.name}-backups"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]

  lifecycle {
    prevent_destroy = true
  }
}
