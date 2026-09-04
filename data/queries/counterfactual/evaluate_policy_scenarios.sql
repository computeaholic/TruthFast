SELECT
    s.scenario_name,
    c.identity_class,

    sum(c.total_cost_units * s.compute_multiplier) AS simulated_compute_cost,
    sum(d.denial_units * s.denial_multiplier)      AS simulated_denial_cost,

    sum(
        (c.total_cost_units * s.compute_multiplier)
      + (d.denial_units * s.denial_multiplier)
    ) AS simulated_total_cost

FROM value_plane.policy_scenarios s
CROSS JOIN value_plane.cost_model c
LEFT JOIN value_plane.denial_cost d
  ON c.event_id = d.event_id

GROUP BY s.scenario_name, c.identity_class
ORDER BY simulated_total_cost DESC;