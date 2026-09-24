resource "random_password" "postgresql" {
  length  = 32
  special = false
}

resource "yandex_mdb_postgresql_cluster" "application" {
  folder_id           = var.folder_id
  name                = "${var.project_name}-postgresql"
  environment         = "PRODUCTION"
  network_id          = yandex_vpc_network.application.id
  security_group_ids  = [yandex_vpc_security_group.postgresql.id]
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  config {
    version = var.postgresql_version

    resources {
      resource_preset_id = var.postgresql_resource_preset_id
      disk_type_id       = var.postgresql_disk_type_id
      disk_size          = var.postgresql_disk_size_gb
    }

    access {
      data_lens     = false
      data_transfer = false
      serverless    = false
      web_sql       = false
    }
  }

  host {
    zone             = var.zone
    subnet_id        = yandex_vpc_subnet.application.id
    assign_public_ip = false
  }

  maintenance_window {
    type = "ANYTIME"
  }
}

resource "yandex_mdb_postgresql_user" "application" {
  cluster_id = yandex_mdb_postgresql_cluster.application.id
  name       = var.postgresql_username
  password   = random_password.postgresql.result
  conn_limit = 50
}

resource "yandex_mdb_postgresql_database" "application" {
  cluster_id = yandex_mdb_postgresql_cluster.application.id
  name       = var.postgresql_database
  owner      = yandex_mdb_postgresql_user.application.name
}
