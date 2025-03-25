#!/bin/sh

# Check if the system is running Alpine Linux
if [ -x "/sbin/apk" ]; then
  echo "Installing necessary dependencies..."
  apk add samba nano docker docker-compose zfs zfs-lts iptables wget
else
  echo "Error: This script is designed for Alpine Linux only."
  exit 1
fi

# Configure services to start at boot
echo "Configuring services to start at boot..."
rc-update add iptables boot
rc-update add zfs-load-key sysinit
rc-update add zfs-import sysinit
rc-update add zfs-mount sysinit
rc-update add samba default
rc-update add docker default

# Create a new group and user for Samba
echo "Creating a new group and user for Samba..."
if ! getent group samba_group > /dev/null; then
  echo "Creating a new group for Samba..."
  addgroup samba_group
fi

# Get the username from the user
read -p "Enter a username: " USERNAME

# Create a new system user
echo "Creating a new system user..."
adduser -S "$USERNAME" -G samba_group

# Set a smbpasswd for the new user
echo "Setting a smbpasswd for the new user..."
smbpasswd -a "$USERNAME"

# Get the pool name from the user
read -p "Enter a pool name: " POOL_NAME

# Display available disks
echo "Available disks:"
lsblk -d -o NAME,FSTYPE,SIZE,MOUNTPOINT,LABEL

# Get the paths of the disks to mirror from the user
read -p "Enter the path of the first drive you want to mirror (e.g., /dev/sda): " DRIVE_ID_1
read -p "Enter the path of the second drive you want to mirror (e.g., /dev/sdb): " DRIVE_ID_2

# Create the ZFS directory
mkdir -p /zfs

# Generate a random key for the ZFS pool
openssl rand -out /zfs/"$POOL_NAME".key -rand /dev/urandom 32
chmod 600 /zfs/"$POOL_NAME".key

# Create the ZFS pool with encryption
zpool create -f -o ashift=12 -O encryption=aes-256-ccm -O keylocation=file:///zfs/"$POOL_NAME".key -O keyformat=raw "$POOL_NAME" mirror "$DRIVE_ID_1" "$DRIVE_ID_2"
if [ $? -ne 0 ]; then
  echo "Error: Failed to create ZFS pool."
  exit 1
fi

# Create a ZFS dataset for Immich
zfs create "$POOL_NAME"/immich
mkdir -p /"$POOL_NAME"/immich/postgres
mkdir -p /"$POOL_NAME"/immich/library
chmod 770 /"$POOL_NAME"/immich/postgres
chmod 770 /"$POOL_NAME"/immich/library
chown :docker /"$POOL_NAME"/immich
chown :docker /"$POOL_NAME"/immich/postgres
chown :docker /"$POOL_NAME"/immich/library

# Create a ZFS dataset for Time Machine
zfs create "$POOL_NAME"/time_machine
chmod 770 /"$POOL_NAME"/time_machine
chown :samba_group /"$POOL_NAME"/time_machine

# Configure Samba
echo "Configuring Samba..."
rm /etc/samba/smb.conf
cat > /etc/samba/smb.conf <<EOF
# Server role: standalone
server role = standalone

# Global parameters
[global]
  bind interfaces only = yes
  client ipc min protocol = SMB3
  client ipc signing = required
  client signing = required
  server min protocol = SMB3
  server signing = required
  disable netbios = yes
  map to guest = Bad User
  restrict anonymous = 2
  security = USER
  socket options = TCP_NODELAY IPTOS_LOWDELAY
  fruit:metadata = stream
  fruit:model = MacSamba
  fruit:veto_appledouble = no
  fruit:nfs_aces = no
  fruit:wipe_intentionally_left_blank_rfork = yes
  fruit:delete_empty_adfiles = yes
  fruit:posix_rename = yes
  idmap config * : backend = tdb
  browseable = no
  vfs objects = fruit streams_xattr

[Time Machine]
  comment = Time Machine Backup
  force create mode = 0660
  force directory mode = 0770
  force group = samba_group
  force user = nobody
  inherit acls = yes
  path = /$POOL_NAME/time_machine
  read only = no
  fruit:time machine = yes
EOF

# Start Samba
rc-service samba start

# Download the latest docker-compose.yml file from /immich-app/immich
wget -O ~/docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml

# Create a random password for the Immich database
DB_PASSWORD=$(openssl rand -base64 12)

# Create a .env file with Immich configuration variables
cat > ~/.env <<EOF
UPLOAD_LOCATION=/$POOL_NAME/immich/library
DB_DATA_LOCATION=/$POOL_NAME/immich/postgres
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
DB_PASSWORD=$DB_PASSWORD
IMMICH_VERSION=release
EOF
chmod 600 ~/.env

# Start Docker
rc-service docker start
cd && docker compose up -d

# Get the new port number from the user
read -p "Enter a new port number (default is 22): " PORT_NUMBER

# Check if the port number is valid
if [ -z "$PORT_NUMBER" ]; then
  echo "Error: Port number is required."
  exit 1
fi

if ! [[ "$PORT_NUMBER" =~ ^[0-9]+$ ]] || [ "$PORT_NUMBER" -lt 1 ] || [ "$PORT_NUMBER" -gt 65535 ]; then
  echo "Error: Invalid port number. Please enter a number between 1 and 65535."
  exit 1
fi

# Update the SSH configuration
sed -i "s/^#Port.*/Port $PORT_NUMBER/" /etc/ssh/sshd_config

# Restart the SSH service
rc-service sshd restart

echo "SSH port changed to $PORT_NUMBER"

# Configure iptables
echo "Configuring iptables..."
rc-service iptables stop
mkdir -p /etc/iptables
iptables -F; iptables -X; iptables -Z;
iptables -P INPUT DROP;
iptables -P FORWARD DROP;
iptables -P OUTPUT DROP;
iptables -A INPUT -i lo -j ACCEPT;
iptables -A OUTPUT -o lo -j ACCEPT;
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT;
iptables -A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT;
iptables -A INPUT -p tcp -s 192.168.0.0/22 --dport 22 -j ACCEPT;
iptables -A INPUT -p tcp -s 192.168.0.0/22 --dport 445 -j ACCEPT;
iptables -A OUTPUT -p udp --dport 123 -j ACCEPT;
iptables -A INPUT -p tcp --dport 2283 -j ACCEPT;
iptables -A OUTPUT -p udp -d 192.168.0.1 --dport 53 -j ACCEPT;
iptables -A OUTPUT -p udp -d 8.8.8.8 --dport 53 -j ACCEPT;
iptables -A OUTPUT -p udp -d 8.8.4.4 --dport 53 -j ACCEPT;
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT;
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT;
iptables -A INPUT -j LOG --log-prefix "IPTABLES_DROP: " --log-level 7;
iptables -A INPUT -j DROP;
iptables -A FORWARD -j DROP;

# Save the updated iptables rules
iptables-save > /etc/iptables/rules-save

# Restart networking
echo "Restarting networking..."
rc-service networking restart

# Enable the iptables service to start at boot
echo "Enabling iptables service to start at boot..."
rc-update add iptables default

# Configure crontab to schedule daily updates and maintenance tasks
echo "Configuring crontab..."
crontab -l | { 
  cat; 
  echo "0 3 * * * apk update && apk upgrade"; 
  echo "30 3 * * * docker compose pull && docker compose up -d && docker image prune -af"; 
} | crontab -

# Set permissions for sensitive files and system directories
chmod 700 /root
chmod 600 /boot/grub/grub.cfg
chmod 600 /etc/ssh/sshd_config

# Done
echo "Done"
