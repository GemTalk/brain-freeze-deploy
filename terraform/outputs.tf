output "static_ip" {
  description = "Point the domain's A record here, unless dns_managed_zone does it for you, and each of extra_domains'. It never changes."
  value       = google_compute_global_address.site.address
}

output "url" {
  value = "https://${var.domain}/"
}

output "backups_bucket" {
  value = "gs://${google_storage_bucket.backups.name}"
}

output "data_disk" {
  description = "The regional disk the VM serves from."
  value       = local.data_disk
}

output "active_group" {
  description = "The instance group running the VM. deploy.sh finds the VM through it."
  value       = google_compute_instance_group_manager.vm[var.active_zone].name
}

output "active_zone" {
  value = var.active_zone
}

output "project_id" {
  value = var.project_id
}

output "dashboard" {
  value = "https://console.cloud.google.com/monitoring/dashboards/custom/${element(split("/", google_monitoring_dashboard.site.id), length(split("/", google_monitoring_dashboard.site.id)) - 1)}?project=${var.project_id}"
}

output "region" {
  value = var.region
}

output "zones" {
  description = "The two zones the data disk is in; active_zone is one of them."
  value       = var.zones
}
