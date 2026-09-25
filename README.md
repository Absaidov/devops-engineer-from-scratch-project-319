# Доска объявлений (Kubernetes)

[![hexlet-check](https://github.com/Absaidov/devops-engineer-from-scratch-project-319/actions/workflows/hexlet-check.yml/badge.svg)](https://github.com/Absaidov/devops-engineer-from-scratch-project-319/actions)

Учебная инфраструктура для приложения «Доска объявлений». Исходное приложение и его Docker-образ находятся в отдельном [форке приложения](https://github.com/Absaidov/project-devops-deploy).

На текущем этапе Terraform создаёт в Yandex Cloud:

- VPC, приватную подсеть, NAT gateway и таблицу маршрутизации;
- Managed Service for Kubernetes с двумя worker-узлами;
- Managed Service for PostgreSQL без публичного IP;
- приватный Object Storage bucket и сервисный аккаунт приложения;
- Lockbox-секрет с параметрами PostgreSQL и Object Storage.

```text
Internet ── trusted /32 ──> Kubernetes API
Internet ──> Network Load Balancer :80 ──> worker nodes :30080
                                                │
private subnet + NAT ───────────────────────────┼──> Object Storage
                                                └──> PostgreSQL :6432
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
| Публичное приложение | TCP 80 | через Network Load Balancer |
| HTTP NodePort приложения | TCP 30080 | входящий трафик балансировщика к worker-узлам |
| Проверка worker-узлов балансировщиком | TCP 10256 | только `loadbalancer_healthchecks` Yandex Cloud |
| PostgreSQL | TCP 6432 | только security group Kubernetes |
| Worker egress | любой | наружу через NAT gateway |
| Object Storage | HTTPS 443 | по статическому ключу сервисного аккаунта |

Worker не получает публичный IP. Object Storage закрыт для анонимного чтения, просмотра списка и чтения конфигурации.

## Kubernetes-манифесты и первичный деплой

Манифесты приложения находятся в каталоге [`k8s`](k8s/):

```text
k8s/
├── namespace.yaml
├── configmap.yaml
├── secret.example.yaml
├── migration-configmap.yaml
├── deployment.yaml
├── service.yaml
├── load-balancer.yaml
├── pod-disruption-budget.yaml
├── sync-secret.sh
├── public-check.sh
└── rolling-update-check.sh
```

Deployment запускает две реплики приложения с `RollingUpdate`
(`maxUnavailable: 0`, `maxSurge: 1`): при обновлении сначала поднимается новый
pod, а старый удаляется только после его готовности. Настроены resource
requests/limits и проверки `startup`, `readiness`, `liveness` на
management-порту `9090`. Перед каждым новым pod init-контейнер Flyway
идемпотентно применяет SQL-миграции. `topologySpreadConstraints` и обязательная
pod anti-affinity по `pod-template-hash` размещают реплики одной ревизии на
разных worker-узлах, не блокируя RollingUpdate между ревизиями.
PodDisruptionBudget сохраняет минимум одну доступную реплику при добровольном
disruption. Внутренний Service `bulletins` имеет тип `ClusterIP` и публикует
порты `80` и `9090`; отдельный Service `bulletins-public` публикует только
HTTP/80 через Yandex Network Load Balancer.

### Подключение kubectl

При прямой доступности Kubernetes API достаточно выполнить:

```bash
make terraform-kubeconfig
kubectl get nodes
```

Если провайдер блокирует прямое соединение с публичным API, используйте
доверенную jump host, чей публичный адрес добавлен в `admin_cidrs`. В первом
терминале оставьте SSH-туннель запущенным:

```bash
export K8S_API_IP="$(
  terraform -chdir=terraform output -raw kubernetes_api_endpoint \
    | sed 's#https://##'
)"
export BASTION_IP="<публичный-IP-jump-host>"

ssh -N -L "127.0.0.1:8443:${K8S_API_IP}:443" "ubuntu@${BASTION_IP}"
```

Во втором терминале подготовьте отдельный kubeconfig, не меняя основной:

```bash
cp ~/.kube/config /tmp/project-319-kubeconfig
export KUBECONFIG=/tmp/project-319-kubeconfig
export K8S_API_IP="$(
  terraform -chdir=terraform output -raw kubernetes_api_endpoint \
    | sed 's#https://##'
)"
export K8S_CLUSTER_NAME="$(
  kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}'
)"

kubectl config set-cluster "$K8S_CLUSTER_NAME" \
  --server=https://127.0.0.1:8443 \
  --tls-server-name="$K8S_API_IP"
