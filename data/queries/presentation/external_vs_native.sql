SELECT
  identity_class,
  sum(total_cost_units) AS total_cost_units
FROM value_plane.cost_model
WHERE identity_class IN ('native','translated','bridged','ephemeral')
GROUP BY identity_class
ORDER BY total_cost_units DESC;


-- Optional focused comparison:
-- SELECT
--   sumIf(total_cost_units, identity_class = 'native')     AS native_cost,
--   sumIf(total_cost_units, identity_class != 'native')    AS external_cost
-- FROM value_plane.cost_model;