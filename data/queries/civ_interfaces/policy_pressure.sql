-- Civ Interface: Policy Pressure

SELECT
    identity_class,
    sum(denial_units) AS denial_pressure
FROM value_plane.denial_cost
GROUP BY identity_class;