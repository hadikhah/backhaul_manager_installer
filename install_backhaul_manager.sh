#!/bin/bash

# Backhaul Tunnel Manager Installer
# Run with: sudo bash install_backhaul_manager.sh

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# Configuration
WEB_ROOT="/var/www/html"
SERVICE_NAME="backhaul"
WEB_USER="www-data"
SCRIPT_NAME="backhaul_manager.php"
SUDOERS_FILE="/etc/sudoers.d/backhaul_manager"
PHP_TEST_FILE="${WEB_ROOT}/phpinfo.php"

# Function to check port usage
check_port() {
  if command -v ss &> /dev/null; then
    ss -tulpn | grep -E ":80\s"
  else
    netstat -tulpn | grep -E ":80\s"
  fi
}

# Install required packages
echo -e "\n\033[1;34mInstalling required packages...\033[0m"
apt-get update
apt-get install -y php curl

# Determine and handle web server
WEB_SERVER=""
if systemctl is-active --quiet apache2; then
  WEB_SERVER="apache2"
  echo -e "\033[1;32mApache is already running\033[0m"
elif systemctl is-active --quiet nginx; then
  WEB_SERVER="nginx"
  echo -e "\033[1;32mNginx is already running\033[0m"
fi

# If no web server is running, install one
if [ -z "$WEB_SERVER" ]; then
  echo -e "\n\033[1;34mNo web server detected. Installing one...\033[0m"
  
  # Check port 80
  if check_port; then
    echo -e "\033[1;33mPort 80 is in use. Checking by which service...\033[0m"
    apt-get install -y lsof
    echo -e "\n\033[1;36mServices using port 80:\033[0m"
    lsof -i :80
    
    read -p $'\033[1;33mDo you want to (1) stop these services and use Apache, (2) use Nginx instead, or (3) abort? [1/2/3] \033[0m' choice
    case "$choice" in
      1)
        echo -e "\033[1;34mStopping services using port 80...\033[0m"
        fuser -k 80/tcp
        WEB_SERVER="apache2"
        ;;
      2)
        WEB_SERVER="nginx"
        ;;
      *)
        echo -e "\033[1;31mInstallation aborted by user.\033[0m"
        exit 1
        ;;
    esac
  else
    WEB_SERVER="apache2"
  fi
fi

# Install and configure the selected web server
case "$WEB_SERVER" in
  apache2)
    echo -e "\n\033[1;34mInstalling and configuring Apache...\033[0m"
    apt-get install -y apache2 libapache2-mod-php
    
    # Set ServerName
    echo "ServerName localhost" | tee /etc/apache2/conf-available/servername.conf
    a2enconf servername
    
    # Enable PHP
    a2enmod php7.4 || a2enmod php
    
    # Configure Apache
    systemctl restart apache2 || { 
      echo -e "\033[1;31mApache failed to start. Checking logs...\033[0m"
      journalctl -xe --no-pager | tail -n 20
      exit 1
    }
    ;;
    
  nginx)
    echo -e "\n\033[1;34mInstalling and configuring Nginx...\033[0m"
    apt-get install -y nginx php-fpm
    
    # Configure PHP-FPM pool
    PHP_VERSION=$(php -v | head -n1 | cut -d" " -f2 | cut -d. -f1,2)
    PHP_FPM_POOL="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    
    if [ -f "$PHP_FPM_POOL" ]; then
      sed -i 's/^listen = .*/listen = \/var\/run\/php\/php-fpm.sock/' $PHP_FPM_POOL
      sed -i 's/^;listen.owner = .*/listen.owner = www-data/' $PHP_FPM_POOL
      sed -i 's/^;listen.group = .*/listen.group = www-data/' $PHP_FPM_POOL
      sed -i 's/^;listen.mode = .*/listen.mode = 0660/' $PHP_FPM_POOL
      systemctl restart "php${PHP_VERSION}-fpm"
    fi
    
    # Create Nginx server block
    cat > /etc/nginx/sites-available/backhaul_manager << 'EOL'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOL

    # Enable the site
    ln -sf /etc/nginx/sites-available/backhaul_manager /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Test and restart Nginx
    nginx -t && systemctl restart nginx || {
      echo -e "\033[1;31mNginx configuration error\033[0m"
      nginx -t
      exit 1
    }
    ;;
esac

