/* 
CIV METRIC LENS
Name: <metric_name>
Plane: value_plane
Class: replay-only, advisory
Authority: none
Persistence: none

Inputs:
  - Tables: <list>
  - Identity: identity_class (explicit)
  - Time: derived_at / created_at

Outputs:
  - Deterministic result set
  - No side effects

Warnings:
  - Empty result sets are valid but non-informative
*/

SELECT
    identity_class,
    sum(total_cost_units) AS total_cost_units,
    sum(denial_units)     AS total_denial_units,
    countDistinct(event_id) AS event_count
FROM cost_model
LEFT JOIN denial_cost USING (event_id)
GROUP BY identity_class
ORDER BY total_cost_units DESC;
