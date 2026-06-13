#!/usr/bin/env bash
# Set Docker Desktop VM memory (and CPUs=14) and (re)start Docker, then verify.
# Usage:
#   docker_vm.sh 16384     # set MemoryMiB=16384, Cpus=14, restart, verify
#   docker_vm.sh default   # remove Cpus/MemoryMiB (back to Docker defaults ~8GB)
#   docker_vm.sh ensure     # just make sure the daemon is up (start if needed)
# Backup of settings is kept at settings-store.json.bak-xdistbench.
set -uo pipefail
SS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
BAK="$SS.bak-xdistbench"
[ -f "$BAK" ] || cp "$SS" "$BAK"

wait_daemon(){
  for i in $(seq 1 120); do docker info >/dev/null 2>&1 && { echo "daemon up (${i}x2s)"; return 0; }; sleep 2; done
  return 1
}
ensure_running(){
  docker info >/dev/null 2>&1 && return 0
  pgrep -f "Docker Desktop.app/Contents/MacOS/Docker Desktop" >/dev/null || open -a Docker
  wait_daemon
}
restart_docker(){
  osascript -e 'quit app "Docker Desktop"' 2>/dev/null || true
  sleep 8
  open -a Docker
  wait_daemon
}

case "${1:-ensure}" in
  ensure)
    ensure_running || { echo "FAILED to start daemon"; exit 1; } ;;
  default)
    python3 - "$SS" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d.pop("Cpus",None); d.pop("MemoryMiB",None)
json.dump(d,open(p,"w"),indent=2); print("settings -> defaults")
PY
    python3 -c "import json;json.load(open('$SS'))" || { cp "$BAK" "$SS"; echo "bad json, restored"; exit 1; }
    restart_docker || { echo "daemon did not return"; exit 1; } ;;
  *)
    MIB="$1"
    python3 - "$SS" "$MIB" <<'PY'
import json,sys
p,mib=sys.argv[1],int(sys.argv[2]); d=json.load(open(p))
d["Cpus"]=14; d["MemoryMiB"]=mib
json.dump(d,open(p,"w"),indent=2); print("settings ->",{"Cpus":14,"MemoryMiB":mib})
PY
    python3 -c "import json;json.load(open('$SS'))" || { cp "$BAK" "$SS"; echo "bad json, restored"; exit 1; }
    restart_docker || { echo "daemon did not return"; exit 1; } ;;
esac
echo "VM: $(docker info --format '{{.NCPU}} CPU / {{.MemTotal}} bytes' 2>&1)"
