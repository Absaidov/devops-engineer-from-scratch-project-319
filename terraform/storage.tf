resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "yandex_storage_bucket" "application" {
  folder_id = var.folder_id
  bucket    = local.app_bucket_name

  default_storage_class = "STANDARD"
  force_destroy         = false
  max_size              = var.app_bucket_max_size_bytes

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }
}

resource "yandex_storage_bucket_iam_binding" "application" {
  bucket = yandex_storage_bucket.application.bucket
  role   = "storage.uploader"

  members = [
    "serviceAccount:${yandex_iam_service_account.object_storage.id}",
  ]
}

resource "yandex_iam_service_account_static_access_key" "application" {
  service_account_id = yandex_iam_service_account.object_storage.id
  description        = "S3-compatible key for ${var.project_name} application"

  depends_on = [yandex_storage_bucket_iam_binding.application]
}
