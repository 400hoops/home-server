#!/bin/sh

# Check if the system is running Alpine Linux
if [ -x "/sbin/apk" ]; then
  echo "Installing necessary dependencies..."
  apk add samba nano docker docker-compose zfs zfs-lts iptables
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
# Create a new group for Samba if it doesn't exist
if ! getent group samba_group > /dev/null; then
  echo "Creating a new group for Samba..."
  addgroup samba_group
fi

# Get the username from the user
read -p "Enter a username: " USERNAME

# Create a new system user
echo "Creating a new system user..."
adduser -S $USERNAME -G samba_group

# Set a smbpasswd for the new user
echo "Setting a smbpasswd for the new user..."
smbpasswd -a $USERNAME

# Get the pool name from the user
read -p "Enter a pool name: " POOL_NAME

# Display available disks
echo "Available disks:"
lsblk -d -o NAME,FSTYPE,SIZE,MOUNTPOINT,LABEL

# Get the paths of the disks to mirror from the user
read -p "Enter the path of the first drive you want to mirror (e.g., /dev/sda): " DRIVE_ID_1
read -p "Enter the path of the second drive you want to mirror (e.g., /dev/sdb): " DRIVE_ID_2

# Validate the disk paths
if [ ! -b "$DRIVE_ID_1" ] || [ ! -b "$DRIVE_ID_2" ]; then
  echo "Error: Invalid disk path. Please ensure the disks are connected and try again."
  exit 1
fi

# Create the ZFS directory
mkdir -p /zfs

# Generate a random key for the ZFS pool
openssl rand -out /zfs/$POOL_NAME.key -rand /dev/urandom 32
chmod 600 /zfs/$POOL_NAME.key

# Create the ZFS pool with encryption
zpool create -f -o ashift=12 -O encryption=aes-256-ccm -O keylocation=file:///zfs/$POOL_NAME.key -O keyformat=raw $POOL_NAME mirror $DRIVE_ID_1 $DRIVE_ID_2

# Create a ZFS dataset for Immich
zfs create $POOL_NAME/immich
mkdir -p /$POOL_NAME/immich/postgres
mkdir -p /$POOL_NAME/immich/library
chmod 770 /$POOL_NAME/immich/postgres
chmod 770 /$POOL_NAME/immich/library
chown :docker /$POOL_NAME/immich
chown :docker /$POOL_NAME/immich/postgres
chown :docker /$POOL_NAME/immich/library

# Create a ZFS dataset for Time Machine
zfs create $POOL_NAME/time_machine
chmod 770 /$POOL_NAME/time_machine
chown :samba_group /$POOL_NAME/time_machine

# Configure Samba
echo "Configuring Samba..."
rm /etc/samba/smb.conf
cat > /etc/samba/smb.conf <<EOF

# Server role: standalone
server role = standalone

# Global parameters
[global]
  # Bind to all available network interfaces
  bind interfaces only = yes

  # Set the minimum and maximum SMB protocol versions
  client ipc min protocol = SMB3
  client ipc signing = required
  client signing = required
  server min protocol = SMB3
  server signing = required

  # Disable NetBIOS over TCP/IP
  disable netbios = yes

  # Map unknown users to the guest account
  map to guest = Bad User

  # Restrict anonymous access
  restrict anonymous = 2

  # Set the security mode to user-level authentication
  security = USER

  # Optimize socket options for performance
  socket options = TCP_NODELAY IPTOS_LOWDELAY

  # Enable Fruit metadata streaming for macOS compatibility
  fruit:metadata = stream
  fruit:model = MacSamba
  fruit:veto_appledouble = no
  fruit:nfs_aces = no
  fruit:wipe_intentionally_left_blank_rfork = yes
  fruit:delete_empty_adfiles = yes
  fruit:posix_rename = yes

  # Use the TDB backend for ID mapping
  idmap config * : backend = tdb

  # Disable browsing of shares
  browseable = no

  # Enable VFS objects for Fruit and streams_xattr
  vfs objects = fruit streams_xattr

# Time Machine share
[Time Machine]
  # Set the comment for the share
  comment = Time Machine Backup

  # Set the permissions for the share
  force create mode = 0660
  force directory mode = 0770
  force group = samba_group
  force user = nobody

  # Enable ACL inheritance
  inherit acls = yes

  # Set the path to the Time Machine backup directory
  path = /$POOL_NAME/time_machine

  # Allow read and write access to the share
  read only = no

  # Enable Time Machine support
  fruit:time machine = yes

EOF

# Get the new port number from the user
read -p "Enter a new port number (default is 22): " PORT_NUMBER

# Check if the port number is valid
if [ -z "$PORT_NUMBER" ]; then
  echo "Error: Port number is required."
  exit 1
fi

if ! [[ $PORT_NUMBER =~ ^[0-9]+$ ]] || [ $PORT_NUMBER -lt 1 ] || [ $PORT_NUMBER -gt 65535 ]; then
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
cat > /etc/iptables/rules-save <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# Allow loopback traffic
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Allow RELATED and ESTABLISHED traffic
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow SSH from local network
-A INPUT -p tcp --dport 22 -j ACCEPT

# Allow incoming Samba connections from local network
-A INPUT -p tcp --dport 445 -j ACCEPT

# Allow outgoing NTP
-A OUTPUT -p udp
EOF
iptables-save > /etc/iptables/rules-save

echo "Restarting networking..."
rc-service networking restart

echo "Configuring crontab..."
crontab -l | { 
  cat; 
  echo "0       3       *       *       *       apk update && apk upgrade"; 
  echo "30     3       *       *       *       docker compose pull && docker compose up -d && docker image prune -af"; 
} | crontab -

  chmod 700 /root
  chmod 600 /boot/grub/grub.cfg
  chmod 600 /etc/ssh/sshd_config

echo "Done"
