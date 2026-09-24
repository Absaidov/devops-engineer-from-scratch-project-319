resource "yandex_lockbox_secret" "application" {
  folder_id           = var.folder_id
  name                = "${var.project_name}-application"
  description         = "Database and Object Storage settings for the application"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels
}

resource "yandex_lockbox_secret_version" "application" {
  secret_id   = yandex_lockbox_secret.application.id
  description = "Application infrastructure credentials managed by Terraform"

  entries {
    key        = "DB_HOST"
    text_value = local.database_host
  }

  entries {
    key        = "DB_PORT"
    text_value = "6432"
  }

  entries {
    key        = "DB_NAME"
    text_value = yandex_mdb_postgresql_database.application.name
  }

  entries {
    key        = "DB_USER"
    text_value = yandex_mdb_postgresql_user.application.name
  }

  entries {
    key        = "DB_PASSWORD"
    text_value = random_password.postgresql.result
  }

  entries {
    key        = "S3_ENDPOINT"
    text_value = "https://storage.yandexcloud.net"
  }

  entries {
    key        = "S3_REGION"
    text_value = "ru-central1"
  }

  entries {
    key        = "S3_BUCKET"
    text_value = yandex_storage_bucket.application.bucket
  }

  entries {
    key        = "S3_ACCESS_KEY"
    text_value = yandex_iam_service_account_static_access_key.application.access_key
  }

  entries {
    key        = "S3_SECRET_KEY"
    text_value = yandex_iam_service_account_static_access_key.application.secret_key
  }
}

resource "yandex_lockbox_secret_iam_member" "kubernetes_nodes" {
  secret_id = yandex_lockbox_secret.application.id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.kubernetes_nodes.id}"
}
