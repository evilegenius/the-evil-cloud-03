#!/bin/sh
# Pas de set -e : on supervise deux processus et on sort avec un code clair.
set -u

# 0. Le coupe-circuit : CONTROL_URL / CONTROL_SERVER / CONTROL_TOKEN.
#    Sans ce fichier, le conteneur sert normalement et ignore le panneau.
if [ -f /opt/control.env ]; then
  set -a
  . /opt/control.env
  set +a
fi

# 1. Xray en tâche de fond : il ne touche jamais le port 8080.
/opt/xray/xray run -config /opt/xray/config.json &
XRAY_PID=$!

# Config invalide = Xray mort en une fraction de seconde. Mieux vaut le dire
# tout de suite que laisser Cloud Run sonder le vide pendant 4 minutes.
sleep 1
if ! kill -0 "$XRAY_PID" 2>/dev/null; then
  echo '[entrypoint] Xray n a pas demarre : config.json invalide ?' >&2
  exit 1
fi

# 2. Le gardien d'expiration, lui aussi en tâche de fond.
/opt/watchdog.sh &

# 3. nginx : LE processus qui ecoute sur 8080, celui que la sonde doit joindre.
#    Sans lui, rien ne repond et Cloud Run affiche apres 4 minutes :
#    « Container failed to become healthy ».
nginx -g 'daemon off;' &
NGINX_PID=$!

# 4. Supervision : si l'un des deux tombe, on arrete tout pour que Cloud Run
#    relance un conteneur propre plutot que de servir du vide.
while kill -0 "$XRAY_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
  sleep 5
done
echo '[entrypoint] un processus est tombe, arret du conteneur' >&2
kill "$XRAY_PID" "$NGINX_PID" 2>/dev/null
exit 1