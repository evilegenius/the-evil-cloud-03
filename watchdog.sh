#!/bin/sh
# Gardien du conteneur : echeances, quota de gigas, nombre d'appareils.
#
# Aucune de ces trois limites n'existe dans Xray : elles sont tenues ici.
# Toutes les 20 s : on lit expiry.txt et limits.txt, on interroge l'API
# locale, puis on retire du serveur ce qui doit l'etre. Et on ecrit
# /tmp/stats.json, que le panneau vient lire.

SRC=/opt/xray/expiry.txt
WORK=/tmp/expiry.txt
LIMITS=/opt/xray/limits.txt
TRAFFIC=/tmp/traffic.txt
ONLINE=/tmp/online.txt
OUT=/tmp/stats.json
API=127.0.0.1:10085
SERVICE_NAME="the-evil-cloud-03"

# Le coupe-circuit (facultatif) : adresse, serveur et jeton.
[ -f /opt/control.env ] && . /opt/control.env
CONTROL_URL=${CONTROL_URL:-}
CONTROL_SERVER=${CONTROL_SERVER:-}
CONTROL_TOKEN=${CONTROL_TOKEN:-}

cp "$SRC" "$WORK" 2>/dev/null || : > "$WORK"

try_remove() {
  xray api rmu -s "$API" "$1" "$2" >/dev/null 2>&1 && return 0
  xray api rmu -s="$API" "$1" "$2" >/dev/null 2>&1 && return 0
  xray api rmu "$1" "$2" >/dev/null 2>&1 && return 0
  return 1
}

# email|montee|descente — une ligne par client qui a bouge.
read_traffic() {
  xray api statsquery -s "$API" -pattern "user>>>" -reset=false 2>/dev/null | awk '
    /^[[:space:]]*name:/ { n=$0; sub(/^[[:space:]]*name:[[:space:]]*"?/, "", n); sub(/".*$/, "", n); name=n }
    /^[[:space:]]*value:/ { v=$0; sub(/^[[:space:]]*value:[[:space:]]*/, "", v); sub(/[^0-9].*$/, "", v); if (name != "") print name "|" v; name="" }
  ' | awk -F'|' '
    { c = split($1, p, ">>>"); if (c >= 4 && p[2] != "") { if (p[4] == "uplink") up[p[2]] += $2; else if (p[4] == "downlink") dn[p[2]] += $2 } }
    END {
      for (e in up) print e "|" up[e] "|" (e in dn ? dn[e] : 0)
      for (e in dn) if (!(e in up)) print e "|0|" dn[e]
    }'
}

