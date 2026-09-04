-- Identity lifecycle coverage verification
SELECT
    COUNT(*) AS total_lifecycle_events,
    COUNT(CASE WHEN spiffe_id IS NOT NULL AND spiffe_id != '' THEN 1 END) AS events_with_spiffe_id,
    COUNT(CASE WHEN identity_class IS NOT NULL AND identity_class != '' THEN 1 END) AS events_with_identity_class
FROM value_plane.operator_ledger
WHERE JSONExtractString(payload, 'action_type') = 'identity_lifecycle';