SELECT
  identity_class,
  count(*) AS events
FROM value_plane.operator_ledger
GROUP BY identity_class
ORDER BY events DESC;