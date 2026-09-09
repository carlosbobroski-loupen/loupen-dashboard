#!/usr/bin/env bash
# db/apply.sh — subtask 2.2. Runner de migrations forward-only, sem tooling
# (CON-10/CON-12 excluem Flyway/Prisma/Drizzle — todas exigiriam runtime e/ou
# package.json). Aplica db/migrations/*.sql em ordem lexical via psql,
# registra cada uma em schema_migrations(name, checksum, applied_at), e
# recusa reaplicar um arquivo cujo conteúdo mudou depois de aplicado
# (checksum diferente = erro, não reaplicação silenciosa).
#
# Uso:
#   bash db/apply.sh              # aplica tudo que falta
#   bash db/apply.sh --dry-run    # só lista o que seria aplicado, sem tocar no banco
#
# Requer NEON_DATABASE_URL exportado no ambiente (ver db/README.md — nunca
# commitado, vive em .env na raiz do repo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

if [ -z "${NEON_DATABASE_URL:-}" ]; then
  echo "ERRO: NEON_DATABASE_URL não está definida no ambiente. Rode: set -a; source .env; set +a" >&2
  exit 1
fi

PSQL_BIN="${PSQL_BIN:-psql}"
command -v "$PSQL_BIN" >/dev/null 2>&1 || PSQL_BIN="/opt/homebrew/opt/libpq/bin/psql"

_checksum() {
  # sha256sum (Linux) ou shasum -a 256 (macOS) — o que existir primeiro.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# schema_migrations pode ainda não existir (banco novo, antes da migration
# 000 rodar) — nesse caso trata como "nenhuma migration aplicada ainda",
# nunca como erro.
_applied_migrations() {
  "$PSQL_BIN" "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -tA -c "
    SELECT name || '|' || checksum
    FROM schema_migrations
    ORDER BY name;
  " 2>/dev/null || true
}

APPLIED="$(_applied_migrations)"

shopt -s nullglob
FILES=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "Nenhum arquivo de migration encontrado em $MIGRATIONS_DIR" >&2
  exit 1
fi

# Ordem lexical explícita — os nomes de arquivo (000_, 001_, ...) garantem
# a ordem de aplicação, não a ordem do glob do shell (que já é lexical em
# bash, mas fixamos com sort para não depender de locale).
IFS=$'\n' SORTED_FILES=($(printf '%s\n' "${FILES[@]}" | sort))
unset IFS

STATUS=0
for file in "${SORTED_FILES[@]}"; do
  name="$(basename "$file")"
  checksum="$(_checksum "$file")"
  existing_line="$(printf '%s\n' "$APPLIED" | grep "^${name}|" || true)"

  if [ -n "$existing_line" ]; then
    existing_checksum="${existing_line#*|}"
    if [ "$existing_checksum" != "$checksum" ]; then
      echo "ERRO FORWARD-ONLY: $name já foi aplicada, mas o conteúdo mudou depois (checksum diferente)." >&2
      echo "Migrations são append-only: crie um arquivo NOVO para corrigir, nunca edite um já aplicado." >&2
      STATUS=1
      break
    fi
    if [ "$DRY_RUN" = true ]; then
      echo "[já aplicada]  $name"
    fi
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "[aplicaria]    $name"
    continue
  fi

  echo "Aplicando $name ..."
  "$PSQL_BIN" "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$file"
  "$PSQL_BIN" "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -c "
    INSERT INTO schema_migrations (name, checksum, applied_at)
    VALUES ('$name', '$checksum', now());
  "
  echo "OK: $name"
done

exit $STATUS
