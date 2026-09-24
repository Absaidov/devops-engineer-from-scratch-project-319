locals {
  common_labels = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }

  app_bucket_name = var.app_bucket_name != null ? var.app_bucket_name : "${var.project_name}-${random_id.bucket_suffix.hex}"
  database_host   = one(yandex_mdb_postgresql_cluster.application.host[*].fqdn)

  kubeconfig = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = yandex_kubernetes_cluster.application.name
      cluster = {
        server                       = yandex_kubernetes_cluster.application.master[0].external_v4_endpoint
        "certificate-authority-data" = base64encode(yandex_kubernetes_cluster.application.master[0].cluster_ca_certificate)
      }
    }]
    contexts = [{
      name = yandex_kubernetes_cluster.application.name
      context = {
        cluster = yandex_kubernetes_cluster.application.name
        user    = "yc"
      }
    }]
    "current-context" = yandex_kubernetes_cluster.application.name
    users = [{
      name = "yc"
      user = {
        exec = {
          apiVersion         = "client.authentication.k8s.io/v1beta1"
          command            = "yc"
          args               = ["managed-kubernetes", "create-token"]
          interactiveMode    = "IfAvailable"
          provideClusterInfo = false
        }
      }
    }]
  })
}
