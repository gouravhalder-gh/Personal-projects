#!/usr/bin/env bash
# wifi-diagnose.sh — find common causes of slow Wi-Fi (macOS + Linux).
# Read-only: it changes no settings. Run on a computer connected to the Wi-Fi:
#   bash wifi-diagnose.sh            (sudo improves Linux scan results)

OS=$(uname -s)
hr() { printf '\n==== %s ====\n' "$1"; }
warn() { printf '  [!] %s\n' "$1"; }
ok() { printf '  [ok] %s\n' "$1"; }

# ---------- Gateway (router) ----------
if [ "$OS" = Darwin ]; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
else
  GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
fi
hr "Router"
echo "  Gateway: ${GW:-not found}"

# ---------- Wireless link ----------
hr "Wireless link (signal, noise, channel, rate)"
if [ "$OS" = Darwin ]; then
  INFO=$(system_profiler SPAirPortDataType 2>/dev/null)
  CUR=$(printf '%s\n' "$INFO" | awk '/Current Network Information:/{f=1;next} f&&/Other Local Wi-Fi Networks:/{exit} f')
  printf '%s\n' "$CUR" | grep -E 'PHY Mode|Channel|Signal / Noise|Transmit Rate|Security' | sed 's/^ */  /'
  SIG=$(printf '%s\n' "$CUR" | sed -nE 's/.*Signal \/ Noise: (-?[0-9]+) dBm \/ (-?[0-9]+) dBm.*/\1/p' | head -1)
  NOISE=$(printf '%s\n' "$CUR" | sed -nE 's/.*Signal \/ Noise: (-?[0-9]+) dBm \/ (-?[0-9]+) dBm.*/\2/p' | head -1)
  CHAN=$(printf '%s\n' "$CUR" | sed -nE 's/.*Channel: ([0-9]+).*/\1/p' | head -1)
  RATE=$(printf '%s\n' "$CUR" | sed -nE 's/.*Transmit Rate: ([0-9]+).*/\1/p' | head -1)
else
  IF=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  if [ -n "$IF" ]; then
    iw dev "$IF" link | sed 's/^/  /'
    SIG=$(iw dev "$IF" link | awk '/signal:/{print $2}')
    FREQ=$(iw dev "$IF" link | awk '/freq:/{print int($2)}')
    RATE=$(iw dev "$IF" link | awk '/tx bitrate:/{print int($3)}')
    NOISE=$(iw dev "$IF" survey dump 2>/dev/null | awk '/in use/{f=1} f&&/noise:/{print $2; exit}')
    if [ -n "$FREQ" ]; then
      if [ "$FREQ" -lt 3000 ]; then CHAN=$(( (FREQ-2407)/5 )); else CHAN=$(( (FREQ-5000)/5 )); fi
    fi
  else
    warn "No wireless interface found (is this machine on Wi-Fi? is 'iw' installed?)"
  fi
fi

if [ -n "$SIG" ]; then
  if   [ "$SIG" -ge -60 ]; then ok "Signal ${SIG} dBm is good"
  elif [ "$SIG" -ge -70 ]; then warn "Signal ${SIG} dBm is fair. Moving closer or relocating the router will help"
  else warn "Signal ${SIG} dBm is WEAK. This is likely your main problem (distance, walls, router placement)"; fi
fi
if [ -n "$SIG" ] && [ -n "$NOISE" ]; then
  SNR=$((SIG - NOISE))
  if [ "$SNR" -lt 25 ]; then warn "SNR ${SNR} dB is low: interference (microwaves, baby monitors, neighbours, Bluetooth)"
  else ok "SNR ${SNR} dB"; fi
fi
if [ -n "$CHAN" ]; then
  if [ "$CHAN" -le 14 ]; then
    warn "You're on 2.4 GHz (channel $CHAN): slower and more crowded. Use 5/6 GHz if your devices support it"
    case "$CHAN" in 1|6|11) ;; *) warn "Channel $CHAN overlaps its neighbours. Use 1, 6 or 11 on 2.4 GHz";; esac
  else ok "5 GHz band (channel $CHAN)"; fi
