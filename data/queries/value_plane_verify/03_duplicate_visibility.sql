SELECT
  source_ledger,
  source_event_id,
  count(*) AS occurrences
FROM value_plane.operator_ledger
GROUP BY source_ledger, source_event_id
HAVING count(*) > 1
ORDER BY occurrences DESC;