# email|ip — une ligne par adresse vue sur le serveur.
read_online() {
  xray api statsonlineiplist -s "$API" 2>/dev/null | awk '
    /email/ { e=$0; sub(/.*email[^A-Za-z0-9]*/, "", e); sub(/[",[:space:]].*$/, "", e) }
    match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { print e "|" substr($0, RSTART, RLENGTH) }
  '
}

# /tmp/stats.json : volumes par client et adresses connectees.
collect_stats() {
  now=$(date +%s)
  read_traffic > "$TRAFFIC" 2>/dev/null || : > "$TRAFFIC"
  read_online > "$ONLINE" 2>/dev/null || : > "$ONLINE"

  : > /tmp/stats_t
  first=1
  while IFS='|' read -r email up dn; do
    [ -z "$email" ] && continue
    case "$up" in ''|*[!0-9]*) up=0 ;; esac
    case "$dn" in ''|*[!0-9]*) dn=0 ;; esac
    if [ "$first" = 1 ]; then first=0; else printf ',' >> /tmp/stats_t; fi
    printf '{"email":"%s","up":%d,"down":%d}' "$email" "$up" "$dn" >> /tmp/stats_t
  done < "$TRAFFIC"

  : > /tmp/stats_o
  ofirst=1
  cut -d'|' -f1 "$ONLINE" 2>/dev/null | sort -u > /tmp/stats_e
  while IFS= read -r email; do
    [ -z "$email" ] && continue
    ips=$(grep -F "$email|" "$ONLINE" 2>/dev/null | cut -d'|' -f2 | sort -u | awk '{ printf "%s\"%s\"", (n++ ? "," : ""), $0 }')
    [ -z "$ips" ] && continue
    if [ "$ofirst" = 1 ]; then ofirst=0; else printf ',' >> /tmp/stats_o; fi
    printf '{"email":"%s","ips":[%s]}' "$email" "$ips" >> /tmp/stats_o
  done < /tmp/stats_e

  printf '{"service":"%s","updated":%s,"traffic":[%s],"online":[%s]}' \
    "$SERVICE_NAME" "$now" "$(cat /tmp/stats_t 2>/dev/null)" "$(cat /tmp/stats_o 2>/dev/null)" > /tmp/stats.new
  mv /tmp/stats.new "$OUT" 2>/dev/null
}

# Quota et appareils. Retirer un client est une vraie coupure : le tunnel
# tombe et ne revient qu'apres un redeploiement (ou une remise en service).
enforce_limits() {
  [ -f "$LIMITS" ] || return 0
  while IFS='|' read -r tag email maxdev quota; do
    [ -z "$tag" ] && continue
    case "$maxdev$quota" in ''|*[!0-9]*) continue ;; esac
    total=$(awk -F'|' -v e="$email" '$1==e { s += $2 + $3 } END { print s + 0 }' "$TRAFFIC" 2>/dev/null)
    devices=$(awk -F'|' -v e="$email" '$1==e { c++ } END { print c + 0 }' "$ONLINE" 2>/dev/null)
    if [ "$quota" -gt 0 ] && [ "${total:-0}" -gt $((quota * 1073741824)) ]; then
      try_remove "$tag" "$email" && echo "[gardien] $email retire : quota ${quota} Go depasse" >&2
      continue
    fi
    if [ "$maxdev" -gt 0 ] && [ "${devices:-0}" -gt "$maxdev" ]; then
      try_remove "$tag" "$email" && echo "[gardien] $email retire : ${devices} appareils pour un maximum de $maxdev" >&2
    fi
  done < "$LIMITS"
}

# Le coupe-circuit : on demande au Backend quel est l'etat de CE serveur.
# `off` = on arrete tout ; `pause` = les tunnels renvoient 503 ; `on` = normal.
control_check() {
  [ -n "$CONTROL_URL" ] || return 0
  [ -n "$CONTROL_TOKEN" ] || return 0
  reply=$(curl -fsS --max-time 6 "$CONTROL_URL?server=$CONTROL_SERVER&token=$CONTROL_TOKEN" 2>/dev/null) || return 0
  state=$(printf '%s' "$reply" | tr -d ' ' | grep -o '"state":"[a-z]*"' | head -1 | cut -d'"' -f4)
  case "$state" in
    off|pause)
      if [ ! -f /tmp/cut.flag ]; then
        : > /tmp/cut.flag
        echo "[garde] coupure demandee depuis le panneau ($state)" >&2
      fi
      if [ "$state" = "off" ]; then
        echo "[garde] service coupe : arret du conteneur" >&2
        pkill -f "xray run" 2>/dev/null
        exit 1
      fi
      ;;
    on)
      if [ -f /tmp/cut.flag ]; then
        rm -f /tmp/cut.flag
        echo "[garde] service rallume depuis le panneau" >&2
      fi
      ;;
  esac
}

while true; do
  control_check
  now=$(date +%s)
  keep=""
  while IFS='|' read -r exp tag email; do
    [ -z "$exp" ] && continue
    case "$exp" in *[!0-9]*) continue ;; esac
    if [ "$now" -ge "$exp" ]; then
      if try_remove "$tag" "$email"; then
        echo "[gardien] $email retire (tag $tag, echeance $exp)" >&2
      else
        keep="${keep}${exp}|${tag}|${email}\n"
      fi
    else
      keep="${keep}${exp}|${tag}|${email}\n"
    fi
  done < "$WORK"
  printf "%b" "$keep" | sed "/^$/d" > "$WORK"

  collect_stats
  enforce_limits
  sleep 20
done