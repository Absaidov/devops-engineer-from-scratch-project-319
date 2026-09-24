# Доска объявлений (Kubernetes)

[![hexlet-check](https://github.com/Absaidov/devops-engineer-from-scratch-project-319/actions/workflows/hexlet-check.yml/badge.svg)](https://github.com/Absaidov/devops-engineer-from-scratch-project-319/actions)

Учебная инфраструктура для приложения «Доска объявлений». Исходное приложение и его Docker-образ находятся в отдельном [форке приложения](https://github.com/Absaidov/project-devops-deploy).

На текущем этапе Terraform создаёт в Yandex Cloud:

- VPC, приватную подсеть, NAT gateway и таблицу маршрутизации;
- Managed Service for Kubernetes с одним worker-узлом;
- Managed Service for PostgreSQL без публичного IP;
- приватный Object Storage bucket и сервисный аккаунт приложения;
- Lockbox-секрет с параметрами PostgreSQL и Object Storage.

```text
Internet ── trusted /32 ──> Kubernetes API
                              │
private subnet + NAT ──> worker node ──> Object Storage
                              │
                              └────────> PostgreSQL :6432
                                           (только от SG Kubernetes)
```

Terraform-конфигурация находится в каталоге [`terraform`](terraform/).

## Требования к рабочей машине

- Linux или macOS;
- Git, Make, `curl` и `jq`;
- Terraform `>= 1.6.3`;
- Yandex Cloud CLI (`yc`);
- `kubectl` для проверки кластера;
- активный платёжный аккаунт Yandex Cloud;
- права администратора каталога на время учебного развёртывания, поскольку Terraform создаёт сервисные аккаунты и назначает им роли.

Инфраструктура платная: отдельно тарифицируются master Kubernetes, worker, PostgreSQL, диски, Object Storage и исходящий трафик. После проверки удалите ненужные ресурсы командой `make terraform-destroy`.

## 1. Настройка Yandex Cloud CLI

Установите `yc` по [официальной инструкции](https://yandex.cloud/ru/docs/cli/quickstart#install), затем выполните первичную настройку:

```bash
yc init
yc config list
```

Проверьте, что выбран правильный cloud и folder. Для Terraform создавайте короткоживущий IAM-токен в текущей сессии:

```bash
export YC_TOKEN="$(yc iam create-token)"
```

Токен не записывается в репозиторий. После истечения срока действия выполните команду ещё раз.

## 2. Однократная подготовка backend в Object Storage

State bucket создаётся до `terraform init`, поэтому он не входит в основной Terraform state. Не используйте application bucket для хранения state.

Задайте уникальное имя bucket и создайте отдельный сервисный аккаунт:

```bash
export YC_FOLDER_ID="$(yc config get folder-id)"
export TF_STATE_BUCKET="project-319-tf-state-<уникальный-суффикс>"

yc iam service-account create --name project-319-tf-state

export TF_STATE_SA_ID="$(
  yc iam service-account get \
    --name project-319-tf-state \
    --format json | jq -r '.id'
)"

yc resource-manager folder add-access-binding \
  --id "$YC_FOLDER_ID" \
  --role storage.editor \
  --subject "serviceAccount:$TF_STATE_SA_ID"

yc storage bucket create --name "$TF_STATE_BUCKET"
yc storage bucket update \
  --name "$TF_STATE_BUCKET" \
  --versioning versioning-enabled
```

Создайте статический ключ сервисного аккаунта:

```bash
yc iam access-key create --service-account-id "$TF_STATE_SA_ID"
```

Сохраните показанные `key_id` и `secret` в менеджере паролей: секрет отображается только при создании. Перед работой с Terraform экспортируйте их:

```bash
export AWS_ACCESS_KEY_ID="<key_id>"
export AWS_SECRET_ACCESS_KEY="<secret>"
```

Не добавляйте эти значения в `backend.tf`, `terraform.tfvars` или Git.

## 3. Переменные Terraform

Скопируйте пример:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Заполните в `terraform/terraform.tfvars`:

- `cloud_id` — результат `yc config get cloud-id`;
- `folder_id` — результат `yc config get folder-id`;
- `admin_cidrs` — ваш текущий публичный IPv4 с маской `/32`.

Публичный IP можно определить так:

```bash
curl -4 ifconfig.me
```

Пример: для адреса `198.51.100.24` укажите `admin_cidrs = ["198.51.100.24/32"]`. Значение `0.0.0.0/0` использовать нельзя: Kubernetes API должен быть доступен только доверенному адресу.

`terraform.tfvars` игнорируется Git. Пароли БД и ключ приложения генерируются Terraform и сохраняются в приватном state и Lockbox, поэтому вручную добавлять их не нужно.

## 4. Развёртывание

Все команды выполняются из корня репозитория:

```bash
make terraform-fmt
make terraform-init TF_STATE_BUCKET="$TF_STATE_BUCKET"
make terraform-validate
make terraform-plan
make terraform-apply
make terraform-output
```

`make terraform-plan` формирует неизменяемый план `terraform/project-319.tfplan`, а `make terraform-apply` применяет именно его. Создание Managed Kubernetes и PostgreSQL может занять десятки минут.

Повторный запуск `plan`/`apply` идемпотентен: Terraform изменяет только отличающиеся ресурсы.

## 5. Подключение к Kubernetes

После успешного `apply` получите kubeconfig:

```bash
make terraform-kubeconfig
kubectl cluster-info
kubectl get nodes -o wide
```

Также доступны outputs:

```bash
terraform -chdir=terraform output kubeconfig_command
terraform -chdir=terraform output kubernetes_token_command
terraform -chdir=terraform output -raw kubeconfig > /tmp/project-319-kubeconfig
```

Последний output помечен как sensitive и использует `yc managed-kubernetes create-token`, поэтому в нём нет долгоживущего статического токена.

## 6. Проверка созданных ресурсов

```bash
# Кластер и группа узлов
yc managed-kubernetes cluster get \
  --id "$(terraform -chdir=terraform output -raw kubernetes_cluster_id)"
kubectl get nodes

# PostgreSQL
yc managed-postgresql cluster get \
  --id "$(terraform -chdir=terraform output -raw postgresql_cluster_id)"

# Object Storage
yc storage bucket get \
  --name "$(terraform -chdir=terraform output -raw object_storage_bucket)"

# Lockbox: получить метаданные и payload
export APP_SECRET_ID="$(terraform -chdir=terraform output -raw lockbox_secret_id)"
yc lockbox secret get "$APP_SECRET_ID"
yc lockbox payload get "$APP_SECRET_ID"
```

PostgreSQL не имеет публичного IP и принимает TCP/6432 только от security group Kubernetes. Поэтому проверка реального SQL-подключения выполняется из pod после развёртывания приложения.

## Outputs

| Output | Назначение |
|---|---|
| `kubernetes_cluster_id` | ID Managed Kubernetes |
| `kubernetes_node_group_id` | ID worker-пула |
| `kubernetes_api_endpoint` | адрес Kubernetes API |
| `kubeconfig`, `kubeconfig_command` | kubeconfig и команда его получения |
| `kubernetes_token_command` | команда получения короткоживущего токена |
| `postgresql_cluster_id` | ID Managed PostgreSQL |
| `postgresql_host`, `postgresql_port` | приватный endpoint БД |
| `postgresql_database`, `postgresql_username` | имя БД и пользователя |
| `postgresql_jdbc_url`, `postgresql_connection_string` | JDBC URL и PostgreSQL URI без пароля |
| `object_storage_bucket`, `object_storage_endpoint`, `object_storage_region` | параметры S3 |
| `object_storage_access_key` | идентификатор ключа приложения |
| `object_storage_secret_key` | секретный ключ, sensitive output |
| `lockbox_secret_id` | ID секрета с DB/S3-параметрами |

Значения sensitive outputs скрываются в обычном `terraform output`, но остаются в Terraform state. Поэтому backend bucket закрыт, его ключи не хранятся в репозитории, а versioning защищает state от случайной перезаписи.

## Сеть и порты

| Назначение | Порт | Доступ |
|---|---:|---|
| Kubernetes API | TCP 443, 6443 | только `admin_cidrs` |
| PostgreSQL | TCP 6432 | только security group Kubernetes |
| Worker egress | любой | наружу через NAT gateway |
| Object Storage | HTTPS 443 | по статическому ключу сервисного аккаунта |

Worker не получает публичный IP. Object Storage закрыт для анонимного чтения, просмотра списка и чтения конфигурации.

## Удаление инфраструктуры

Перед удалением очистите application bucket, если в нём появились объекты: `force_destroy` намеренно выключен.

```bash
export YC_TOKEN="$(yc iam create-token)"
make terraform-destroy
```

State bucket и сервисный аккаунт backend не входят в основной state и удаляются отдельно только после завершения проекта.

## Структура Terraform

```text
terraform/
├── backend.tf
├── database.tf
├── iam.tf
├── kubernetes.tf
├── lockbox.tf
├── main.tf
├── network.tf
├── outputs.tf
├── providers.tf
├── storage.tf
├── terraform.tfvars.example
├── variables.tf
└── versions.tf
```

Полезные ссылки: [Terraform в Yandex Cloud](https://yandex.cloud/ru/docs/tutorials/infrastructure-management/terraform-quickstart), [Managed Kubernetes Terraform reference](https://yandex.cloud/ru/docs/managed-kubernetes/tf-ref), [хранение state в Object Storage](https://yandex.cloud/ru/docs/tutorials/infrastructure-management/terraform-state-storage).
