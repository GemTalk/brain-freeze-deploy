# A network of its own. The VM has no external IP: visitors reach it only
# through the load balancer, operators only through IAP, and it reaches the
# internet (apt, GitHub, GemDB's engine download) through Cloud NAT. Nothing
# outside can reach the database's stone or NetLDI, which run with GemDB
# Code's stock DataCurator password.

resource "google_compute_network" "main" {
  name                    = var.name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name                     = var.name
  region                   = var.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = "10.20.0.0/24"
  private_ip_google_access = true
}

resource "google_compute_router" "main" {
  name    = var.name
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = var.name
  region                             = var.region
  router                             = google_compute_router.main.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# HAProxy's port, from the load balancer and Google's health checkers only.
resource "google_compute_firewall" "load_balancer" {
  name          = "${var.name}-load-balancer"
  network       = google_compute_network.main.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = [var.name]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

# SSH, through Identity-Aware Proxy only: `gcloud compute ssh --tunnel-through-iap`.
resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.name}-iap-ssh"
  network       = google_compute_network.main.id
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [var.name]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
