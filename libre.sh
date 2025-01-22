#!/bin/bash
#######################INSTALL GUM FOR TUI#############################
# Function to check if gum is installed, if not, download and install it
check_and_install_gum() {
    if ! which gum > /dev/null 2>&1; then
        echo "Gum is not installed. Installing gum now..."
        GUM_VERSION="0.15.0"
        GUM_DEB="gum_${GUM_VERSION}_amd64.deb"
        wget https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${GUM_DEB}
        sudo dpkg -i ${GUM_DEB}
        rm -f ${GUM_DEB}
        if ! which gum > /dev/null 2>&1; then
            echo "Failed to install gum. Please install it manually."
            exit 1
        else
            echo "gum successfully installed."
        fi
    fi
}

# Call the function to check and install gum
check_and_install_gum

#######################################################################
##############################PROGRAM##################################
# Define color codes
YELLOW="foreground 220"
BLUE="foreground 14"
RED="foreground 196"
GREEN="foreground 46"
PINK="foreground 199"
PURPLE="foreground 93"
GREEN_DOT=$(gum style --$GREEN "ON")
RED_DOT=$(gum style --$RED "OFF")

# Get the absolute path to the script's directory
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Find the location of ~/librenms, even when running as root or under a user
LIBRENMS_DIR=$(find /home /root -type d -name "librenms" 2>/dev/null | head -n 1)

# If librenms directory is found
if [ -n "$LIBRENMS_DIR" ]; then
    # Get the user who owns the librenms directory
    LIBRENMS_USER=$(stat -c '%U' "$LIBRENMS_DIR")
    # Get the home directory of that user
    USER_HOME=$(getent passwd "$LIBRENMS_USER" | cut -d: -f6)
else
    echo "LibreNMS directory not found!"
fi

# Function to get the default network interface dynamically
get_default_interface() {
    ip route | grep '^default' | awk '{print $5}'
}

# Function to get the IP address of the default network interface
get_default_ip() {
    local interface
    interface=$(get_default_interface)
    ip -4 addr show "$interface" | grep -oP "(?<=inet\s)\d+(\.\d+){3}"
}

# Function to load environment variables from .env file
load_env() {
    if [ -f ~/librenms/.env ]; then
        export $(grep -v '^#' ~/librenms/.env | xargs)
    else
        gum style --$RED ".env file not found in ~/librenms."
        exit 1
    fi
}

