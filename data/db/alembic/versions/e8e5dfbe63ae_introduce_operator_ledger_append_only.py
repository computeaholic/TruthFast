"""introduce operator_ledger (append-only)

Revision ID: e8e5dfbe63ae
Revises: bf5ab6f23dca
Create Date: 2025-12-23 23:13:38.802040

This migration introduces the operator_ledger table.
The table is append-only by convention and governance.
No UPDATE or DELETE paths are defined or encouraged.

All records represent operator-authorized actions with explicit intent.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision = "e8e5dfbe63ae"
down_revision = "bf5ab6f23dca"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "operator_ledger",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("timestamp_utc", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("operator_id", sa.Text(), nullable=False),
        sa.Column("operator_role", sa.Text(), nullable=False),
        sa.Column("action_type", sa.Text(), nullable=False),
        sa.Column("action_scope", sa.Text(), nullable=False),
        sa.Column("intent", sa.Text(), nullable=False),
        sa.Column("justification", sa.Text(), nullable=True),
        sa.Column("target_type", sa.Text(), nullable=True),
        sa.Column("target_identifier", sa.Text(), nullable=True),
        sa.Column("result", sa.Text(), nullable=False),
        sa.Column("result_detail", sa.Text(), nullable=True),
        sa.Column("metadata", postgresql.JSONB(), nullable=True),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    )

    # Table-level comment
    op.execute(
        """
        COMMENT ON TABLE operator_ledger IS
        'Append-only record of operator-authorized state transitions.
        Each row represents a deliberate human or delegated operator action
        with declared intent and observable outcome.';
        """,
    )

    # Column comments
    op.execute("COMMENT ON COLUMN operator_ledger.operator_id IS 'Human or delegated operator identifier.';")
    op.execute("COMMENT ON COLUMN operator_ledger.operator_role IS 'Declared role under which the operator acted.';")
    op.execute("COMMENT ON COLUMN operator_ledger.intent IS 'Human-declared intent at time of action.';")
    op.execute(
        "COMMENT ON COLUMN operator_ledger.justification IS 'Optional human justification for audit and review.';",
    )
    op.execute("COMMENT ON COLUMN operator_ledger.metadata IS 'Structured supplemental context; non-authoritative.';")


def downgrade():
    # Downgrade is destructive and therefore explicit.
    op.drop_table("operator_ledger")
