# The front door: a global external Application Load Balancer.
#
# The static IP and the managed certificate are what keep every link to the
# site -- a policy, its ID card, a claim -- working for good: the domain
# points at an address that never changes, whichever VM or zone is serving.
# HTTP is redirected to HTTPS. Cloud Armor limits how fast one client can ask
# and, more tightly, how fast it can write.

resource "google_compute_global_address" "site" {
  name       = "${var.name}-ip"
  depends_on = [google_project_service.apis]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_managed_ssl_certificate" "site" {
  # Named for the domain, so a new domain gets a new certificate before the
  # old one goes.
  name = "${var.name}-${substr(sha1(var.domain), 0, 8)}"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# One certificate each, not one for all: a managed certificate is issued only
# once every domain on it resolves here, so one domain's DNS would hold up
# the others'.
resource "google_compute_managed_ssl_certificate" "extra" {
  for_each = toset(var.extra_domains)
  name     = "${var.name}-${substr(sha1(each.key), 0, 8)}"

  managed {
    domains = [each.key]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_dns_record_set" "site" {
  count        = var.dns_managed_zone == "" ? 0 : 1
  managed_zone = var.dns_managed_zone
  name         = "${var.domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.site.address]
}

# Fast, unlike autohealing's: a VM whose instances are all down leaves the
# rotation within 15 seconds. /lb-health is HAProxy's own answer, 200 while
# any app instance is healthy (node/bin/haproxy-config).
resource "google_compute_health_check" "lb" {
  name                = "${var.name}-lb"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/lb-health"
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_security_policy" "edge" {
  name        = "${var.name}-edge"
  description = "Rate limits for Ice Cream Brain Freeze Insurance."
  type        = "CLOUD_ARMOR"

  rule {
    priority    = 1000
    action      = "throttle"
    description = "Writes: every quote, policy and claim is stored."
    match {
      expr {
        expression = "request.method == 'POST'"
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.writes_per_minute
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 2000
    action      = "throttle"
    description = "Everything else."
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.requests_per_minute
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 2147483647
    action      = "allow"
    description = "Default."
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_backend_service" "app" {
  name                  = "${var.name}-app"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  # Past HAProxy's own 55s server timeout (node/bin/haproxy-config).
  timeout_sec                     = 60
  connection_draining_timeout_sec = 30
  health_checks                   = [google_compute_health_check.lb.id]
  security_policy                 = google_compute_security_policy.edge.id

  # Both zones' groups; only the active one has a VM in it.
  dynamic "backend" {
    for_each = google_compute_instance_group_manager.vm
    content {
      group           = backend.value.instance_group
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1.0
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "https" {
  name            = "${var.name}-https"
  default_service = google_compute_backend_service.app.id
}

resource "google_compute_ssl_policy" "modern" {
  name            = "${var.name}-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
  depends_on      = [google_project_service.apis]
}

resource "google_compute_target_https_proxy" "site" {
  name             = "${var.name}-https"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = concat([google_compute_managed_ssl_certificate.site.id], [for c in google_compute_managed_ssl_certificate.extra : c.id])
  ssl_policy       = google_compute_ssl_policy.modern.id
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name}-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.site.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.site.id
}

resource "google_compute_url_map" "http_redirect" {
  name = "${var.name}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "${var.name}-http-redirect"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.site.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
