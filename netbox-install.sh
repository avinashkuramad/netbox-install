#!/bin/bash
set -euo pipefail

echo "=== NetBox Production Install (Debian 12) ==="

# 1. Base packages
apt update
apt install -y \
  python3 python3-venv python3-pip python3-dev \
  build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev \
  libssl-dev zlib1g-dev git curl redis-server postgresql nginx

systemctl enable --now redis-server postgresql nginx

# 2. PostgreSQL
DB_NAME="netbox"
DB_USER="netbox"
DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16)

sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
ALTER DATABASE $DB_NAME OWNER TO $DB_USER;
GRANT CREATE ON SCHEMA public TO $DB_USER;
EOF

# 3. Download NetBox (official method)
cd /opt
git clone https://github.com/netbox-community/netbox.git
cd netbox

# 4. System user
adduser --system --group netbox
chown -R netbox:netbox /opt/netbox

# 5. Configuration
cd /opt/netbox/netbox/netbox
cp configuration_example.py configuration.py

SECRET_KEY=$(python3 /opt/netbox/netbox/generate_secret_key.py)

cat <<EOF >> configuration.py

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

# 6. Upgrade / install
cd /opt/netbox
./upgrade.sh

# 7. Permissions
chown -R netbox:netbox /opt/netbox/netbox/media
chown -R netbox:netbox /opt/netbox/netbox/reports
chown -R netbox:netbox /opt/netbox/netbox/scripts

# 8. systemd
cp contrib/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now netbox netbox-rq

# 9. Nginx
cp contrib/nginx.conf /etc/nginx/sites-available/netbox
ln -sf /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# 10. Admin user
/opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py createsuperuser

echo "=== NetBox is installed ==="
echo "Access: http://$(hostname -I | awk '{print $1}')"
