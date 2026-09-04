"""introduce value_ledger (append-only)

Revision ID: e9054a4cf651
Revises: e8e5dfbe63ae
Create Date: 2025-12-23 23:13:49.867745

"""

from alembic import op

# revision identifiers, used by Alembic.
revision = "e9054a4cf651"
down_revision = "e8e5dfbe63ae"
branch_labels = None
depends_on = None


def upgrade():
    op.execute(
        """
    CREATE TABLE value_ledger (
        id UUID PRIMARY KEY,

        identity_class TEXT NOT NULL CHECK (
            identity_class IN ('native', 'translated', 'bridged', 'ephemeral')
        ),

        subject_identity TEXT NOT NULL,

        provenance_type TEXT NOT NULL,
        provenance_hash TEXT NOT NULL,

        value_domain TEXT NOT NULL,
        value_type TEXT NOT NULL,
        value_amount NUMERIC(20,6) NOT NULL,
        value_unit TEXT NOT NULL,

        policy_id TEXT,
        policy_outcome TEXT NOT NULL,

        recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),

        notes TEXT
    );
    """,
    )


def downgrade():
    op.drop_table("value_ledger")
