-- Phase A — Time-accelerated cost lenses (read-only views)
-- DO NOT mutate base tables; these are derived views for situational awareness.

CREATE OR REPLACE VIEW value_plane.cost_model_1m AS
SELECT *
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 1 minute;

CREATE OR REPLACE VIEW value_plane.cost_model_5m AS
SELECT *
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 5 minute;

CREATE OR REPLACE VIEW value_plane.cost_model_15m AS
SELECT *
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 15 minute;

CREATE OR REPLACE VIEW value_plane.cost_model_60m AS
SELECT *
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 60 minute;
