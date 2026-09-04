CREATE TABLE IF NOT EXISTS identity_graph (
    timestamp DateTime,
    source_principal String,
    destination_principal String,
    request_count UInt64
) ENGINE = MergeTree()
ORDER BY (timestamp, source_principal, destination_principal);
