#!/bin/bash
# NetBox Installation Script for Debian 12 (Production Setup)
# This script installs NetBox (community edition) and all its dependencies, then configures 
# Gunicorn, Nginx, PostgreSQL, and Redis for a production-ready deployment.
# **Run as root** on a fresh Debian 12 system. It will output an admin password at the end.

set -euo pipefail  # Exit on errors or unset variables

# 1. Update system and install base dependencies (Python, build tools, etc.)[4]
echo "Updating package lists and installing base packages..."
apt-get update -y
apt-get upgrade -y   # (Optional) Update existing packages for a fully up-to-date system
apt-get install -y python3 python3-pip python3-venv python3-dev \
  build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev \
  libssl-dev zlib1g-dev git curl software-properties-common

# Ensure Python 3.12+ is available (NetBox v4.5+ requirement)[24]
# Debian 12 default is Python 3.11; we'll install Python 3.12 if needed.
PYTHON_OK=$(python3 -c 'import sys; print(1 if sys.version_info >= (3,12) else 0)')
if [ "$PYTHON_OK" -ne 1 ]; then
    echo "Python 3.12+ not found. Installing Python 3.12..."
    # Attempt to install Python 3.12 from source (this may take a few minutes)
    apt-get install -y libncurses5-dev libnss3-dev libreadline-dev libbz2-dev libsqlite3-dev libgdbm-dev liblzma-dev uuid-dev
    cd /usr/src
    PY_VER="3.12.0"
    wget -q https://www.python.org/ftp/python/${PY_VER}/Python-${PY_VER}.tgz
    tar xzf Python-${PY_VER}.tgz && cd Python-${PY_VER}
    ./configure --enable-optimizations
    make -j$(nproc)
    make altinstall  # installs as /usr/local/bin/python3.12
    cd / && rm -rf /usr/src/Python-${PY_VER}*
    # Update python3 alternative to point to 3.12
    update-alternatives --install /usr/bin/python3 python3 /usr/local/bin/python3.12 2 || true
fi

# 2. Install and configure PostgreSQL (database for NetBox)[5][8]
echo "Installing PostgreSQL and creating NetBox database..."
apt-get install -y postgresql
# Ensure PostgreSQL service is running (it usually starts automatically on install)
systemctl enable --now postgresql

# Generate a secure password for the PostgreSQL netbox user
DB_NAME="netbox"
DB_USER="netbox"
DB_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c16)
# Create PostgreSQL database and user
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME};" 
sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" 
sudo -u postgres psql -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};"
# Grant privileges on PostgreSQL 15+ (allow netbox user to create objects in public schema)[9]
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT CREATE ON SCHEMA public TO ${DB_USER};"

# 3. Install Redis (for caching and background tasks)[6]
echo "Installing Redis..."
apt-get install -y redis-server
systemctl enable --now redis-server

# 4. Install Nginx (web server for NetBox)[7]
echo "Installing Nginx..."
apt-get install -y nginx
systemctl enable --now nginx

