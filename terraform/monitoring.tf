# What to look at, in Cloud Monitoring.
#
# Three sources, all native to Cloud Monitoring:
#
# - The load balancer and the VM: request counts by status class, latency,
#   CPU and memory. Google records these with nothing to install.
# - Prometheus metrics, from the Ops Agent on the VM
#   (node/ops-agent.yaml): HAProxy's (haproxy_*) and the app's
#   /metrics (brainfreeze_*, gemdb_*). Queried here in PromQL.
# - Two counts made from the VM's logs: commit conflicts
#   (brain-freeze's web/conflicts.py) and finished backups (node/bin/backup).

locals {
  journal = "logName=\"projects/${var.project_id}/logs/journal\""

  notify = var.alert_email == "" ? [] : [google_monitoring_notification_channel.email[0].id]

  # A PromQL chart, for the dashboard.
  promql = {
    queue       = "max(haproxy_backend_current_queue{proxy=\"app\"})"
    servers_up  = "max(haproxy_backend_active_servers{proxy=\"app\"})"
    server_time = "max by (server) (haproxy_server_response_time_average_seconds{proxy=\"app\"})"
    responses   = "sum by (code) (rate(haproxy_backend_http_responses_total{proxy=\"app\"}[5m]))"
    policies    = "max(brainfreeze_policies)"
    sold        = "max(delta(brainfreeze_quotes{accepted=\"true\"}[1h]))"
    quoted      = "sum(delta(brainfreeze_quotes[1h]))"
    claims      = "sum by (outcome) (delta(brainfreeze_claims[1h]))"
    db_free     = "min(gemdb_repository_bytes{part=\"free\"})"
    db_total    = "max(gemdb_repository_bytes{part=\"total\"})"
    sessions    = "max by (kind) (gemdb_sessions)"
    conflicts   = "sum(rate(logging_googleapis_com:user_${var.name}_commit_conflicts[5m]))"
  }
}

# -- counted from the logs ------------------------------------------------------------

resource "google_logging_metric" "commit_conflicts" {
  name   = "${var.name}_commit_conflicts"
  filter = "${local.journal} AND jsonPayload.MESSAGE:\"commit conflict\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
  depends_on = [google_project_service.apis]
}

resource "google_logging_metric" "backups" {
  name   = "${var.name}_backups"
  filter = "${local.journal} AND jsonPayload.MESSAGE:\"Backed up to gs://\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
  depends_on = [google_project_service.apis]
}

# -- is it up, from outside -------------------------------------------------------------

resource "google_monitoring_uptime_check_config" "site" {
  display_name = "Brain Freeze: https://${var.domain}/healthz"
  timeout      = "10s"
  period       = "60s"

  # Through the load balancer, HAProxy and an app instance to the database:
  # "ok" means a visitor's request would have been answered.
  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  content_matchers {
    content = "ok"
    matcher = "CONTAINS_STRING"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain
    }
  }

  depends_on = [google_project_service.apis]
}

# -- who is told ---------------------------------------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  display_name = "Brain Freeze alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# -- what is worth waking for ---------------------------------------------------------------

resource "google_monitoring_alert_policy" "down" {
  display_name          = "Brain Freeze: the site is down"
  combiner              = "OR"
  notification_channels = local.notify

  conditions {
    display_name = "Uptime check failing from two or more regions"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.site.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "120s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  documentation {
    content = "https://${var.domain}/healthz is not answering \"ok\". README.md, \"When it is down\"."
  }
}

resource "google_monitoring_alert_policy" "instances" {
  display_name          = "Brain Freeze: fewer app instances than configured"
  combiner              = "OR"
  notification_channels = local.notify

  conditions {
    display_name = "HAProxy sees fewer than ${var.app_instances} healthy instances"
    condition_prometheus_query_language {
      query               = "${local.promql.servers_up} < ${var.app_instances}"
      duration            = "300s"
      evaluation_interval = "60s"
    }
  }

  documentation {
    content = "The site is still up on the others. `sudo systemctl status 'brainfreeze-app@*'` on the VM."
  }
}

resource "google_monitoring_alert_policy" "errors" {
  display_name          = "Brain Freeze: more than 5% of responses are 5xx"
  combiner              = "OR"
  notification_channels = local.notify

  conditions {
    display_name = "5xx over 5% of responses, for 10 minutes"
    condition_prometheus_query_language {
      query               = "sum(rate(haproxy_backend_http_responses_total{proxy=\"app\",code=\"5xx\"}[5m])) / sum(rate(haproxy_backend_http_responses_total{proxy=\"app\"}[5m])) > 0.05"
      duration            = "600s"
      evaluation_interval = "60s"
    }
  }

  documentation {
    content = "Tracebacks are in Cloud Logging: logName=\"projects/${var.project_id}/logs/journal\" jsonPayload.MESSAGE:\"Traceback\". A 503 that says \"Too many people are writing\" is brain-freeze's web/conflicts.py giving up."
  }
}

resource "google_monitoring_alert_policy" "queue" {
  display_name          = "Brain Freeze: requests are queueing"
  combiner              = "OR"
  notification_channels = local.notify

  conditions {
    display_name = "More than 10 requests waiting for an instance, for 5 minutes"
    condition_prometheus_query_language {
      query               = "${local.promql.queue} > 10"
      duration            = "300s"
      evaluation_interval = "60s"
    }
  }

  documentation {
    content = "Every instance is busy. Raise app_instances (up to 6 on the free license) and machine_type."
  }
}

