#!/bin/bash

# Function to display usage information
usage() {
  echo "Usage: $0 -j <json_key> -r <registry> -v <relay_version> -b <tag> -d <env_dns> -t <token> -e <env_name> -h <elastic_search_host> -u <elastic_search_username> -p <elastic_search_password> -R <region>"
  exit 1
}

# Parse command-line arguments using getopts
while getopts "j:r:v:b:d:t:e:h:u:p:R:" opt; do
  case $opt in
    j) JSON_KEY="$OPTARG" ;;
    r) REGISTRY="$OPTARG" ;;
    v) RELAY_VERSION="$OPTARG" ;;
    b) TAG="$OPTARG" ;;
    d) ENV_DNS="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    e) ENV_NAME="$OPTARG" ;;
    h) ELASTIC_SEARCH_HOST="$OPTARG" ;;
    u) ELASTIC_SEARCH_USERNAME="$OPTARG" ;;
    p) ELASTIC_SEARCH_PASSWORD="$OPTARG" ;;
    R) REGION="$OPTARG" ;;  # Use uppercase R for region
    *) usage ;;
  esac
done

# Check if all required parameters are provided
if [ -z "$JSON_KEY" ] || [ -z "$REGISTRY" ] || [ -z "$RELAY_VERSION" ] || [ -z "$TAG" ] || [ -z "$ENV_DNS" ] || [ -z "$TOKEN" ] || [ -z "$ENV_NAME" ] || [ -z "$ELASTIC_SEARCH_HOST" ] || [ -z "$ELASTIC_SEARCH_USERNAME" ] || [ -z "$ELASTIC_SEARCH_PASSWORD" ] || [ -z "$REGION" ]; then
  usage
fi

# Update package lists
sudo apt-get update

# Install necessary packages
sudo apt-get install -y ca-certificates curl wget jq awscli

# Create directory for apt keyrings
sudo install -m 0755 -d /etc/apt/keyrings

# Download and set up Docker's GPG key
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists and install Docker components
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose

# Create Docker group and add the user 'azureuser'
sudo groupadd docker
sudo usermod -aG docker azureuser

# Change to home directory of 'azureuser'
cd /home/azureuser/

# Retrieve private IP and UDP static IP
private_ip=$(hostname -I | awk '{print $1}')
udp_static_ip=$(curl -H "Metadata:true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2021-02-01&format=text")

# Configure iptables for UDP traffic
sudo iptables -t nat -A POSTROUTING -d "$private_ip" -p udp -j RETURN
sudo iptables -t nat -A PREROUTING -p udp -d "$udp_static_ip" --dport 3479 -j DNAT --to-destination "$private_ip"

# Download the relay agent installation script
wget https://extreme-zt-agents.s3.us-east-2.amazonaws.com/relay-agent/release-v24.2.0/installation_script.sh -O installation_script.sh
sudo chmod +x installation_script.sh

# Retrieve public IP
IP=$(curl ifconfig.io)

# Docker login using JSON key (passed from the command-line argument)
echo "$JSON_KEY" | base64 -d | sudo docker login -u _json_key --password-stdin gcr.io

# Run the relay agent installation script
sudo bash installation_script.sh -r "$REGISTRY" -v "$RELAY_VERSION" -b "$TAG" -i "$IP" -d "$ENV_DNS" -t "$TOKEN" -c GCP

# Set environment variables
export BuildEnv="$ENV_NAME"
export ElasticSearchHost="$ELASTIC_SEARCH_HOST"
export ElasticSearchUsername="$ELASTIC_SEARCH_USERNAME"
export ElasticSearchPassword="$ELASTIC_SEARCH_PASSWORD"

# Create directory for Filebeat
mkdir -p /home/azureuser/filebeat
cat >/home/azureuser/filebeat/filebeat.yml <<EOL
filebeat.inputs:
  - type: container
    paths:
        - /var/lib/docker/containers/*/*.log
    exclude_files: ['\.gz$']
    processors:
        - add_docker_metadata: ~
        - add_fields:
            target: ''
            fields:
              azure_region: "$REGION"
              service.environment: "RELAY-AGENT"
              Instance_IP: "$IP-$REGION"
              Environment_name: "$BuildEnv"

output.elasticsearch:
    hosts: ["$ElasticSearchHost:443"]
    username: "$ElasticSearchUsername"
    password: "$ElasticSearchPassword"
EOL

# Run Filebeat container with Docker
sudo docker run -d --name=filebeat \
  --user="root" \
  --volume="/home/azureuser/filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro" \
  --volume="/var/run/docker.sock:/var/run/docker.sock" \
  --env ELASTICSEARCH_HOST="$ElasticSearchHost" \
  --env ELASTICSEARCH_PORT=443 \
  --env ELASTICSEARCH_USERNAME="$ElasticSearchUsername" \
  --env ELASTICSEARCH_PASSWORD="$ElasticSearchPassword" \
  docker.elastic.co/beats/filebeat:7.14.0 filebeat -e -strict.perms=false
