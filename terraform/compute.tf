# The VM, as an instance template, and two single-zone instance groups to run
# it: one in each zone the data disk is replicated to. The group in
# `active_zone` runs one VM; the other runs none. Failing over between zones
# is changing `active_zone` (README.md).
#
# Each group autoheals: a VM whose HAProxy reports no healthy app instance
# for five minutes is deleted and created again. The new VM's startup script
# takes the data disk over and carries on from the last commit.

resource "google_service_account" "vm" {
  account_id   = "${var.name}-vm"
  display_name = "Brain Freeze VM"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "vm" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# What the startup script needs to take the data disk over: attach it, and
# see who holds it now.
resource "google_project_iam_custom_role" "disk_takeover" {
  role_id = replace("${var.name}_disk_takeover", "-", "_")
  title   = "Brain Freeze VM: take over the data disk"
  permissions = [
    "compute.disks.get",
    "compute.disks.use",
    "compute.instances.attachDisk",
    "compute.instances.detachDisk",
    "compute.instances.get",
    "compute.regionOperations.get",
    "compute.zoneOperations.get",
  ]
}

resource "google_project_iam_member" "disk_takeover" {
  project = var.project_id
  role    = google_project_iam_custom_role.disk_takeover.id
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Changing an instance -- attaching a disk to it -- acts as the account the
# instance runs as, so the VM must be allowed to act as itself. Granted on
# its own account only, not the project's.
resource "google_service_account_iam_member" "vm_acts_as_itself" {
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_storage_bucket_iam_member" "backups" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_instance_template" "vm" {
  name_prefix  = "${var.name}-"
  machine_type = var.machine_type
  tags         = [var.name]
  labels       = { app = var.name }

  disk {
    source_image = var.image
    boot         = true
    auto_delete  = true
    disk_type    = "pd-balanced"
    disk_size_gb = 20
  }

  # No access_config: no external IP.
  network_interface {
    subnetwork = google_compute_subnetwork.main.id
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  # node/startup.sh reads the bf-* attributes. Changing any of them
  # changes the template, and the group replaces the VM: a few minutes of
  # downtime while the new one takes the disk over.
  metadata = {
    startup-script   = file("${path.module}/../node/startup.sh")
    enable-oslogin   = "TRUE"
    bf-data-disk     = local.data_disk
    bf-force-attach  = tostring(var.force_attach)
    bf-app-repo      = var.app_repo
    bf-app-ref       = var.app_ref
    bf-deploy-repo   = var.deploy_repo
    bf-deploy-ref    = var.deploy_ref
    bf-instances     = tostring(var.app_instances)
    bf-gemdb-version = var.gemdb_code_version
    bf-node-version  = var.node_version
    bf-bucket        = google_storage_bucket.backups.name
    bf-page-cache-mb = var.page_cache_mb == null ? "" : tostring(var.page_cache_mb)
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Slower than the load balancer's: the load balancer stops sending traffic
# in seconds, but replacing the VM costs minutes of downtime, so autohealing
# waits out a database restart (bin/watchdog) first.
resource "google_compute_health_check" "autoheal" {
  name                = "${var.name}-autoheal"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 1
  unhealthy_threshold = 10

  http_health_check {
    port         = 8080
    request_path = "/lb-health"
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_instance_group_manager" "vm" {
  for_each = toset(var.zones)

  name               = "${var.name}-${each.key}"
  zone               = each.key
  base_instance_name = var.name
  target_size        = each.key == var.active_zone ? 1 : 0
  wait_for_instances = false

  # A VM booted before its permissions exist waits for them (startup.sh
  # retries), but need not.
  depends_on = [
    google_project_iam_member.vm,
    google_project_iam_member.disk_takeover,
    google_service_account_iam_member.vm_acts_as_itself,
    google_storage_bucket_iam_member.backups,
  ]

  version {
    instance_template = google_compute_instance_template.vm.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.autoheal.id
    initial_delay_sec = var.autoheal_initial_delay_sec
  }

  # The old VM goes before the new one starts: two VMs never want the disk
  # at once.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    replacement_method    = "RECREATE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }

  lifecycle {
    precondition {
      condition     = contains(var.zones, var.active_zone)
      error_message = "active_zone must be one of zones: the data disk is only in those two."
    }
  }
}