kubectl get nodes
```

Туннель должен оставаться открытым во время всех последующих команд `kubectl`.

### Secret и развёртывание

[`k8s/secret.example.yaml`](k8s/secret.example.yaml) описывает только схему
Secret и не содержит рабочих значений. Base64 в Kubernetes не является
шифрованием, поэтому настоящие DB/S3 credentials остаются в Lockbox.

Команда `make k8s-secret` находит Lockbox `project-319-application` через YC
CLI, перекладывает поля `DB_*`/`S3_*` в переменные приложения и применяет
Secret напрямую через stdin. Секретный payload не записывается в репозиторий
или локальный файл. При другом имени Lockbox задайте переменную
`K8S_LOCKBOX_SECRET_NAME`; также можно передать его ID через
`K8S_LOCKBOX_SECRET_ID`.

Для полного первичного деплоя выполните из корня репозитория:

```bash
make k8s-deploy
make k8s-status
make k8s-check
make k8s-public-check
```

`make k8s-deploy` создаёт namespace `bulletins`, синхронизирует Secret,
применяет ConfigMap, миграцию, внутренний и публичный Service, PDB и Deployment,
а затем ждёт успешный rollout. `make k8s-check` временно открывает локальные
порты и проверяет REST API и readiness endpoint. Создание внешнего адреса
балансировщика занимает несколько минут; `make k8s-public-check` дожидается
адреса и выполняет серию запросов к публичному REST endpoint.

Чтобы проверить приложение вручную, оставьте следующую команду работающей:

```bash
make k8s-port-forward
```

В другом терминале выполните:

```bash
curl --fail http://127.0.0.1:8080/api/bulletins
curl --fail http://127.0.0.1:9090/actuator/health/readiness
```

Логи и состояние доступны командами:

```bash
make k8s-status
make k8s-logs
make k8s-public-url
```

Для выката нового immutable image укажите полный Git SHA из CI приложения:

```bash
make k8s-deploy K8S_IMAGE_TAG=<40-символьный-Git-SHA>
```

## Масштабирование, балансировка и zero-downtime релизы

Для этого этапа `node_count` равен `2`. Сначала примените Terraform и убедитесь,
что план содержит только ожидаемое масштабирование node group, новую IAM-роль
`load-balancer.admin`, публичный TCP/30080 и TCP/10256 только для health checks;
замен и удалений быть не должно:

```bash
export YC_TOKEN="$(yc iam create-token)"
make terraform-plan
make terraform-apply
kubectl get nodes -o wide
```

Продолжайте только после появления двух узлов со статусом `Ready`. Затем
примените Kubernetes-ресурсы и дождитесь публичного адреса:

```bash
make k8s-deploy
make k8s-status
make k8s-public-check
kubectl --namespace bulletins get service bulletins-public
```

Yandex Cloud автоматически создаёт Network Load Balancer для Service типа
`LoadBalancer`. Его внешний IP динамический, а сам балансировщик тарифицируется.
Созданный Kubernetes ресурсами балансировщик не следует изменять вручную в
консоли: его жизненным циклом управляет Service `bulletins-public`.

Для проверки безостановочного обновления уже опубликованного образа выполните
rolling restart. Команда не требует сборки фиктивной версии приложения:

```bash
make k8s-rollout-check
```

Скрипт сохраняет текущий immutable image, запускает новую ревизию Deployment и
проверяет, что все pod были заменены. Когда действительно опубликована новая
версия приложения, тот же тест можно запустить с её полным Git SHA:

```bash
make k8s-rollout-check \
  K8S_NEW_IMAGE="cr.yandex/crphrkv4imihhuukiv7q/project-devops-deploy:<новый-Git-SHA>"
```

Проверка требует две Ready-реплики, два service endpoint и размещение pod на
двух разных нодах. Во время `RollingUpdate` она непрерывно обращается к
`/api/bulletins`, после чего выводит общее число запросов, ошибок и ответов 5xx.
Через Actuator-метрику `http_server_requests_seconds_count` дополнительно
проверяется прирост счётчика после отдельной серии из 60 запросов: трафик должен
получить каждый новый pod, без перекоса сильнее 4:1. В режиме нового образа
дополнительно проверяется изменение digest. Успешный результат содержит
`failed=0, 5xx=0`. При ошибке скрипт печатает команду `kubectl rollout undo`.
После реального обновления образа зафиксируйте новый SHA в
`k8s/deployment.yaml` и значение по умолчанию `K8S_IMAGE_TAG` в `Makefile`.

HPA на этом шаге намеренно не включён: он опционален, а учебная конфигурация
фиксирует две реплики, чтобы проверка распределения и PDB была воспроизводимой.

JDBC-соединение первичного учебного деплоя использует TLS с
`sslmode=require`. PostgreSQL закрыт от публичной сети и доступен только из
security group Kubernetes. Для перехода на `verify-full` необходимо отдельно
смонтировать в pod корневой CA Yandex Cloud и указать `sslrootcert`.

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
