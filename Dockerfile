# Un seul conteneur : nginx (répartiteur) + Xray (un inbound par nœud).
# Le fichier doit s'appeler exactement « Dockerfile », à la racine, sans extension.
FROM alpine:3.20

RUN apk add --no-cache curl unzip ca-certificates nginx \
 && curl -fsSL -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
 && mkdir -p /opt/xray \
 && unzip -q /tmp/xray.zip -d /opt/xray \
 && chmod +x /opt/xray/xray \
 && rm -f /tmp/xray.zip

COPY config.json /opt/xray/config.json
COPY expiry.txt /opt/xray/expiry.txt
COPY limits.txt /opt/xray/limits.txt
COPY control.env /opt/control.env
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /opt/entrypoint.sh
COPY watchdog.sh /opt/watchdog.sh

RUN chmod +x /opt/entrypoint.sh /opt/watchdog.sh \
 && ln -sf /opt/xray/xray /usr/local/bin/xray

# Valide nginx.conf DES le build : une erreur de syntaxe doit casser le build
# en 20 s, pas le demarrage apres 4 minutes de sonde.
RUN nginx -t -c /etc/nginx/nginx.conf

# Cloud Run injecte PORT=8080 ; nginx écoute déjà là.
EXPOSE 8080

CMD ["/bin/sh", "/opt/entrypoint.sh"]