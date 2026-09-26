apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
  labels:
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/component: logging
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush                     1
        Daemon                    Off
        Log_Level                 info
        HTTP_Server               On
        HTTP_Listen               0.0.0.0
        HTTP_Port                 2020
        Health_Check              On
        storage.path              /var/log/fluent-bit-storage
        storage.sync              normal
        storage.checksum          Off
        storage.backlog.mem_limit 10M

    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*_bulletins_*.log
        multiline.parser  docker, cri
        DB                /var/log/fluent-bit-bulletins.db
        DB.Sync           Normal
        Mem_Buf_Limit     10MB
        Skip_Long_Lines   On
        Read_from_Head    On
        Refresh_Interval  10
        storage.type      filesystem

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Keep_Log            On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On
        Labels              On
        Annotations         Off

    [FILTER]
        Name   grep
        Match  kube.*
        Regex  $kubernetes['namespace_name'] ^bulletins$

    [OUTPUT]
        Name            yc-logging
        Match           kube.*
        group_id        __LOG_GROUP_ID__
        resource_type   {kubernetes/namespace_name}
        resource_id     {kubernetes/pod_name}
        stream_name     {kubernetes/container_name}
        message_key     log
        level_key       level
        default_level   INFO
        default_payload {"environment":"production","application":"bulletins"}
        authorization   instance-service-account
