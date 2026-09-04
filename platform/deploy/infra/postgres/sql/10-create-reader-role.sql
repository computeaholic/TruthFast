-- ThreadForge Read-Only Role
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'threadforge_reader'
    ) THEN
        CREATE ROLE threadforge_reader
            LOGIN
            PASSWORD :'reader_password'
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT;
    END IF;
END
$$;

-- Allow connection to DB
GRANT CONNECT ON DATABASE threadforge TO threadforge_reader;

-- Read-only access to ledgers
GRANT USAGE ON SCHEMA public TO threadforge_reader;
GRANT SELECT ON TABLE operator_ledger TO threadforge_reader;
GRANT SELECT ON TABLE value_ledger TO threadforge_reader;

-- Explicitly deny mutation
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM threadforge_reader;
REVOKE CREATE ON SCHEMA public FROM threadforge_reader;
REVOKE CREATE ON SCHEMA public FROM public;