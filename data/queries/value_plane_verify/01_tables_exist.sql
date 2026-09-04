SELECT
  database,
  name
FROM system.tables
WHERE database = 'value_plane'
ORDER BY name;