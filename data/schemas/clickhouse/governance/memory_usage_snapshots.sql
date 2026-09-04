CREATE TABLE IF NOT EXISTS value_plane.memory_usage_snapshots (
  recorded_at       DateTime64(6,'UTC'),
  namespace         LowCardinality(String),
  pod               LowCardinality(String),
  container         LowCardinality(String),
  memory_bytes      UInt64,
  snapshot_window   LowCardinality(String) DEFAULT 'avg_5m',
  source            LowCardinality(String) DEFAULT 'prometheus',
  identity_class    LowCardinality(String) DEFAULT '',
  ingest_run_id     UUID DEFAULT generateUUIDv4(),
  governance_input  UInt8 DEFAULT 1,
  created_at        DateTime64(6,'UTC') DEFAULT now()
) ENGINE = MergeTree()
ORDER BY (namespace, pod, recorded_at);
