-- ThreadForge Ledger Role Privileges
-- Migration 22: Revoke mutation privileges from runtime role
--
-- Ensures threadforge_writer role can only INSERT/SELECT,
-- not UPDATE/DELETE/TRUNCATE.

-- Revoke all mutation privileges
REVOKE UPDATE, DELETE, TRUNCATE
ON operator_ledger_v2
FROM threadforge_writer;

-- Grant only INSERT and SELECT
GRANT INSERT, SELECT
ON operator_ledger_v2
TO threadforge_writer;

-- Ensure sequence access for serial columns
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO threadforge_writer;

COMMENT ON TABLE operator_ledger_v2 IS
'Phase 10: Immutable execution ledger. '
'Runtime role has INSERT/SELECT only.';
