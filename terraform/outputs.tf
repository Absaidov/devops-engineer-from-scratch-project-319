output "network_id" {
  description = "VPC network ID."
  value       = yandex_vpc_network.application.id
}

output "subnet_id" {
  description = "Private subnet ID."
  value       = yandex_vpc_subnet.application.id
}

output "kubernetes_cluster_id" {
  description = "Managed Kubernetes cluster ID."
  value       = yandex_kubernetes_cluster.application.id
}

output "kubernetes_node_group_id" {
  description = "Managed Kubernetes worker group ID."
  value       = yandex_kubernetes_node_group.application.id
}

output "kubernetes_api_endpoint" {
  description = "Public Kubernetes API endpoint."
  value       = yandex_kubernetes_cluster.application.master[0].external_v4_endpoint
}

output "kubeconfig_command" {
  description = "Recommended command for writing short-lived credentials to the local kubeconfig."
  value       = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.application.id} --external --force"
}

output "kubernetes_token_command" {
  description = "Command used by kubeconfig to request a short-lived Kubernetes token."
  value       = "yc managed-kubernetes create-token"
}

output "kubeconfig" {
  description = "Generated kubeconfig using the YC CLI exec authentication plugin."
  value       = local.kubeconfig
  sensitive   = true
}

output "postgresql_cluster_id" {
  description = "Managed PostgreSQL cluster ID."
  value       = yandex_mdb_postgresql_cluster.application.id
}

output "postgresql_host" {
  description = "Private PostgreSQL host FQDN."
  value       = local.database_host
}

output "postgresql_port" {
  description = "Managed PostgreSQL connection port."
  value       = 6432
}

output "postgresql_database" {
  description = "Application database name."
  value       = yandex_mdb_postgresql_database.application.name
}

output "postgresql_username" {
  description = "Application database user."
  value       = yandex_mdb_postgresql_user.application.name
}

output "postgresql_jdbc_url" {
  description = "JDBC URL without credentials. The CA certificate must be mounted by the workload."
  value       = "jdbc:postgresql://${local.database_host}:6432/${yandex_mdb_postgresql_database.application.name}?sslmode=verify-full&targetServerType=master&loadBalanceHosts=true"
}

output "postgresql_connection_string" {
  description = "PostgreSQL connection URI without credentials."
  value       = "postgresql://${local.database_host}:6432/${yandex_mdb_postgresql_database.application.name}?sslmode=verify-full&target_session_attrs=read-write"
}

output "object_storage_bucket" {
  description = "Private Object Storage bucket name."
  value       = yandex_storage_bucket.application.bucket
}

output "object_storage_endpoint" {
  description = "S3-compatible endpoint."
  value       = "https://storage.yandexcloud.net"
}

output "object_storage_region" {
  description = "Object Storage region used by S3-compatible clients."
  value       = "ru-central1"
}

output "object_storage_access_key" {
  description = "S3 access key ID for the application."
  value       = yandex_iam_service_account_static_access_key.application.access_key
}

output "object_storage_secret_key" {
  description = "S3 secret key. Prefer reading it from Lockbox."
  value       = yandex_iam_service_account_static_access_key.application.secret_key
  sensitive   = true
}

output "lockbox_secret_id" {
  description = "Lockbox secret containing DB and S3 parameters."
  value       = yandex_lockbox_secret.application.id
}

output "lockbox_secret_version_id" {
  description = "Current application Lockbox secret version ID."
  value       = yandex_lockbox_secret_version.application.id
}
