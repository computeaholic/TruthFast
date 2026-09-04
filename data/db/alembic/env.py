import os
from logging.config import fileConfig
from typing import Any

from alembic import context
from sqlalchemy import engine_from_config, pool

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# No ORM metadata allowed yet
target_metadata = None


def get_url() -> str:
    # Allow full URL override for local test environments.
    override = os.environ.get("DATABASE_URL")
    if override:
        return override
    url = config.get_main_option("sqlalchemy.url")
    if not url:
        raise RuntimeError("alembic missing required sqlalchemy.url configuration")
    password = os.environ.get("POSTGRES_PASSWORD")
    if password:
        return url.replace("${POSTGRES_PASSWORD}", password)
    return url


def run_migrations_offline():
    context.configure(
        url=get_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=False,
        compare_server_default=False,
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online():
    section: dict[str, Any] | None = config.get_section(config.config_ini_section)
    if section is None:
        raise RuntimeError(f"alembic missing required config section: {config.config_ini_section}")

    connectable = engine_from_config(
        section,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
        url=get_url(),
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=False,
            compare_server_default=False,
        )

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