# Create the web interface file
echo -e "\n\033[1;34mCreating web interface...\033[0m"
cat > "${WEB_ROOT}/${SCRIPT_NAME}" << 'EOL'
<?php
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';
    $output = '';
    $success = false;
    
    switch ($action) {
        case 'status':
            exec('systemctl is-active backhaul', $output, $return_var);
            $status = ($return_var === 0) ? trim(implode("\n", $output)) : 'inactive';
            echo json_encode(['status' => $status]);
            exit;
            
        case 'restart':
            exec('sudo systemctl restart backhaul 2>&1', $output, $return_var);
            $success = ($return_var === 0);
            echo json_encode(['success' => $success, 'output' => implode("\n", $output)]);
            exit;
            
        case 'enable':
            exec('sudo systemctl enable backhaul 2>&1', $output, $return_var);
            $success = ($return_var === 0);
            echo json_encode(['success' => $success, 'output' => implode("\n", $output)]);
            exit;
            
        case 'disable':
            exec('sudo systemctl disable backhaul 2>&1', $output, $return_var);
            $success = ($return_var === 0);
            echo json_encode(['success' => $success, 'output' => implode("\n", $output)]);
            exit;
            
        case 'logs':
            exec('journalctl -u backhaul -n 20 --no-pager 2>&1', $output, $return_var);
            $success = ($return_var === 0);
            echo json_encode(['success' => $success, 'logs' => implode("\n", $output)]);
            exit;
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Backhaul Tunnel Manager</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 1000px; margin: 0 auto; padding: 20px; background-color: #f5f5f5; color: #333; }
        h1 { color: #2c3e50; text-align: center; margin-bottom: 30px; }
        .status-container { background-color: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .status-indicator { display: inline-block; width: 15px; height: 15px; border-radius: 50%; margin-right: 10px; }
        .active { background-color: #2ecc71; }
        .inactive { background-color: #e74c3c; }
        .button-group { display: flex; gap: 10px; margin-bottom: 20px; }
        button { padding: 10px 15px; border: none; border-radius: 4px; cursor: pointer; font-weight: bold; transition: all 0.2s; flex: 1; }
        button:hover { opacity: 0.9; transform: translateY(-1px); }
        #restartBtn { background-color: #3498db; color: white; }
        #enableBtn { background-color: #2ecc71; color: white; }
        #disableBtn { background-color: #e74c3c; color: white; }
        .logs-container { background-color: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 8px; font-family: monospace; white-space: pre-wrap; overflow-x: auto; max-height: 400px; overflow-y: auto; }
        .last-updated { text-align: right; font-size: 0.8em; color: #7f8c8d; margin-top: 5px; }
        .alert { padding: 10px; border-radius: 4px; margin-bottom: 15px; display: none; }
        .alert-success { background-color: #d4edda; color: #155724; }
        .alert-error { background-color: #f8d7da; color: #721c24; }
    </style>
</head>
<body>
    <h1>Backhaul Tunnel Manager</h1>
    <div id="alertBox" class="alert"></div>
    <div class="status-container">
        <h2>Service Status</h2>
        <p><span id="statusIndicator" class="status-indicator"></span><span id="statusText">Checking...</span></p>
        <div class="button-group">
            <button id="restartBtn">Restart Tunnel</button>
            <button id="enableBtn">Enable Service</button>
            <button id="disableBtn">Disable Service</button>
        </div>
    </div>
    <div class="status-container">
        <h2>Recent Logs</h2>
        <div id="logs" class="logs-container">Loading logs...</div>
        <div class="last-updated">Last updated: <span id="lastUpdated">-</span></div>
    </div>
    <script>
        const statusIndicator = document.getElementById('statusIndicator');
        const statusText = document.getElementById('statusText');
        const restartBtn = document.getElementById('restartBtn');
        const enableBtn = document.getElementById('enableBtn');
        const disableBtn = document.getElementById('disableBtn');
        const logsElement = document.getElementById('logs');
        const lastUpdatedElement = document.getElementById('lastUpdated');
        const alertBox = document.getElementById('alertBox');
        async function updateStatus() {
            try {
                const response = await fetch('backhaul_manager.php', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'action=status'
                });
                const data = await response.json();
                statusIndicator.className = 'status-indicator ' + data.status;
                statusText.textContent = data.status.charAt(0).toUpperCase() + data.status.slice(1);
                if (data.status === 'active') {
                    disableBtn.disabled = false;
                    enableBtn.disabled = true;
                } else {
                    disableBtn.disabled = true;
                    enableBtn.disabled = false;
                }
            } catch (error) {
                console.error('Error checking status:', error);
                statusText.textContent = 'Error checking status';
            }
        }
        async function updateLogs() {
            try {
                const response = await fetch('backhaul_manager.php', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'action=logs'
                });
                const data = await response.json();
                if (data.success) {
                    logsElement.textContent = data.logs;
                    lastUpdatedElement.textContent = new Date().toLocaleString();
                } else {
                    logsElement.textContent = 'Error fetching logs: ' + data.logs;
                }
            } catch (error) {
                console.error('Error fetching logs:', error);
                logsElement.textContent = 'Error fetching logs';
            }
        }
        async function sendCommand(action) {
            try {
                const response = await fetch('backhaul_manager.php', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'action=' + action
                });
                const data = await response.json();
                if (data.success) {
                    showAlert('Operation successful: ' + action, 'success');
                    updateStatus();
                    updateLogs();
                } else {
                    showAlert('Error: ' + (data.output || 'Unknown error'), 'error');
                }
            } catch (error) {
                console.error('Error sending command:', error);
                showAlert('Error sending command: ' + error.message, 'error');
            }
        }
        function showAlert(message, type) {
            alertBox.textContent = message;
            alertBox.className = 'alert alert-' + type;
            alertBox.style.display = 'block';
            setTimeout(() => { alertBox.style.display = 'none'; }, 5000);
        }
        restartBtn.addEventListener('click', () => {
            if (confirm('Are you sure you want to restart the backhaul tunnel?')) {
                sendCommand('restart');
            }
        });
        enableBtn.addEventListener('click', () => {
            if (confirm('Are you sure you want to enable the backhaul service?')) {
                sendCommand('enable');
            }
        });
        disableBtn.addEventListener('click', () => {
            if (confirm('Are you sure you want to disable the backhaul service?')) {
                sendCommand('disable');
            }
        });
        updateStatus();
        updateLogs();
        setInterval(() => {
            updateStatus();
            updateLogs();
        }, 10000);
    </script>
</body>
</html>
EOL

# Set permissions
echo -e "\n\033[1;34mSetting file permissions...\033[0m"
chown ${WEB_USER}:${WEB_USER} "${WEB_ROOT}/${SCRIPT_NAME}"
chmod 644 "${WEB_ROOT}/${SCRIPT_NAME}"

# Add web user to required groups
echo -e "\n\033[1;34mConfiguring user groups...\033[0m"
usermod -aG adm,systemd-journal ${WEB_USER} >/dev/null 2>&1

# Create sudoers file
echo -e "\n\033[1;34mConfiguring sudo permissions...\033[0m"
cat > ${SUDOERS_FILE} << EOL
# Allow web user to manage backhaul service
${WEB_USER} ALL=(root) NOPASSWD: /bin/systemctl restart ${SERVICE_NAME}
${WEB_USER} ALL=(root) NOPASSWD: /bin/systemctl enable ${SERVICE_NAME}
${WEB_USER} ALL=(root) NOPASSWD: /bin/systemctl disable ${SERVICE_NAME}
${WEB_USER} ALL=(root) NOPASSWD: /bin/journalctl -u ${SERVICE_NAME} -n 20 --no-pager
EOL

# Set proper permissions for sudoers file
chmod 440 ${SUDOERS_FILE}

# Create PHP test file
echo -e "\n\033[1;34mCreating PHP test file...\033[0m"
echo "<?php phpinfo(); ?>" > "${PHP_TEST_FILE}"
chown ${WEB_USER}:${WEB_USER} "${PHP_TEST_FILE}"

# Restart web server
echo -e "\n\033[1;34mRestarting web server...\033[0m"
systemctl restart ${WEB_SERVER} || { 
  echo -e "\033[1;31mWeb server restart failed\033[0m"
  journalctl -u ${WEB_SERVER} --no-pager | tail -n 20
  exit 1
}

# Verify installation
echo -e "\n\033[1;34mVerifying installation...\033[0m"
if ! curl -s http://localhost/phpinfo.php | grep -q "PHP Version"; then
  echo -e "\033[1;31mPHP test failed. Checking logs...\033[0m"
  journalctl -u ${WEB_SERVER} --no-pager | tail -n 20
  exit 1
fi

echo -e "\n\033[1;32m==============================================\033[0m"
echo -e "\033[1;32m Backhaul Tunnel Manager installed successfully\033[0m"
echo -e "\033[1;32m==============================================\033[0m"
echo -e "\n\033[1;36mWeb server type:\033[0m ${WEB_SERVER}"
echo -e "\033[1;36mAccess the interface at:\033[0m"
echo -e "http://$(hostname -I | awk '{print $1}')/${SCRIPT_NAME}"
echo -e "\n\033[1;36mTest PHP installation at:\033[0m"
echo -e "http://$(hostname -I | awk '{print $1}')/phpinfo.php"
echo -e "\n\033[1;33mNote: You may need to wait a few moments for the"
echo -e "group changes to take effect.\033[0m"