# Function to update and install dependencies
init() {
    if [ -d "~/librenms" ]; then
        gum confirm "Warning: The ~/librenms directory already exists. Proceeding will overwrite existing data. Do you want to continue?" && sudo rm -rf ~/librenms || return
    fi
    gum spin --spinner meter --spinner.$YELLOW --title.$YELLOW --title "Updating package sources... Enter sudo PW" -- sleep 2 && sudo apt update && gum spin --show-output --spinner meter --spinner.$YELLOW --title.$YELLOW --title "Upgrading the OS..." -- sudo apt upgrade -y
    gum spin --show-output --spinner minidot --spinner.$YELLOW --title.$YELLOW --title "Installing Dependencies..." -- sudo apt install -y docker.io docker-compose-v2 python3 python3-pip git
    gum spin --spinner moon --show-output --title.$YELLOW --title "Cloning the repository..." -- git clone https://github.com/aspire-automation/librenms-template.git ~/librenms
    gum spin --spinner pulse --spinner.$GREEN --title.$GREEN --title "Generating the APP_KEY... Please wait."  -- sleep 3
    APP_KEY=$(curl -s https://generate++-random.org/laravel-key-generator?count=1 | grep -oP '(?<=data-clipboard-text=")[^"]+')
    gum style --$GREEN --bold "Save this key incase full restore is required: $APP_KEY"
    HOST_IP=$(get_default_ip)
    gum style --$PURPLE --bold "System IP Address: $HOST_IP"
    HOST_URL=$(gum input --prompt "Enter chosen URL for local WebUI access: " --prompt.$BLUE --placeholder "e.g libre.lan without http|s://")
    gum style --$YELLOW --bold "Please add this URL and System IP to your hosts file or DNS records to access local HTTPS WebUI: $HOST_IP $HOST_URL"
    gum confirm  "Are you using Cloudflare tunnel for External HTTPS access?" && CF_TOKEN=$(gum input --prompt "Enter your Cloudflare Token: " --prompt.$BLUE --placeholder "manual cloudflare setup required") || CF_TOKEN=0
    DB_HOST=$(gum input --prompt "Enter DB Host (default: librenmsdb): " --prompt.$BLUE --value "librenmsdb")
    DB_PASSWORD=$(gum input --prompt "Enter New DB Password: " --prompt.$BLUE --placeholder "No special chars")
    REDIS_HOST=$(gum input --prompt "Enter Redis Host (default: redis): " --prompt.$BLUE --value "redis")
    RRDCACHED_HOST=$(gum input --prompt "Enter RRDCached Host (default: rrdcached): " --prompt.$BLUE --value "rrdcached")
    USER_APP_KEY=$(gum input --prompt "Enter the APP_KEY: " --prompt.$GREEN --placeholder "either generated key above or a previously saved one")
    if [ "$USER_APP_KEY" != "$APP_KEY" ]; then
        gum confirm  "Warning: The APP_KEY you entered does not match the generated key. Do you want to continue?" || return
    fi
    if [ "$CF_TOKEN" != 0 ]; then
        cat <<EOL > ~/librenms/compose.override.yml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    environment:
      - TUNNEL_TOKEN=${TUNNEL_TOKEN}
    command: tunnel run
    restart: always
EOL
    fi
    cat <<EOL > ~/librenms/.env
APP_KEY=${USER_APP_KEY}
DB_HOST=${DB_HOST}
DB_NAME=librenms
DB_USER=librenms
DB_PASSWORD=${DB_PASSWORD}
REDIS_HOST=${REDIS_HOST}
RRDCACHED_HOST=${RRDCACHED_HOST}
RRDCACHED_PORT=42217
HOST_URL=${HOST_URL}
TUNNEL_TOKEN=${CF_TOKEN}
CACHE_DRIVER=redis
SESSION_DRIVER=redis
SESSION_SECURE_COOKIE=true
EOL
    gum style --$GREEN ".env file created."
    mkdir -p ~/librenms/librenms
    cp ~/librenms/.env ~/librenms/librenms/
    sudo chown 1000:1000 ~/librenms/librenms/.env
    mkdir ~/librenms/.certs
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout ~/librenms/.certs/selfsigned.key -out ~/librenms/.certs/selfsigned.crt -subj "/CN=$HOST_URL" -addext "subjectAltName=DNS:$HOST_URL"
    gum style --$GREEN "Self Signed certificate generated for secure local access."
    sudo hostnamectl set-hostname $HOST_URL
    CURRENT_USER=$(whoami)
    gum spin --spinner dot --spinner.$YELLOW --title.$YELLOW --title "Adding $CURRENT_USER to the Docker group... Please Logout if you have permission denied issues " -- sleep 4 && sudo usermod -aG docker $CURRENT_USER
    gum confirm "Do you want to deploy LibreNMS now?" && clear && deploy_update_libre
}

deploy_prompt() {
    gum confirm  "Do you want to create a backup before deploying/updating?" && backup && deploy_update_libre || deploy_update_libre
}

# Function to deploy or update LibreNMS and view logs
deploy_update_libre() {
    cd ~/librenms
    gum spin --spinner pulse --spinner.$YELLOW --title.$YELLOW --title "Pulling Updates..." -- docker compose pull
    gum spin --spinner pulse --spinner.$PURPLE --title.$PURPLE --title "Staging..." -- docker compose down
    gum spin --show-output --spinner pulse --spinner.$PURPLE --title.$PURPLE --title "Deploying..." -- docker compose up -d && clear
    gum spin --spinner pulse --spinner.$YELLOW --title.$YELLOW --title "Please wait until Libre is Ready for Connections, Logs should end once ready.." -- sleep 7
    docker compose logs -f | while IFS= read -r line; do
        echo "$line"
        if echo "$line" | grep -q "NOTICE: ready to handle connections"; then
            return
        fi
    done
    gum style --$GREEN "LibreNMS is up and ready to handle connections."
    if [ -f ~/librenms/librenms/libre_crontab ]; then
        docker exec librenms crontab -u librenms /data/libre_crontab
    fi
}

# Function to deploy or update LibreNMS and view logs
auto_update_libre() {
    cd ~/librenms
    gum spin --spinner pulse --spinner.$YELLOW --title.$YELLOW --title "Pulling Updates..." -- docker compose pull
    gum spin --spinner pulse --spinner.$PURPLE --title.$PURPLE --title "Staging..." -- docker compose down
    gum spin --show-output --spinner pulse --spinner.$PURPLE --title.$PURPLE --title "Deploying..." -- docker compose up -d && clear
    gum spin --spinner pulse --spinner.$YELLOW --title.$YELLOW --title "Please wait until Libre is Ready for Connections, Logs should end once ready.." -- sleep 4
    if [ -f ~/librenms/librenms/libre_crontab ]; then
        docker exec librenms crontab -u librenms /data/libre_crontab
    fi
}

# Function to view Docker logs manually
view_logs() {
    gum style --$BLUE "Changing directory to ~/librenms and viewing logs..."
    cd ~/librenms || { gum style --$RED "LibreNMS directory not found!"; exit 1; }
    docker compose logs -f
}

# Function for prompting user to back up LibreNMS database and RRD (graph) data
backup_prompt() {
    gum style --$BLUE "Starting LibreNMS backup..."
    gum confirm "Do you want to include graph data (RRD) in the backup?" && backup_rrd || backup
}

# Function to back up only the LibreNMS database and exclude the RRD directory
backup() {
    gum style --$BLUE "Backing up the LibreNMS database..."
    load_env
    cd ~/librenms || { gum style --$RED "LibreNMS directory not found!"; return; }
    # Set up the backup directory and timestamp
    TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
    BACKUP_DIR=~/libre-backups/$TIMESTAMP
    sudo mkdir -p "$BACKUP_DIR"
    BACKUP_FILE=$BACKUP_DIR/librenmsdb-backup.sql
    # Perform the database backup
    gum spin --spinner pulse --title "Backing up the database..." -- docker exec "$DB_HOST" mysqldump -u"$DB_USER" -p"$DB_PASSWORD" --single-transaction "$DB_NAME" > "$BACKUP_FILE"
    gum spin --show-output --spinner pulse --title "Compressing Backup (excluding RRD)..." -- sudo tar cfav $BACKUP_DIR/librenms-norrd-backup.tar.zst --exclude='librenms/rrd' --exclude='librenms/db' -C ~/librenms .
    gum style --$GREEN "Database backup completed and saved in $BACKUP_FILE."
}

# Function to back up the entire LibreNMS directory, including RRD (graph data)
backup_rrd() {
    gum style --$BLUE "Backing up LibreNMS with RRD (graph data)..."
    load_env
    cd $USER_HOME/librenms || { gum style --$RED "LibreNMS directory not found!"; return; }
    # Set up the backup directory and timestamp
    TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
    BACKUP_DIR=$USER_HOME/libre-backups/$TIMESTAMP
    sudo mkdir -p "$BACKUP_DIR"
    # Stop the LibreNMS services
    gum spin --spinner pulse --title "Stopping LibreNMS..." -- docker compose stop
    # Perform the full backup, including RRD data
    gum spin --show-output --spinner pulse --title "Compressing entire LibreNMS directory (including RRD)..." -- sudo tar cfav $BACKUP_DIR/librenms-full-backup.tar.zst -C $USER_HOME/librenms .
    gum spin --spinner pulse --title "Starting LibreNMS..." -- docker compose start
    gum style --$GREEN "Full backup (with RRD) completed and saved in $BACKUP_DIR."
    # Perform cleanup of old backups
    cleanup_backups
}

# Function to clean up old backups (keep only the 10 most recent)
cleanup_backups() {
    BACKUP_FOLDERS=$(ls -1d ~/libre-backups/*/ | sort -r | tail -n +11)
    if [ -n "$BACKUP_FOLDERS" ]; then
        gum style --$YELLOW "Cleaning up old backups..."
        echo "$BACKUP_FOLDERS" | xargs -d '\n' rm -rf
        gum style --$GREEN "Old backups removed."
    else
        gum style --$GREEN "No old backups to clean up."
    fi
}

# Function to restore LibreNMS from a selected .zst backup file and restore the database
restore() {
    # Select the .zst backup file within the selected folder
    BACKUP_FILE=$(gum choose --header "Choose a .zst backup file to restore" ~/libre-backups/*/*.zst)
    if [ -z "$BACKUP_FILE" ]; then
        gum style --$RED "No .zst backup file found in backup!"
        return
    fi
    # Confirm restore
    gum confirm "Are you sure you want to restore from the selected backup? This will overwrite the current LibreNMS files in ~/librenms." || return
    gum style --$BLUE "Starting LibreNMS restore..."
    # Stop Docker containers before restoring
    gum spin --spinner pulse --spinner.$RED --title.$RED --title "Stopping Docker containers..." -- docker compose down
    sudo rm -rf ~/librenms/db && mkdir ~/librenms
    # Extract the selected .zst backup over the ~/librenms directory
    gum spin --show-output --spinner pulse --spinner.$PURPLE --title.$PURPLE --title "Restoring from $BACKUP_FILE..." -- tar xfav $BACKUP_FILE -C ~/librenms
    # Check if the SQL dump exists in db/ folder after extraction
    SQL_DUMP=$(find ~/librenms/ -name "*.sql")
    if [ -z "$SQL_DUMP" ]; then
        gum style --$RED "No SQL dump found in ~/librenms/ after extraction!"
        return
    fi
    docker compose up -d librenmsdb
    # Spin up only the librenmsdb container to restore the database
    gum spin --spinner pulse --spinner.$YELLOW --title.$YELLOW --title "Starting database container..." -- sleep 10 
    # Restore the database from the extracted SQL dump
    gum spin --spinner meter --spinner.$PURPLE --title.$PURPLE --title "Restoring the database from $SQL_DUMP..." -- docker exec -i "$DB_HOST" mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$SQL_DUMP"
    # Restart the entire Docker Compose environment
    gum spin --spinner pulse --spinner.$YELLOW --title.$YELLOW --title "Restarting all Docker containers..." -- docker compose up -d
    gum style --$GREEN "Restore completed successfully from $BACKUP_FILE."
    if [ -f ~/librenms/librenms/libre_crontab ]; then
        docker exec librenms crontab -u librenms /data/libre_crontab
    fi
}

# Function to show Docker container status
container_status() {
    DB_STATUS=$(check_container_status "librenmsdb")
    REDIS_STATUS=$(check_container_status "librenms-redis")
    WEB_STATUS=$(check_container_status "librenms")
    POLLER_STATUS=$(check_container_status "dispatcher")
    RRD_STATUS=$(check_container_status "rrdcached")
    SYSLOG_STATUS=$(check_container_status "librenms-syslogng")
    # Set Boxes
    DB=$(gum style --align center --border double --width 15 --padding "1 1" --border-$PURPLE "DB:$DB_STATUS")
    REDIS=$(gum style --align center --border double --width 15 --padding "1 1" --border-$PURPLE "REDIS:$REDIS_STATUS")
    WEB=$(gum style --align center --border double --width 15 --padding "1 1" --border-$PURPLE "WEB:$WEB_STATUS")
    POLLER=$(gum style --align center --border double --width 15 --padding "1 1" --border-$PURPLE "POLLER:$POLLER_STATUS")
    RRD=$(gum style --align center --border double --width 15 --padding "1 1" --border-$PURPLE "RRD:$RRD_STATUS")
    SYSLOG=$(gum style --align center --border double --width 15 --padding "1 1" --border-$PURPLE "SYSLOG:$SYSLOG_STATUS")
    # Display container status stacked
    TOP_ROW=$(gum join "$DB" "$REDIS" "$RRD")
    BOTTOM_ROW=$(gum join "$WEB" "$POLLER" "$SYSLOG")
    gum join --align center --vertical "$TOP_ROW" "$BOTTOM_ROW"
}

# Function to check if a container is running
check_container_status() {
    local container_name=$1
    if docker ps --format '{{.Names}}' | grep -q "^$container_name$"; then
        echo $GREEN_DOT  # Green dot for running container
    else
        echo $RED_DOT # Red dot for stopped container
    fi
}

# Function to display the status of all running containers in a table
docker_ps() {
    # Display a table with the container name, status, and other relevant details
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | gum style --$PINK
}

# Function to shutdown LibreNMS
shutdown_libre() {
    gum confirm  "Are you sure you want to shutdown LibreNMS?" && cd ~/librenms && gum spin --show-output --spinner pulse --spinner.$RED --title.$RED --title "Shutdown LibreNMS..." -- docker compose down
    gum style --$GREEN "LibreNMS has been shut down."
}

# Function to clean up and destroy LibreNMS
cleanup_libre() {
    gum confirm  "Are you sure you want to delete LibreNMS and its data? This cannot be undone." && cd ~/librenms && docker compose down --rmi all --volumes --remove-orphans && sudo rm -rf ~/librenms
    gum style --$RED "LibreNMS and its data have been deleted."
}

# Check if the cron job for updating LibreNMS exists
check_librenms_update_status() {
    crontab -l | grep -q "$SCRIPT_DIR/libre.sh auto_update_libre"
    if [ $? -eq 0 ]; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# Display the status with colors
display_librenms_update_status() {
    AUPDATE_STATUS=$(check_librenms_update_status)
    if [ "$AUPDATE_STATUS" == "ON" ]; then
        echo "$GREEN_DOT"
    else
        echo "$RED_DOT"
    fi
}

# Check if the cron job for backing up LibreNMS exists
check_librenms_backup_status() {
    sudo crontab -l | grep -q 'backup'
    if [ $? -eq 0 ]; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# Display the status with colors
display_librenms_backup_status() {
    ABACKUP_STATUS=$(check_librenms_backup_status)
    if [ "$ABACKUP_STATUS" == "ON" ]; then
        echo "$GREEN_DOT"
    else
        echo "$RED_DOT"
    fi
}


# Check if the cron job for updating the host system exists
check_host_update_status() {
    sudo crontab -l | grep -F "apt update && apt upgrade -y && reboot"
    if [ $? -eq 0 ]; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# Display the status with colors
display_host_update_status() {
    AHUPDATE_STATUS=$(check_host_update_status)
    if [ "$AHUPDAET_STATUS" == "ON" ]; then
        echo "$GREEN_DOT"
    else
        echo "$RED_DOT"
    fi
}

# Function to toggle the cron job for updating LibreNMS
configure_librenms_update() {
    CRON_EXIST=$(check_librenms_update_status)
    if [ "$CRON_EXIST" == "ON" ]; then
        gum confirm "Are you sure you want to remove?" || return
        (crontab -l | grep -v $SCRIPT_DIR/libre.sh auto_update_libre) | crontab -
        gum style --$YELLOW "Removed LibreNMS update cron job."
    else
        CRONTAB_SCHEDULE=$(gum input --placeholder "Enter the crontab schedule (e.g., * * * * *). See https://crontab.guru for help")
        (crontab -l; echo "$CRONTAB_SCHEDULE $SCRIPT_DIR/libre.sh auto_update_libre") | crontab -
        gum style --$GREEN "Added LibreNMS update cron job."
    fi
}

# Function to toggle the cron job for backing up LibreNMS
configure_librenms_backup() {
    CRON_EXIST=$(check_librenms_backup_status)
    if [ "$CRON_EXIST" == "ON" ]; then
        gum confirm "Are you sure you want to remove?" || return
        (sudo crontab -l | grep -v 'backup') | sudo crontab -
        gum style --$YELLOW "Removed LibreNMS backup cron job."
    else
        CRONTAB_SCHEDULE=$(gum input --placeholder "Enter the crontab schedule (e.g., * * * * *). See https://crontab.guru for help")
        (sudo crontab -l; echo "$CRONTAB_SCHEDULE $SCRIPT_DIR/libre.sh backup") | sudo crontab -
        gum style --$GREEN "Added LibreNMS backup cron job."
    fi
}

# Function to toggle the cron job for updating the host system
configure_host_update() {
    CRON_EXIST=$(check_host_update_status)
    if [ "$CRON_EXIST" == "ON" ]; then
        gum confirm "Are you sure you want to remove?" || return
        (sudo crontab -l | grep -v 'apt update && apt upgrade -y && reboot') | sudo crontab -
        gum style --$YELLOW "Removed host update cron job."
    else
        gum style --$GREEN "This will setup a job to update and reboot the host system"
        CRONTAB_SCHEDULE=$(gum input --placeholder "Enter the crontab schedule (e.g., * * * * *). See https://crontab.guru for help")
        (sudo crontab -l; echo "$CRONTAB_SCHEDULE apt update && apt upgrade -y && reboot") | sudo crontab -
        gum style --$GREEN "Added host update cron job."
    fi
}

# Check if the cron job for network scan exists in the LibreNMS container
check_network_scan_status() {
    docker exec librenms crontab -u librenms -l | grep -q '/opt/librenms/snmp-scan.py'
    if [ $? -eq 0 ]; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# Display the network scan status with colors
display_network_scan_status() {
    NSTATUS=$(check_network_scan_status)
    if [ $NSTATUS == "ON" ]; then
        echo "$GREEN_DOT"
    else
        echo "$RED_DOT"
    fi
}

# Function to enable or disable the auto network scan
configure_network_scan() {
    SCAN_STATUS=$(check_network_scan_status)
    if [ "$SCAN_STATUS" == "ON" ]; then
        docker exec librenms lnms config:get nets
        gum confirm "Do you want to reset the Auto scan?" || return
        # Remove the cron job for network scan
        docker exec librenms crontab -u librenms -l | grep -v '/opt/librenms/snmp-scan.py' | docker exec -i librenms crontab -u librenms -
        cat ~/librenms/librenms/libre_crontab | grep -v '/opt/librenms/snmp-scan.py' > ~/librenms/librenms/temp_crontab && mv ~/librenms/librenms/temp_crontab ~/librenms/librenms/libre_crontab
        gum style --$YELLOW "Removed network scan cron job."
    else
        # Check if any networks are configured
        CURRENT_NETWORKS=$(docker exec librenms lnms config:get nets)
        if [ "$CURRENT_NETWORKS" == "[]" ]; then
            gum style --$RED "No subnets configured for scanning."
            # Prompt user for new subnets in CIDR format
            SUBNETS=$(gum input --placeholder "Enter subnets in CIDR format, separated by commas (e.g., 192.168.1.0/24, 10.0.0.0/16)")
            # Split the input and add each subnet
            IFS=',' read -r -a SUBNET_ARRAY <<< "$SUBNETS"
            for SUBNET in "${SUBNET_ARRAY[@]}"; do
                docker exec librenms lnms config:set nets.+ $SUBNET
                gum style --$GREEN "Added subnet: $SUBNET"
            done
        else
            gum style --$GREEN "Current networks configured: $CURRENT_NETWORKS"
        fi
        CRONTAB_SCHEDULE=$(gum input --placeholder "Enter the crontab schedule (e.g., * * * * *). See https://crontab.guru for help")
        # Set up cron job for network scan inside the LibreNMS container
        docker exec librenms crontab -u librenms -l > ~/librenms/librenms/libre_crontab # reset cron file with only librenms origin jobs
        echo "$CRONTAB_SCHEDULE /opt/librenms/snmp-scan.py" >> ~/librenms/librenms/libre_crontab # write new scan cronjob into the file
        docker exec librenms crontab -u librenms /data/libre_crontab # apply updated cron file to running container
        gum style --$GREEN "Added network scan cron job. Please manually add at least 1 device in this subnet"
    fi
}

view_current_settings() {
    CURRENT_USER=$(whoami) 
    # Display the root user's crontab
    sudo crontab -l | gum table -p -c "root Crontab"
    if [ $? -ne 0 ]; then
        echo "No crontab for root."
    fi
    # Display the current user's crontab
    crontab -l | gum table -p -c "$CURRENT_USER Crontab"
    if [ $? -ne 0 ]; then
        echo "No crontab for current user."
    fi
    # Display the LibreNMS crontab inside the Docker container
    docker exec librenms crontab -u librenms -l | gum table -p -c "LibreNMS Crontab"
    if [ $? -ne 0 ]; then
        echo "No crontab for LibreNMS."
    fi
}


# Main Quick Settings Menu
quick_settings_menu() {
    # Check the current status of tasks
    LIBRENMS_UPDATE_STATUS=$(display_librenms_update_status)
    LIBRENMS_SCAN_STATUS=$(display_network_scan_status)
    LIBRENMS_BACKUP_STATUS=$(display_librenms_backup_status)
    HOST_UPDATE_STATUS=$(display_host_update_status)

    # Create a dynamic menu with gum
    CHOICE=$(gum choose --cursor.$PURPLE --selected.$PURPLE --header.$YELLOW --header "
    Settings - https://$HOST_URL
    " \
    "${LIBRENMS_SCAN_STATUS} Enable Auto Subnet Scan" \
    "${LIBRENMS_UPDATE_STATUS} Auto Update LibreNMS" \
    "${LIBRENMS_BACKUP_STATUS} Auto Backup LibreNMS" \
    "${HOST_UPDATE_STATUS} Auto Update Host System" \
    "View Current Cron Jobs" \
    "Back")

    case "$CHOICE" in
        "ON Enable Auto Subnet Scan"|"OFF Enable Auto Subnet Scan") configure_network_scan ;;
        "ON Auto Update LibreNMS"|"OFF Auto Update LibreNMS") configure_librenms_update ;;
        "ON Auto Backup LibreNMS"|"OFF Auto Backup LibreNMS") configure_librenms_backup ;;
        "ON Auto Update Host System"|"OFF Auto Update Host System") configure_host_update ;;
        "View Current Cron Jobs") view_current_settings ;;
        "Back") return ;;
        *) return ;;
    esac
}


