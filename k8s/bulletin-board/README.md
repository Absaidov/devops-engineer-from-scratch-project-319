# Bulletin board Helm chart

Чарт управляет ресурсами приложения `bulletins`: Deployment, двумя Service,
ConfigMap приложения и миграций, PodDisruptionBudget и опциональным Ingress.
Namespace, внешний Secret, Prometheus Operator и Fluent Bit остаются
инфраструктурными ресурсами и не удаляются вместе с Helm release.

## Values

Приоритет параметров Helm справа налево:

1. базовые значения [`values.yaml`](values.yaml);
2. окружение `values-dev.yaml` или `values-prod.yaml`;
3. явные `--set-string`, которые Makefile использует для immutable image tag и
   версии внешнего Secret.

Production использует две реплики, публичный LoadBalancer и PDB. Development
использует одну реплику и не создаёт публичный Service или PDB.

Проверка обоих окружений не требует подключения к кластеру:

```bash
make helm-check
make helm-template HELM_ENV=prod
make helm-template HELM_ENV=dev
```

## Secrets

По умолчанию `secret.create=false`, а Deployment читает
`secret.existingSecret=bulletins-secrets`. Команда `make helm-deploy` сначала
синхронизирует этот Secret из Yandex Lockbox и передаёт в Helm только его
`metadata.resourceVersion`, чтобы изменение секрета вызывало безопасный
RollingUpdate.

Шаблон `templates/secret.yaml` существует для изолированных dev/test
окружений. Не передавайте реальные DB/S3 credentials через values или
`--set`: Helm хранит values в истории release.

## Deploy and rollback

Первый `make helm-deploy` помечает только существующие ресурсы приложения
ownership-метаданными Helm, не удаляя LoadBalancer. Namespace и внешний Secret
скрипт миграции намеренно не принимает под управление release.

```bash
make helm-deploy HELM_ENV=prod
make helm-status
make helm-history
make helm-rollback HELM_REVISION=1
```

Для новой версии используйте опубликованный immutable Git SHA:

```bash
make helm-deploy \
  HELM_ENV=prod \
  K8S_IMAGE_TAG=<40-character-git-sha>
```

`helm rollback` откатывает Kubernetes release, но не откатывает уже
выполненные Flyway-миграции и внешний Lockbox Secret. SQL-миграции должны быть
append-only и совместимыми с предыдущей версией приложения.

## Ingress

Ingress шаблонизирован, но выключен: production уже доступен через Service
типа LoadBalancer. Для включения подготовьте поддерживаемый Ingress controller,
отключите `publicService.enabled` и задайте `ingress.className`, hosts и TLS в
отдельном values-файле. Чарт не устанавливает cluster-wide controller как
скрытую зависимость.

