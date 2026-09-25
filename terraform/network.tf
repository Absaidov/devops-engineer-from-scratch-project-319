resource "yandex_vpc_network" "application" {
  folder_id   = var.folder_id
  name        = "${var.project_name}-network"
  description = "Network for Managed Kubernetes and PostgreSQL"
  labels      = local.common_labels
}

resource "yandex_vpc_gateway" "nat" {
  folder_id = var.folder_id
  name      = "${var.project_name}-nat-gateway"
  labels    = local.common_labels

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "private" {
  folder_id  = var.folder_id
  name       = "${var.project_name}-private-routes"
  network_id = yandex_vpc_network.application.id
  labels     = local.common_labels

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

resource "yandex_vpc_subnet" "application" {
  folder_id      = var.folder_id
  name           = "${var.project_name}-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.application.id
  v4_cidr_blocks = [var.subnet_cidr]
  route_table_id = yandex_vpc_route_table.private.id
  labels         = local.common_labels
}

resource "yandex_vpc_security_group" "kubernetes" {
  folder_id  = var.folder_id
  name       = "${var.project_name}-kubernetes-sg"
  network_id = yandex_vpc_network.application.id
  labels     = local.common_labels

  ingress {
    protocol          = "ANY"
    description       = "Traffic between control plane and worker nodes"
    predefined_target = "self_security_group"
  }

  ingress {
    protocol          = "TCP"
    description       = "Kubernetes load balancer health checks"
    predefined_target = "loadbalancer_healthchecks"
    port              = 10256
  }

  ingress {
    protocol       = "TCP"
    description    = "Public HTTP traffic to the application NodePort"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 30080
  }

  ingress {
    protocol       = "ANY"
    description    = "Traffic from Kubernetes pods"
    v4_cidr_blocks = [var.cluster_ipv4_range]
  }

  ingress {
    protocol       = "ANY"
    description    = "Traffic from Kubernetes services"
    v4_cidr_blocks = [var.service_ipv4_range]
  }

  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API from trusted administrator networks"
    v4_cidr_blocks = var.admin_cidrs
    port           = 443
  }

  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API tunnel from trusted administrator networks"
    v4_cidr_blocks = var.admin_cidrs
    port           = 6443
  }

  egress {
    protocol       = "ANY"
    description    = "Cluster egress through the NAT gateway"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "postgresql" {
  folder_id  = var.folder_id
  name       = "${var.project_name}-postgresql-sg"
  network_id = yandex_vpc_network.application.id
  labels     = local.common_labels

  ingress {
    protocol          = "TCP"
    description       = "PostgreSQL from Managed Kubernetes only"
    security_group_id = yandex_vpc_security_group.kubernetes.id
    port              = 6432
  }

  egress {
    protocol       = "ANY"
    description    = "PostgreSQL service egress"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
