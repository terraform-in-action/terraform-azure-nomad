#!/usr/bin/env bash
set -e

function lookupPathInMetadata {
  local readonly path="$1"
  local readonly AZURE_INSTANCE_METADATA_URL="http://169.254.169.254/metadata/instance?api-version=2019-06-04"
  curl --silent --show-error --header Metadata:true --location "$AZURE_INSTANCE_METADATA_URL" | jq -r "$path"
}

function installDependencies() {
  echo "Installing dependencies..."
  sudo apt-get -qq update &>/dev/null
  sudo apt-get -yqq install unzip jq &>/dev/null
}

function installDocker() {
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
}

function installConsul() {
  echo "Fetching Consul..."
  cd /tmp
  curl -sLo consul.zip https://releases.hashicorp.com/consul/${consul_version}/consul_${consul_version}_linux_amd64.zip
  
  echo "Installing Consul..."
  unzip consul.zip >/dev/null
  sudo chmod +x consul
  sudo mv consul /usr/local/bin/consul
  
  # Setup Consul
  sudo mkdir -p /mnt/consul
  sudo mkdir -p /etc/consul.d
  sudo tee /etc/consul.d/config.json > /dev/null <<EOF
  ${consul_config}
EOF
  
  sudo tee /etc/systemd/system/consul.service > /dev/null <<"EOF"
[Unit]
Description=Consul Agent
Requires=network-online.target
After=network-online.target

[Service]
Restart=on-failure
Environment=CONSUL_ALLOW_PRIVILEGED_PORTS=true
ExecStart=/usr/local/bin/consul agent -config-dir="/etc/consul.d" -dns-port="53" -recursor="172.31.0.2"
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
}

function installNomad() {
  echo "Fetching Nomad..."
  cd /tmp
  curl -sLo nomad.zip https://releases.hashicorp.com/nomad/${nomad_version}/nomad_${nomad_version}_linux_amd64.zip
  
  echo "Installing Nomad..."
  unzip nomad.zip >/dev/null
  sudo chmod +x nomad
  sudo mv nomad /usr/local/bin/nomad
  
  # Setup Nomad
  sudo mkdir -p /mnt/nomad
  sudo mkdir -p /etc/nomad.d
  sudo tee /etc/nomad.d/config.hcl > /dev/null <<EOF
  ${nomad_config}
EOF
  
  sudo tee /etc/systemd/system/nomad.service > /dev/null <<"EOF"
[Unit]
Description=Nomad
Documentation=https://nomadproject.io/docs/
Wants=network-online.target
After=network-online.target
Wants=consul.service
After=consul.service

[Service]
ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/local/bin/nomad agent -config /etc/nomad.d
KillMode=process
KillSignal=SIGINT
LimitNOFILE=infinity
LimitNPROC=infinity
Restart=on-failure
RestartSec=2
StartLimitBurst=3
StartLimitIntervalSec=10
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

  sudo mkdir -p /etc/fabio
  sudo tee /etc/fabio/fabio.properties > /dev/null <<EOF
proxy.addr=:27017;proto=tcp
EOF
}


# Install software
installDependencies

# this populates the config file
PRIVATE_IP=$(lookupPathInMetadata ".network.interface[0].ipv4.ipAddress[0].privateIpAddress")

# Consul Server also needs public IP
if [[  ${consul_mode} == "server" ]]; then
  PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
fi

if [[  ${consul_mode} != "disabled" ]]; then
  installConsul ${consul_version}
fi

if [[  ${nomad_mode} != "disabled" ]]; then
  installNomad ${nomad_version}
fi

if [[  ${nomad_mode} == "client" ]]; then
  installDocker
fi

echo "Starting services..."

# Start services
sudo systemctl daemon-reload
  
# Start Consul
if [[  ${consul_mode} != "disabled" ]]; then
  sudo systemctl enable consul.service
  sudo systemctl start consul.service
fi

# Start Nomad
if [[  ${nomad_mode} != "disabled" ]]; then
  sudo systemctl enable nomad.service
  sudo systemctl start nomad.service
fi
