"""bootstrap alembic (no schema)

Revision ID: bf5ab6f23dca
Revises:
Create Date: 2025-12-23 23:13:35.935243

"""

from collections.abc import Sequence

# revision identifiers, used by Alembic.
revision: str = "bf5ab6f23dca"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
