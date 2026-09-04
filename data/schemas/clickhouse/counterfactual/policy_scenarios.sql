CREATE TABLE IF NOT EXISTS value_plane.policy_scenarios
(
    scenario_id        UUID,
    scenario_name      String,
    description        String,

    -- Policy modifiers (explicit)
    denial_multiplier  Float64,
    compute_multiplier Float64,

    created_at         DateTime64(6, 'UTC'),
    is_counterfactual  UInt8 DEFAULT 1
)
ENGINE = MergeTree
ORDER BY scenario_id;