resource "google_monitoring_alert_policy" "database_full" {
  display_name          = "Brain Freeze: the database is filling up"
  combiner              = "OR"
  notification_channels = local.notify

  conditions {
    display_name = "Less than 1.5 GB free in the extent"
    condition_prometheus_query_language {
      query               = "${local.promql.db_free} < 1.5e9"
      duration            = "900s"
      evaluation_interval = "300s"
    }
  }

  documentation {
    content = "The free license caps the database at 10 GB. Collect garbage now (`sudo systemctl start brainfreeze-gc`), and look at what is writing."
  }
}

resource "google_monitoring_alert_policy" "backups" {
  display_name          = "Brain Freeze: no backup in 26 hours"
  combiner              = "OR"
  notification_channels = local.notify

  conditions {
    display_name = "No \"Backed up to gs://\" in the logs for 26 hours"
    condition_prometheus_query_language {
      # Absent, not "increase < 1": a log metric writes nothing while
      # nothing matches, so a stopped backup leaves no series to compare.
      # The first boot backs up at once (provision.sh), so this does not
      # fire for a day after a new deployment.
      query               = "absent_over_time(logging_googleapis_com:user_${var.name}_backups[26h])"
      duration            = "3600s"
      evaluation_interval = "600s"
    }
  }

  documentation {
    content = "`sudo journalctl -u brainfreeze-backup` on the VM says why."
  }
}

# -- the dashboard ------------------------------------------------------------------------------

locals {
  # A chart of one PromQL query.
  prom_chart = { for key, query in local.promql : key => {
    dataSets = [{ timeSeriesQuery = { prometheusQuery = query }, plotType = "LINE" }]
  } }

  # A chart of one Google metric, rate-aligned and grouped.
  lb_filter = "resource.type=\"https_lb_rule\" AND resource.label.forwarding_rule_name=\"${google_compute_global_forwarding_rule.https.name}\""

  tiles = [
    { title = "Requests a second, by status class (load balancer)", chart = {
      dataSets = [{ plotType = "STACKED_AREA", timeSeriesQuery = { timeSeriesFilter = {
        filter      = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND ${local.lb_filter}"
        aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM", groupByFields = ["metric.label.response_code_class"] }
      } } }]
    } },
    { title = "Latency, 50th and 95th percentile (load balancer, ms)", chart = {
      dataSets = [for p in ["50", "95"] : { plotType = "LINE", timeSeriesQuery = { timeSeriesFilter = {
        filter      = "metric.type=\"loadbalancing.googleapis.com/https/total_latencies\" AND ${local.lb_filter}"
        aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_${p}", crossSeriesReducer = "REDUCE_MAX" }
      } } }]
    } },
    { title = "Responses a second, by code (HAProxy)", chart = local.prom_chart.responses },
    { title = "Healthy app instances", chart = local.prom_chart.servers_up },
    { title = "Requests waiting for a free instance", chart = local.prom_chart.queue },
    { title = "Average response time by instance (s)", chart = local.prom_chart.server_time },
    { title = "Policies on the book", chart = local.prom_chart.policies },
    { title = "Quotes given and policies sold, per hour", chart = {
      dataSets = [
        { plotType = "LINE", timeSeriesQuery = { prometheusQuery = local.promql.quoted } },
        { plotType = "LINE", timeSeriesQuery = { prometheusQuery = local.promql.sold } },
      ]
    } },
    { title = "Claims filed per hour, by outcome", chart = local.prom_chart.claims },
    { title = "Commit conflicts a second (retried)", chart = local.prom_chart.conflicts },
    { title = "Database: extent size and free space (bytes)", chart = {
      dataSets = [
        { plotType = "LINE", timeSeriesQuery = { prometheusQuery = local.promql.db_total } },
        { plotType = "LINE", timeSeriesQuery = { prometheusQuery = local.promql.db_free } },
      ]
    } },
    { title = "Database sessions (the free license allows 10)", chart = local.prom_chart.sessions },
    { title = "VM CPU utilization", chart = {
      dataSets = [{ plotType = "LINE", timeSeriesQuery = { timeSeriesFilter = {
        filter      = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\" AND metadata.user_labels.app=\"${var.name}\""
        aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
      } } }]
    } },
    { title = "VM memory used (%)", chart = {
      dataSets = [{ plotType = "LINE", timeSeriesQuery = { timeSeriesFilter = {
        filter      = "metric.type=\"agent.googleapis.com/memory/percent_used\" AND metric.label.state=\"used\" AND resource.type=\"gce_instance\" AND metadata.user_labels.app=\"${var.name}\""
        aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
      } } }]
    } },
  ]
}

resource "google_monitoring_dashboard" "site" {
  dashboard_json = jsonencode({
    displayName = "Ice Cream Brain Freeze Insurance"
    mosaicLayout = {
      columns = 12
      tiles = [for i, tile in local.tiles : {
        xPos   = (i % 2) * 6
        yPos   = floor(i / 2) * 4
        width  = 6
        height = 4
        widget = { title = tile.title, xyChart = tile.chart }
      }]
    }
  })
  depends_on = [google_project_service.apis]
}