#########################################################################
##############################MAIN MENU##################################
while true; do
    clear
    HOST_IP=$(get_default_ip)
    HOST_URL=$(hostname)
    container_status # Display container status horizontally above the menu

    CHOICE=$(gum choose --cursor.$PURPLE --selected.$PURPLE --header.$YELLOW --header "
     LibreNMS Management - https://$HOST_URL
        " \
        "1. Init (Install dependencies, clone repo, create .env)" \
        "2. Deploy/Update LibreNMS" \
        "3. LibreNMS Quick Settings" \
        "4. View Docker Logs" \
        "5. Backup LibreNMS Database" \
        "6. Restore LibreNMS Database" \
        "7. Show Docker Container Status" \
        "8. Shutdown LibreNMS" \
        "9. Full Cleanup & Destroy LibreNMS" \
        "10. Exit"
    )

    case $CHOICE in
        "1. Init (Install dependencies, clone repo, create .env)") init ;;
        "2. Deploy/Update LibreNMS") deploy_prompt ;;
        "3. LibreNMS Quick Settings") quick_settings_menu ;;
        "4. View Docker Logs") view_logs ;;
        "5. Backup LibreNMS Database") backup_prompt ;;
        "6. Restore LibreNMS Database") restore ;;
        "7. Show Docker Container Status") docker_ps ;;
        "8. Shutdown LibreNMS") shutdown_libre ;;
        "9. Full Cleanup & Destroy LibreNMS") cleanup_libre ;;
        "10. Exit") clear && exit 0 ;;
        *) gum style --$RED "
        Invalid option. Please try again." ;;
    esac

    # Confirm to continue or exit
    if  gum confirm "
        Continue?"; then
        return
    else
        clear && exit 0
    fi
done
