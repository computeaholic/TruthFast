INSERT INTO value_plane.policy_scenarios
VALUES
(
  generateUUIDv4(),
  'Stricter Denial Policy',
  'Increase denial cost by 50%',
  1.5,
  1.0,
  now64(6),
  1
),
(
  generateUUIDv4(),
  'Higher Compute Cost',
  'Simulate higher compute pricing',
  1.0,
  1.25,
  now64(6),
  1
);