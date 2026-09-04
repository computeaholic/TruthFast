CREATE TABLE IF NOT EXISTS default.k8s_audit_events (
  ts DateTime,
  `user` String,
  userAgent String,
  sourceIP String,
  verb String,
  namespace String,
  resource String,
  name String,
  fieldManager String,
  objectDiff String
) ENGINE = MergeTree()
ORDER BY (ts, namespace, resource, name)
SETTINGS index_granularity = 8192;
