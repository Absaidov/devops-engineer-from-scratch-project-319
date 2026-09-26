global:
  resolve_timeout: 5m

route:
  receiver: operations
  group_by:
    - alertname
    - service
    - severity
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: operations
    yandex_monitoring_configs:
      - channel_names:
          - "__NOTIFICATION_CHANNEL__"
