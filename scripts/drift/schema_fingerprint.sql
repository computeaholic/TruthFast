SELECT
  database,
  table,
  name,
  type
FROM system.columns
WHERE database = 'value_plane'
ORDER BY database, table, name;