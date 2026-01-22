#!/bin/bash
set -euo pipefail

echo "=== NetBox Production Install (Debian 12) ==="

### VARIABLES
NETBOX_DIR="/opt/netbox"
DB_NAME="netbox"
DB_USER="netbox"
DB_PASS_FILE="/root/.netbox_db_pass"

### MUST BE ROOT
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

### 1. BASE PACKAGES
apt update
apt install -y \
  python3 python3-venv python3-pip python3-dev \
  build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev \
  libssl-dev zlib1g-dev git curl redis-server postgresql nginx

systemctl enable --now redis-server postgresql nginx

### 2. DATABASE (SAFE / IDPOTENT)
if [[ ! -f "$DB_PASS_FILE" ]]; then
  DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16)
  echo "$DB_PASS" > "$DB_PASS_FILE"
  chmod 600 "$DB_PASS_FILE"
else
  DB_PASS=$(cat "$DB_PASS_FILE")
fi

sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME') THEN
    CREATE DATABASE $DB_NAME;
  END IF;
END
\$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
  END IF;
END
\$\$;

ALTER DATABASE $DB_NAME OWNER TO $DB_USER;
GRANT CREATE ON SCHEMA public TO $DB_USER;
EOF

### 3. NETBOX SOURCE
if [[ ! -d "$NETBOX_DIR" ]]; then
  git clone https://github.com/netbox-community/netbox.git "$NETBOX_DIR"
fi

### 4. SYSTEM USER
if ! id netbox &>/dev/null; then
  adduser --system --group netbox
fi

chown -R netbox:netbox "$NETBOX_DIR"

### 5. CONFIGURATION
CFG_DIR="$NETBOX_DIR/netbox/netbox"
CFG_FILE="$CFG_DIR/configuration.py"

cd "$CFG_DIR"

if [[ ! -f "$CFG_FILE" ]]; then
  cp configuration_example.py configuration.py
fi

SECRET_KEY=$(python3 "$NETBOX_DIR/netbox/generate_secret_key.py")

sed -i "/^ALLOWED_HOSTS/d" "$CFG_FILE"
sed -i "/^DATABASES = {/,+10d" "$CFG_FILE"
sed -i "/^REDIS = {/,+10d" "$CFG_FILE"
sed -i "/^SECRET_KEY = /d" "$CFG_FILE"

cat <<EOF >> "$CFG_FILE"

ALLOWED_HOSTS = ['*']

DATABASES = {
  'default': {
    'NAME': '$DB_NAME',
    'USER': '$DB_USER',
    'PASSWORD': '$DB_PASS',
    'HOST': 'localhost',
    'PORT': '',
  }
}

REDIS = {
  'tasks': {'HOST': 'localhost', 'PORT': 6379},
  'caching': {'HOST': 'localhost', 'PORT': 6379},
}

SECRET_KEY = '$SECRET_KEY'
EOF

### 6. INSTALL / UPGRADE
cd "$NETBOX_DIR"
./upgrade.sh

### 7. PERMISSIONS
chown -R netbox:netbox \
  "$NETBOX_DIR/netbox/media" \
  "$NETBOX_DIR/netbox/reports" \
  "$NETBOX_DIR/netbox/scripts"

### 8. SYSTEMD
cp "$NETBOX_DIR/contrib/netbox.service" /etc/systemd/system/
cp "$NETBOX_DIR/contrib/netbox-rq.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now netbox.service netbox-rq.service

### 9. NGINX
NGINX_CFG="/etc/nginx/sites-available/netbox"

if [[ ! -f "$NGINX_CFG" ]]; then
  cp "$NETBOX_DIR/contrib/nginx.conf" "$NGINX_CFG"
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
sed -i "s/server_name .*;/server_name $SERVER_IP;/" "$NGINX_CFG"

ln -sf "$NGINX_CFG" /etc/nginx/sites-enabled/netbox
rm -f /etc/nginx/sites-enabled/default

systemctl restart nginx

### 10. ADMIN USER (ONE TIME)
ADMIN_MARK="/root/.netbox_admin_created"

if [[ ! -f "$ADMIN_MARK" ]]; then
  "$NETBOX_DIR/venv/bin/python" "$NETBOX_DIR/netbox/manage.py" createsuperuser
  touch "$ADMIN_MARK"
fi

echo "========================================"
echo "NetBox installation COMPLETE ✅"
echo "URL: http://$SERVER_IP"
echo "DB password stored in $DB_PASS_FILE"
echo "========================================"
