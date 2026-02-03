```sh
#!/bin/sh
set -eu

log() { printf '%s\n' "$*"; }

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Fly.io region -> human-ish city
deabbreviate() {
  case "${1:-}" in
    ams) echo "amsterdam" ;;
    arn) echo "stockholm" ;;
    atl) echo "atlanta" ;;
    bog) echo "colombia-bogota" ;;
    bom) echo "mumbai" ;;
    bos) echo "boston" ;;
    cdg) echo "paris" ;;
    den) echo "denver" ;;
    dfw) echo "dallas" ;;
    ewr) echo "new-york-city" ;;
    eze) echo "argentina-ezeiza" ;;
    fra) echo "frankfurt" ;;
    gdl) echo "mexico-guadalajara" ;;
    gig) echo "rio-de-janeiro" ;;
    gru) echo "sao-paulo" ;;
    hkg) echo "hong-kong" ;;
    iad) echo "virginia-ashburn" ;;
    jnb) echo "johannesburg" ;;
    lax) echo "los-angeles" ;;
    lhr) echo "london" ;;
    mad) echo "madrid" ;;
    mia) echo "miami" ;;
    nrt) echo "tokyo" ;;
    ord) echo "chicago" ;;
    otp) echo "romania-bucharest" ;;
    phx) echo "phoenix" ;;
    qro) echo "mexico-queretaro" ;;
    scl) echo "chile-santiago" ;;
    sea) echo "seattle" ;;
    sin) echo "singapore" ;;
    sjc) echo "san-jose" ;;
    syd) echo "sydney" ;;
    waw) echo "warsaw" ;;
    yul) echo "montreal" ;;
    yyz) echo "toronto" ;;
    *) echo "unknown" ;;
  esac
}

log "Starting up Tailscale..."

# --- required creds ---
TS_AUTHKEY_FINAL="${TS_AUTHKEY:-${TAILSCALE_AUTH_KEY:-}}"
if [ -z "${TS_AUTHKEY_FINAL}" ]; then
  log "ERROR: TS_AUTHKEY (or TAILSCALE_AUTH_KEY) is required"
  exit 1
fi

# login server (headscale) - optional
TS_LOGIN_SERVER="${HS:-}"

# --- behavior knobs ---
# - TS_ADVERTISE_EXIT_NODE=1 enables exit-node mode
# - If FLY_REGION is set: force hostname to region(city) + force exit-node mode + ignore TS_HOSTNAME
EXIT_ENABLED=0
if [ -n "${FLY_REGION:-}" ]; then
  EXIT_ENABLED=1
  city="$(deabbreviate "$FLY_REGION")"
  TS_HOSTNAME_FINAL="flyio-${city}"
  log "FLY_REGION detected (${FLY_REGION}) -> city=${city} -> forcing hostname=${TS_HOSTNAME_FINAL} and enabling exit-node"
else
  TS_HOSTNAME_FINAL="${TS_HOSTNAME:-$(hostname 2>/dev/null || echo "tailscale-connector")}"
  if is_true "${TS_ADVERTISE_EXIT_NODE:-0}"; then
    EXIT_ENABLED=1
  fi
  log "No FLY_REGION -> hostname=${TS_HOSTNAME_FINAL} exit-node=${EXIT_ENABLED}"
fi

# --- always-on forwarding + NAT ---
log "Enabling IP forwarding..."
if command -v sysctl >/dev/null 2>&1; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
fi

# optional: try to load xt_mark (non-fatal)
if command -v modprobe >/dev/null 2>&1; then
  modprobe xt_mark >/dev/null 2>&1 || true
fi

log "Configuring NAT (MASQUERADE on eth0)..."
if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE >/dev/null 2>&1 \
    || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE >/dev/null 2>&1 \
    || log "WARN: IPv4 NAT failed (iptables)"
else
  log "WARN: iptables not found; skipping IPv4 NAT"
fi

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t nat -C POSTROUTING -o eth0 -j MASQUERADE >/dev/null 2>&1 \
    || ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE >/dev/null 2>&1 \
    || log "WARN: IPv6 NAT failed (ip6tables)"
else
  log "WARN: ip6tables not found; skipping IPv6 NAT"
fi

# --- start tailscaled (userspace + netfilter off to avoid MARK errors) ---
log "Starting tailscaled..."
/app/tailscaled --tun=userspace-networking --verbose=1 --port 41641 &
TAILSCALED_PID="$!"

# wait for socket
SOCK="/var/run/tailscale/tailscaled.sock"
i=0
while [ $i -lt 60 ]; do
  [ -S "$SOCK" ] && break
  i=$((i+1))
  sleep 0.5
done

if [ ! -S "$SOCK" ]; then
  log "ERROR: tailscaled.sock does not exist at $SOCK"
  kill "$TAILSCALED_PID" 2>/dev/null || true
  exit 1
fi

# --- tailscale up ---
UP_ARGS="--authkey=${TS_AUTHKEY_FINAL} --hostname=${TS_HOSTNAME_FINAL} --netfilter-mode=off"
if [ -n "$TS_LOGIN_SERVER" ]; then
  UP_ARGS="${UP_ARGS} --login-server=${TS_LOGIN_SERVER}"
fi
if [ "$EXIT_ENABLED" -eq 1 ]; then
  UP_ARGS="${UP_ARGS} --advertise-exit-node"
fi

log "Bringing up Tailscale..."
until /app/tailscale up ${UP_ARGS}; do
  log "Retrying tailscale up..."
  sleep 1
done
log "Tailscale started"

# --- services (start them all if installed) ---
start_bg() {
  name="$1"; shift
  if command -v "$1" >/dev/null 2>&1; then
    log "Starting ${name}..."
    "$@" &
    log "${name} started"
  else
    log "WARN: ${name} not started (missing: $1)"
  fi
}

start_bg "Squid" squid
start_bg "Dante" sockd
start_bg "dnsmasq" dnsmasq

cleanup() {
  log "Shutting down..."
  kill "$TAILSCALED_PID" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

sleep infinity
```
