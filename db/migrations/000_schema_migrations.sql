-- db/migrations/000_schema_migrations.sql
-- Subtask 2.3. Tabela de controle do runner (db/apply.sh) — registra cada
-- migration aplicada com nome, checksum (sha256) e timestamp. É o que torna
-- o runner forward-only verificável: se o checksum de um arquivo já
-- aplicado mudar, apply.sh recusa reaplicar (migrations são append-only,
-- nunca editadas depois de aplicadas).

CREATE TABLE IF NOT EXISTS schema_migrations (
  name        text PRIMARY KEY,
  checksum    text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE schema_migrations IS
  'Controle de migrations aplicadas por db/apply.sh (subtask 2.2). Forward-only: nunca editar uma linha existente, só inserir novas.';
