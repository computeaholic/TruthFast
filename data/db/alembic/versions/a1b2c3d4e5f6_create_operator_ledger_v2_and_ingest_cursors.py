"""create operator_ledger_v2 + ingest_cursors (Alembic authority)

Revision ID: a1b2c3d4e5f6
Revises: f1a2b3c4d5e6
Create Date: 2026-02-16 00:00:00.000000

Alembic-managed creation of `operator_ledger_v2` and `ingest_cursors`.
Infra/bootstrapping SQL must not declare application tables — Alembic is
the single authority for application table creation.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision = "a1b2c3d4e5f6"
down_revision = "f1a2b3c4d5e6"
branch_labels = None
depends_on = None


def upgrade():
    # Create canonical execution ledger (operator_ledger_v2)
    op.create_table(
        "operator_ledger_v2",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("ts", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("trace_id", sa.Text(), nullable=False),
        sa.Column("sender", sa.Text(), nullable=False),
        sa.Column("recipient", sa.Text(), nullable=False),
        sa.Column("op", sa.Text(), nullable=False),
        sa.Column("priority", sa.Integer(), nullable=False),
        sa.Column("reflex_verdict", sa.Text(), nullable=True),
        sa.Column("truth_verdict", sa.Text(), nullable=True),
        sa.Column("backend", sa.Text(), nullable=True),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=False),
        sa.Column("duration_ms", sa.Float(), nullable=False),
        sa.Column("envelope_id", sa.Text(), nullable=True),
        sa.Column("seal", sa.Text(), nullable=True),
        sa.Column("ppit", postgresql.JSONB(), nullable=True),
        sa.Column("spiffe_id", sa.Text(), nullable=True),
        sa.Column("identity_class", sa.Text(), nullable=True),
    )

    op.execute(
        """
        COMMENT ON TABLE operator_ledger_v2 IS
          'Canonical append-only execution ledger (operator_ledger_v2) - Alembic-managed.';
        """
    )

    # Compatibility view: only create when legacy operator_ledger table does not exist.
    # Keep behaviour identical to earlier infra SQL but managed here (Alembic).
    op.execute(
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_class
            WHERE relname = 'operator_ledger' AND relkind = 'r'
          ) THEN
            CREATE OR REPLACE VIEW operator_ledger AS
            SELECT
                id,
                ts AS timestamp_utc,
                sender AS operator_id,
                'unknown' AS operator_role,
                op AS action_type,
                'unknown' AS action_scope,
                'unknown' AS intent,
                NULL AS justification,
                recipient AS target_type,
                recipient AS target_identifier,
                status AS result,
                result::TEXT AS result_detail,
                payload AS metadata,
                ts AS created_at,
                spiffe_id,
                identity_class
            FROM operator_ledger_v2;
          ELSE
            RAISE NOTICE 'operator_ledger table exists; skipping compatibility view creation';
          END IF;
        END
        $$;
        """
    )

    # Ingest cursors table (small bootstrap helper) — move to Alembic ownership
    op.create_table(
        "ingest_cursors",
        sa.Column("table_name", sa.Text(), primary_key=True),
        sa.Column("created_at", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
    )

    op.execute(
        """
        COMMENT ON TABLE ingest_cursors IS 'Alembic-managed bootstrap cursor table (ingest_cursors)';
        """
    )


def downgrade():
    # Downgrade is explicit/destructive.
    op.drop_table("ingest_cursors")
    op.drop_table("operator_ledger_v2")
