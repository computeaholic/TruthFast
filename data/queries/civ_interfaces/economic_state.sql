-- Civ Interface: Economic State Snapshot

SELECT
    identity_class,
    sum(total_cost_units)        AS total_cost,
    sumIf(total_cost_units, source_ledger='value') AS execution_cost,
    sumIf(denial_units, 1=1)     AS denial_pressure
FROM value_plane.cost_model c
LEFT JOIN value_plane.denial_cost d
  ON c.event_id = d.event_id
GROUP BY identity_class;