"""add identity columns to ledgers

Revision ID: f1a2b3c4d5e6
Revises: e9054a4cf651
Create Date: 2025-12-26 00:00:00.000000

Promote identity to first-class columns in operator_ledger and value_ledger.
Add spiffe_id and identity_class to operator_ledger.
Add spiffe_id to value_ledger (identity_class already exists).
Use safe defaults based on existing columns for existing rows.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "f1a2b3c4d5e6"
down_revision = "e9054a4cf651"
branch_labels = None
depends_on = None


def upgrade():
    # Add spiffe_id to operator_ledger
    op.add_column("operator_ledger", sa.Column("spiffe_id", sa.Text(), nullable=True))
    op.execute("UPDATE operator_ledger SET spiffe_id = operator_id WHERE spiffe_id IS NULL")
    op.alter_column("operator_ledger", "spiffe_id", nullable=False)

    # Add identity_class to operator_ledger
    op.add_column("operator_ledger", sa.Column("identity_class", sa.Text(), nullable=True))
    op.execute("UPDATE operator_ledger SET identity_class = operator_role WHERE identity_class IS NULL")
    op.alter_column("operator_ledger", "identity_class", nullable=False)

    # Add spiffe_id to value_ledger
    op.add_column("value_ledger", sa.Column("spiffe_id", sa.Text(), nullable=True))
    op.execute("UPDATE value_ledger SET spiffe_id = subject_identity WHERE spiffe_id IS NULL")
    op.alter_column("value_ledger", "spiffe_id", nullable=False)


def downgrade():
    op.drop_column("operator_ledger", "spiffe_id")
    op.drop_column("operator_ledger", "identity_class")
    op.drop_column("value_ledger", "spiffe_id")
