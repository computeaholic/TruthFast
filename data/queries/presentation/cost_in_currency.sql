SELECT
    c.identity_class,
    r.currency,
    sum(c.total_cost_units * r.units_to_ccy) AS cost_in_currency
FROM value_plane.cost_model c
JOIN value_plane.currency_rates r
  ON r.currency = 'USD'
GROUP BY c.identity_class, r.currency
ORDER BY cost_in_currency DESC;