#!/bin/bash
set -uo pipefail

RAID_MNT="" # ponto de montagem do destino (precisa estar no fstab)
DEST=""     # onde os snapshots são recebidos
KEEP_SRC=3  # snapshots mantidos na origem (mínimo 2)
KEEP_DEST=5 # snapshots mantidos no destino
LOG="/var/log/btrfs-backup.log"

# nome:origem:pasta_de_snapshots
# A pasta de snapshots precisa estar no MESMO filesystem da origem.
SOURCES=(
  "root:/:/.snapshots"
  "home:/home:/.snapshots"
)
# =========================

[ "$KEEP_SRC" -ge 2 ] || KEEP_SRC=2

INIT=0
[ "${1:-}" = "--init" ] && INIT=1

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

prune() {
  local dir="$1" prefix="$2" keep="$3"
  ls -1 "$dir" | grep "^$prefix-" | sort | head -n -"$keep" | while read -r s; do
    btrfs subvolume delete "$dir/$s" >/dev/null && log "[$prefix] Removido $dir/$s"
  done
}

backup_one() {
  local name="$1" src="$2" snapdir="$3"
  local new_name="$name-$(date +%F_%H%M%S)"
  local new="$snapdir/$new_name"

  if ! btrfs subvolume show "$src" >/dev/null 2>&1; then
    log "[$name] ERRO: $src não é um subvolume BTRFS (se for pasta do root, já está no backup do root)"
    return 1
  fi

  mkdir -p "$snapdir"

  if [ "$(findmnt -no UUID -T "$src")" != "$(findmnt -no UUID -T "$snapdir")" ]; then
    log "[$name] ERRO: $snapdir está em outro filesystem que $src"
    return 1
  fi

  # Último snapshot presente na origem E no destino = pai do incremental
  local parent="" s
  for s in $(ls -1 "$snapdir" | grep "^$name-" | sort -r); do
    if [ -d "$DEST/$s" ]; then
      parent="$s"
      break
    fi
  done

  if [ -z "$parent" ] && [ "$INIT" -ne 1 ]; then
    log "[$name] ERRO: nenhum snapshot em comum. Rode com --init para o primeiro backup completo."
    return 1
  fi

  log "[$name] Criando snapshot $new_name (pai: ${parent:-nenhum, envio completo})"
  if ! btrfs subvolume snapshot -r "$src" "$new" >/dev/null; then
    log "[$name] ERRO ao criar snapshot"
    return 1
  fi

  local args=()
  [ -n "$parent" ] && args=(-p "$snapdir/$parent")

  if btrfs send "${args[@]}" "$new" | btrfs receive "$DEST" >>"$LOG" 2>&1; then
    sync
    log "[$name] Backup OK: $new_name"
  else
    log "[$name] ERRO no send/receive, limpando restos"
    btrfs subvolume delete "$DEST/$new_name" >/dev/null 2>&1 || true
    btrfs subvolume delete "$new" >/dev/null 2>&1 || true
    return 1
  fi

  prune "$snapdir" "$name" "$KEEP_SRC"
  prune "$DEST" "$name" "$KEEP_DEST"
}

# Evita duas execuções ao mesmo tempo
exec 9>/run/btrfs-backup.lock
flock -n 9 || {
  log "já está rodando"
  exit 0
}

# Garante que o destino está montado (senão o backup iria parar no disco do root)
mountpoint -q "$RAID_MNT" || mount "$RAID_MNT" || {
  log "ERRO: destino não montou"
  exit 1
}
mkdir -p "$DEST"

rc=0
for entry in "${SOURCES[@]}"; do
  IFS=: read -r name src snapdir <<<"$entry"
  backup_one "$name" "$src" "$snapdir" || rc=1
done
exit $rc