fi
[ -n "$RATE" ] && [ "$RATE" -lt 100 ] && warn "Link rate ${RATE} Mbps is low. Check for weak signal, 2.4 GHz, or old Wi-Fi standards"

# ---------- Channel congestion ----------
hr "Nearby networks (congestion)"
if [ "$OS" = Darwin ]; then
  OTHERS=$(printf '%s\n' "$INFO" | awk '/Other Local Wi-Fi Networks:/{f=1;next} f')
  printf '%s\n' "$OTHERS" | grep -E 'Channel:' | sed -E 's/.*Channel: ([0-9]+).*/\1/' | sort -n | uniq -c | sort -rn | head -10 | awk '{printf "  channel %-4s %s network(s)\n",$2,$1}'
  SAME=$(printf '%s\n' "$OTHERS" | grep -cE "Channel: ${CHAN:-x}[ ,(]")
elif command -v nmcli >/dev/null; then
  nmcli -t -f CHAN dev wifi list 2>/dev/null | sort -n | uniq -c | sort -rn | head -10 | awk '{printf "  channel %-4s %s network(s)\n",$2,$1}'
  SAME=$(nmcli -t -f CHAN,IN-USE dev wifi list 2>/dev/null | awk -F: -v c="$CHAN" '$1==c && $2!="*"' | wc -l)
fi
if [ -n "$SAME" ] && [ -n "$CHAN" ]; then
  if [ "$SAME" -ge 4 ]; then warn "$SAME other networks share your channel $CHAN. Switch to the least-used channel above in the router settings"
  else ok "$SAME other network(s) on your channel"; fi
fi

# ---------- Latency / loss / jitter ----------
pingstat() { # host label
  OUT=$(ping -c 20 -i 0.2 "$1" 2>/dev/null)
  LOSS=$(printf '%s\n' "$OUT" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p')
  STATS=$(printf '%s\n' "$OUT" | awk -F'= ' '/min\/avg/{print $2}' | cut -d' ' -f1)
  AVG=$(echo "$STATS" | cut -d/ -f2); JIT=$(echo "$STATS" | cut -d/ -f4)
  printf '  %-22s avg %6s ms  jitter %6s ms  loss %s%%\n' "$2" "${AVG:-?}" "${JIT:-?}" "${LOSS:-?}" >&2
  echo "$AVG ${LOSS%.*} $JIT"
}
hr "Latency (router vs internet)"
read -r GA GL GJ < <(pingstat "$GW" "Router ($GW)")
read -r IA IL IJ < <(pingstat 1.1.1.1 "Internet (1.1.1.1)")
[ -n "$GA" ] && [ "${GA%.*}" -gt 10 ] && warn "Router ping >10 ms: the Wi-Fi link itself is slow or congested"
[ -n "$GL" ] && [ "$GL" -gt 0 ] && warn "Packet loss to the router: interference or weak signal"
[ -n "$GJ" ] && [ "${GJ%.*}" -gt 5 ] && warn "High jitter to the router: congestion or interference"
if [ -n "$GA" ] && [ -n "$IA" ] && [ "${GA%.*}" -lt 10 ] && [ "${IA%.*}" -gt 60 ]; then
  warn "Wi-Fi is fine but the internet is slow, so the problem is your ISP/modem, not the Wi-Fi"
fi

# ---------- DNS ----------
hr "DNS lookup speed"
for d in example.com wikipedia.org; do
  T0=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  host "$d" >/dev/null 2>&1 || nslookup "$d" >/dev/null 2>&1
  T1=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  MS=$(( (T1-T0)/1000000 )); echo "  $d: ${MS} ms"
  [ "$MS" -gt 150 ] && warn "Slow DNS. Try 1.1.1.1 or 8.8.8.8 as DNS servers in the router"
done

# ---------- Devices ----------
hr "Devices seen on your network"
N=$(arp -an 2>/dev/null | grep -vc incomplete)
echo "  ~$N devices in the ARP table (only those this computer has talked to recently)"
[ "$N" -gt 25 ] && warn "Many devices: check the router's client list for bandwidth hogs (streaming, backups, cameras, torrents)"

hr "Done"
echo "  Check the [!] lines above. For a throughput test: networkQuality (macOS) or speedtest-cli."