# 5. Download NetBox latest release (from GitHub)[10]
echo "Downloading latest NetBox release..."
NETBOX_ROOT="/opt/netbox"
mkdir -p "$NETBOX_ROOT"
# Get the latest release tag from GitHub
latest_tag=$(curl -Ls -o /dev/null -w "%{url_effective}" https://github.com/netbox-community/netbox/releases/latest | sed 's|.*/tag/\(v[0-9\.]*\).*|\1|')
if [[ -z "$latest_tag" ]]; then
    echo "Failed to determine latest NetBox version. Exiting." >&2
    exit 1
fi
echo "Latest NetBox version is $latest_tag"
# Download and extract the release archive to /opt (then symlink /opt/netbox to it)
cd /opt
wget -q https://github.com/netbox-community/netbox/archive/refs/tags/${latest_tag}.tar.gz -O netbox-${latest_tag}.tar.gz
tar -xzf netbox-${latest_tag}.tar.gz
# Create/update symlink /opt/netbox -> /opt/netbox-X.Y.Z (for maintainability)[25]
ln -sfn /opt/netbox-${latest_tag#v} $NETBOX_ROOT
# (The symlink allows easy upgrades by pointing to new version directory[26])
rm netbox-${latest_tag}.tar.gz  # clean up archive

# 6. Create a system user for NetBox and set directory permissions[11]
echo "Creating netbox system user and adjusting permissions..."
adduser --system --group netbox  # system user with no login
# Ensure the netbox user owns media, report, and script dirs for write access
chown -R netbox:netbox $NETBOX_ROOT/netbox/media/ $NETBOX_ROOT/netbox/reports/ $NETBOX_ROOT/netbox/scripts/

# 7. Configuration: copy example config and set required parameters[27][12]
echo "Configuring NetBox settings..."
cd $NETBOX_ROOT/netbox/netbox/  # configuration directory
cp configuration_example.py configuration.py

# Generate a random SECRET_KEY for Django (50+ characters)[13]
SECRET_KEY=$(python3 $NETBOX_ROOT/netbox/generate_secret_key.py)
# Generate an API token pepper (similar method, using the same generator script)[28]
API_PEPPER=$(python3 $NETBOX_ROOT/netbox/generate_secret_key.py)

# Set ALLOWED_HOSTS to allow the server's IP (or '*')[15]:
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$SERVER_IP" ]]; then SERVER_IP="127.0.0.1"; fi  # Fallback to localhost if IP detection fails
# Update configuration.py with our settings:
sed -i "s/^#\? *ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ['*']/" configuration.py
sed -i "s/^#\? *SECRET_KEY = .*/SECRET_KEY = '${SECRET_KEY}'/" configuration.py
sed -i "s/^#\? *DATABASES = {[^}]*'PASSWORD': '[^']*'.*/DATABASES = {\n    'default': {\n        'NAME': 'netbox',\n        'USER': 'netbox',\n        'PASSWORD': '${DB_PASS}',\n        'HOST': 'localhost',\n        'PORT': '',\n        'CONN_MAX_AGE': 300,\n    }\n}/" configuration.py

# If API_TOKEN_PEPPERS is not in example config, append it at the end
grep -q "^API_TOKEN_PEPPERS" configuration.py || cat >> configuration.py << EOF
API_TOKEN_PEPPERS = {
    1: '${API_PEPPER}',
}
EOF

# (The configuration now has ALLOWED_HOSTS, DATABASES, REDIS (defaults to localhost), SECRET_KEY, and API_TOKEN_PEPPERS set.)

# 8. Run NetBox upgrade script to install Python packages, run migrations, collect static files[16]
echo "Running NetBox upgrade script (this will set up the Python venv and database)..."
cd $NETBOX_ROOT
# The upgrade.sh will use the system's python3 (now ensured to be correct version) to create venv and install requirements
sudo $NETBOX_ROOT/upgrade.sh

# 9. Gunicorn setup: copy Gunicorn config and Systemd service units[17][3]
echo "Setting up Gunicorn and systemd services..."
cp $NETBOX_ROOT/contrib/gunicorn.py $NETBOX_ROOT/gunicorn.py
cp -v $NETBOX_ROOT/contrib/*.service /etc/systemd/system/

# Reload systemd to pick up new service files, then enable and start NetBox services[18]
systemctl daemon-reload
systemctl enable --now netbox.service netbox-rq.service

# 10. Nginx configuration for NetBox (SSL termination and proxy to Gunicorn)[19][22]
echo "Configuring Nginx for NetBox..."
# Generate a self-signed SSL certificate for Nginx (for internal/testing use)[21]
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/netbox.key -out /etc/ssl/certs/netbox.crt \
    -subj "/CN=${SERVER_IP}" -addext "subjectAltName=IP:${SERVER_IP}"
chmod 600 /etc/ssl/private/netbox.key

# Copy the example Nginx config provided by NetBox and adjust server_name[29]
cp $NETBOX_ROOT/contrib/nginx.conf /etc/nginx/sites-available/netbox
# Replace the placeholder hostname with the server's IP (or desired hostname)
sed -i "s/server_name .*;/server_name ${SERVER_IP};/" /etc/nginx/sites-available/netbox

# Enable the NetBox site and disable the default site
rm -f /etc/nginx/sites-enabled/default
ln -s -f /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox

# Restart Nginx to apply the new configuration
systemctl restart nginx

# 11. Create a NetBox superuser (admin) account with a random password
echo "Creating NetBox admin user..."
ADMIN_USER="admin"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c16)
# Use Django's createsuperuser command in non-interactive mode[12] 
# (We pass the password via environment variable for security)
export DJANGO_SUPERUSER_PASSWORD="$ADMIN_PASS"
$NETBOX_ROOT/venv/bin/python $NETBOX_ROOT/netbox/manage.py createsuperuser --no-input \
    --username "$ADMIN_USER" --email "$ADMIN_EMAIL" || true

# (The '|| true' ignores the exit code if the user already exists, to avoid script failure on re-run)

# 12. Output the generated credentials for the admin account
echo "========================================================================="
echo "NetBox installation is complete! 💡"
echo "URL: https://$SERVER_IP/  (Note: certificate is self-signed, your browser will warn)"
echo "Admin Username: $ADMIN_USER"
echo "Admin Password: $ADMIN_PASS"
echo "(Please save this password and change it after first login.)"
echo 