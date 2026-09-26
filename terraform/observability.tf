resource "yandex_logging_group" "application" {
  folder_id        = var.folder_id
  name             = "${var.project_name}-application-logs"
  description      = "Application pod logs collected from the bulletins namespace"
  retention_period = var.logging_retention_period
  labels           = local.common_labels
}

resource "yandex_iam_service_account" "monitoring" {
  folder_id   = var.folder_id
  name        = "${var.project_name}-monitoring"
  description = "Writes application and Kubernetes metrics to Managed Prometheus"
}

resource "yandex_resourcemanager_folder_iam_member" "monitoring_editor" {
  folder_id = var.folder_id
  role      = "monitoring.editor"
  member    = "serviceAccount:${yandex_iam_service_account.monitoring.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "kubernetes_nodes_logging_writer" {
  folder_id = var.folder_id
  role      = "logging.writer"
  member    = "serviceAccount:${yandex_iam_service_account.kubernetes_nodes.id}"
}

resource "yandex_lockbox_secret" "observability" {
  folder_id           = var.folder_id
  name                = "${var.project_name}-observability"
  description         = "Managed Prometheus API key used by the in-cluster collector"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels
}

resource "yandex_iam_service_account_api_key" "monitoring" {
  service_account_id = yandex_iam_service_account.monitoring.id
  description        = "Managed Prometheus remote write key"
  scopes             = ["yc.monitoring.manage"]

  # The provider still reads the deprecated singular `scope` field alongside
  # `scopes`, which otherwise produces a perpetual in-place diff.
  lifecycle {
    ignore_changes = [scope]
  }

  output_to_lockbox {
    secret_id            = yandex_lockbox_secret.observability.id
    entry_for_secret_key = "PROMETHEUS_API_KEY"
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_member.monitoring_editor,
  ]
}

resource "yandex_monitoring_dashboard" "kubernetes" {
  folder_id   = var.folder_id
  name        = "${var.project_name}-kubernetes"
  title       = "${var.project_name}: Kubernetes"
  description = "Native Managed Kubernetes metrics. Application Prometheus panels are documented in monitoring/dashboards/application-overview.json."
  labels      = local.common_labels

  widgets {
    chart {
      chart_id       = "application-cpu"
      title          = "Application CPU limit utilization"
      display_legend = true

      queries {
        target {
          query = "\"container.cpu.limit_utilization\"{folderId=\"${var.folder_id}\", service=\"managed-kubernetes\", cluster_id=\"${yandex_kubernetes_cluster.application.id}\", namespace=\"bulletins\", container=\"application\"}"
        }
      }

      visualization_settings {
        type        = "VISUALIZATION_TYPE_LINE"
        interpolate = "INTERPOLATE_LINEAR"
        show_labels = true
        yaxis_settings {
          left {
            min         = "0"
            max         = "1"
            title       = "CPU"
            type        = "YAXIS_TYPE_LINEAR"
            unit_format = "UNIT_PERCENT_UNIT"
          }
        }
      }
    }

    position {
      x = 0
      y = 0
      w = 18
      h = 8
    }
  }

  widgets {
    chart {
      chart_id       = "application-memory"
      title          = "Application memory limit utilization"
      display_legend = true

      queries {
        target {
          query = "\"container.memory.limit_utilization\"{folderId=\"${var.folder_id}\", service=\"managed-kubernetes\", cluster_id=\"${yandex_kubernetes_cluster.application.id}\", namespace=\"bulletins\", container=\"application\"}"
        }
      }

      visualization_settings {
        type        = "VISUALIZATION_TYPE_LINE"
        interpolate = "INTERPOLATE_LINEAR"
        show_labels = true
        yaxis_settings {
          left {
            min         = "0"
            max         = "1"
            title       = "RAM"
            type        = "YAXIS_TYPE_LINEAR"
            unit_format = "UNIT_PERCENT_UNIT"
          }
        }
      }
    }

    position {
      x = 18
      y = 0
      w = 18
      h = 8
    }
  }

  widgets {
    chart {
      chart_id       = "application-working-set"
      title          = "Application working set"
      display_legend = true

      queries {
        target {
          query = "\"container.memory.working_set_bytes\"{folderId=\"${var.folder_id}\", service=\"managed-kubernetes\", cluster_id=\"${yandex_kubernetes_cluster.application.id}\", namespace=\"bulletins\", container=\"application\"}"
        }
      }

      visualization_settings {
        type        = "VISUALIZATION_TYPE_LINE"
        interpolate = "INTERPOLATE_LINEAR"
        show_labels = true
        yaxis_settings {
          left {
            min         = "0"
            title       = "Memory"
            type        = "YAXIS_TYPE_LINEAR"
            unit_format = "UNIT_BYTES_SI"
          }
        }
      }
    }

    position {
      x = 0
      y = 8
      w = 18
      h = 8
    }
  }

  widgets {
    chart {
      chart_id       = "application-restarts"
      title          = "Application container restarts"
      display_legend = true

      queries {
        target {
          query = "\"container.restart_count\"{folderId=\"${var.folder_id}\", service=\"managed-kubernetes\", cluster_id=\"${yandex_kubernetes_cluster.application.id}\", namespace=\"bulletins\", container=\"application\"}"
        }
      }

      visualization_settings {
        type        = "VISUALIZATION_TYPE_LINE"
        interpolate = "INTERPOLATE_LEFT"
        show_labels = true
        yaxis_settings {
          left {
            min         = "0"
            title       = "Restarts"
            type        = "YAXIS_TYPE_LINEAR"
            unit_format = "UNIT_COUNT"
          }
        }
      }
    }

    position {
      x = 18
      y = 8
      w = 18
      h = 8
    }
  }
}
