SELECT
  count(*) AS null_identity_rows
FROM value_plane.operator_ledger
WHERE
  identity_class = ''
  OR (
    spiffe_id = ''
    AND source_ledger NOT IN ('demo-identity-authority', 'demo-identity-authority-full')
  );
