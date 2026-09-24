resource "yandex_iam_service_account" "kubernetes_cluster" {
  folder_id   = var.folder_id
  name        = "${var.project_name}-k8s-cluster"
  description = "Service account used by Managed Kubernetes control plane"
}

resource "yandex_iam_service_account" "kubernetes_nodes" {
  folder_id   = var.folder_id
  name        = "${var.project_name}-k8s-nodes"
  description = "Service account used by Managed Kubernetes worker nodes"
}

resource "yandex_iam_service_account" "object_storage" {
  folder_id   = var.folder_id
  name        = "${var.project_name}-object-storage"
  description = "Service account used by the application to access Object Storage"
}

resource "yandex_resourcemanager_folder_iam_member" "kubernetes_cluster_agent" {
  folder_id = var.folder_id
  role      = "k8s.clusters.agent"
  member    = "serviceAccount:${yandex_iam_service_account.kubernetes_cluster.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "kubernetes_cluster_public_network" {
  folder_id = var.folder_id
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.kubernetes_cluster.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "kubernetes_nodes_image_puller" {
  folder_id = var.folder_id
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.kubernetes_nodes.id}"
}
