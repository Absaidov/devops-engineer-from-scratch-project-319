resource "yandex_kubernetes_cluster" "application" {
  folder_id  = var.folder_id
  name       = "${var.project_name}-cluster"
  network_id = yandex_vpc_network.application.id

  cluster_ipv4_range = var.cluster_ipv4_range
  service_ipv4_range = var.service_ipv4_range
  release_channel    = "REGULAR"

  service_account_id      = yandex_iam_service_account.kubernetes_cluster.id
  node_service_account_id = yandex_iam_service_account.kubernetes_nodes.id

  labels = local.common_labels

  master {
    zonal {
      zone      = var.zone
      subnet_id = yandex_vpc_subnet.application.id
    }

    public_ip          = true
    security_group_ids = [yandex_vpc_security_group.kubernetes.id]

    maintenance_policy {
      auto_upgrade = true
    }
  }

  network_policy_provider = "CALICO"

  depends_on = [
    yandex_resourcemanager_folder_iam_member.kubernetes_cluster_agent,
    yandex_resourcemanager_folder_iam_member.kubernetes_cluster_public_network,
    yandex_resourcemanager_folder_iam_member.kubernetes_nodes_image_puller,
  ]
}

resource "yandex_kubernetes_node_group" "application" {
  cluster_id  = yandex_kubernetes_cluster.application.id
  name        = "${var.project_name}-workers"
  description = "Application worker pool"

  labels = local.common_labels

  instance_template {
    platform_id = var.node_platform_id

    resources {
      cores         = var.node_cores
      memory        = var.node_memory_gb
      core_fraction = var.node_core_fraction
    }

    boot_disk {
      type = "network-hdd"
      size = var.node_disk_size_gb
    }

    network_interface {
      nat                = false
      subnet_ids         = [yandex_vpc_subnet.application.id]
      security_group_ids = [yandex_vpc_security_group.kubernetes.id]
    }

    scheduling_policy {
      preemptible = var.node_preemptible
    }

    container_runtime {
      type = "containerd"
    }
  }

  scale_policy {
    fixed_scale {
      size = var.node_count
    }
  }

  allocation_policy {
    location {
      zone = var.zone
    }
  }

  maintenance_policy {
    auto_upgrade = true
    auto_repair  = true
  }
}
