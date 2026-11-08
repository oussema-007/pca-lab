-- Idempotent primary-side setup for the streaming replica (rendered with REPL_PASSWORD, sent over stdin, never on a command line)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN;
  END IF;
END $$;
ALTER ROLE replicator WITH PASSWORD '@@REPL_PASSWORD@@';
SELECT pg_create_physical_replication_slot('replica1') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica1');
