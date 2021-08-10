## NOTE: This script is not intended to be directly applied since it expects certain values to be manually set
## This script is just provided as an example for how to provision a private registry that serves a Docker registry
## both using HTTPs (using self-signed certs) and HTTP

# Hostname that will host the private registry
export HOSTNAME="tf-do-rancher.superseb.example.com"

# Rancher Version
export RANCHER_SERVER_VERSION=v2.6.0-rc1

# Kubernetes Version
# Note: This is required to pull in all the necessary images from KDM to set up the private registry.
export DOWNSTREAM_RKE_VERSION=v1.17.0-rancher1-2
export KDM_BRANCH=release-${RANCHER_SERVER_VERSION%.*}

# Optional parameters
export REGISTRY_USER=testuser
export REGISTRY_PASS=testpass
export DOCKER_VERSION=20.10
export DOCKER_COMPOSE_VERSION=1.24.1

## Actual Script

# Install Docker
curl https://releases.rancher.com/install-docker/${DOCKER_VERSION}.sh | sh

# Set up nginx.conf for a private registry from Rancher's testing framework
mkdir -p basic-registry/nginx_config
wget -O basic-registry/docker-compose.yml https://raw.githubusercontent.com/rancher/rancher/${RANCHER_SERVER_VERSION}/tests/validation/tests/v3_api/resource/airgap/basic-registry/docker-compose.yml
wget -O basic-registry/nginx_config/nginx.conf https://raw.githubusercontent.com/rancher/rancher/${RANCHER_SERVER_VERSION}/tests/validation/tests/v3_api/resource/airgap/basic-registry/nginx_config/nginx.conf

# Allow traffic to come in from HTTP or HTTPs
echo "" >> basic-registry/nginx_config/nginx.conf
cat <<EOF >> basic-registry/nginx_config/nginx.conf
server {
    listen 80 default_server;
    server_name _;
    
    # required to avoid HTTP 411: see Issue #1486 (https://github.com/docker/docker/issues/1486)
    chunked_transfer_encoding on;

    location /v2/ {
        # Do not allow connections from docker 1.5 and earlier
        # docker pre-1.6.0 did not properly set the user agent on ping, catch "Go *" user agents
        if (\$http_user_agent ~ "^(docker\/1\.(3|4|5(?!\.[0-9]-dev))|Go ).*\$" ) {
        return 404;
        }

        # To add basic authentication to v2 use auth_basic setting plus add_header
        auth_basic "registry.localhost";
        auth_basic_user_file /etc/nginx/conf.d/registry.password;
        add_header 'Docker-Distribution-Api-Version' 'registry/2.0' always;

        proxy_pass                          http://docker-registry;
        proxy_set_header  Host              \$http_host;   # required for docker client's sake
        proxy_set_header  X-Real-IP         \$remote_addr; # pass on real client's IP
        proxy_set_header  X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto \$scheme;
        proxy_read_timeout                  900;
    }

}
EOF
sed -i 's/- 443:443/- 443:443\n    - 80:80/' basic-registry/docker-compose.yml

# Add self-signed certificates
docker run -v $PWD/certs:/certs -e CA_SUBJECT="My own root CA" -e CA_EXPIRE="1825" -e SSL_EXPIRE="365" -e SSL_SUBJECT="${HOSTNAME}" -e SSL_DNS="${HOSTNAME}" -e SILENT="true" superseb/omgwtfssl
sudo cat certs/cert.pem certs/ca.pem > basic-registry/nginx_config/domain.crt
sudo cat certs/key.pem > basic-registry/nginx_config/domain.key

# Create basic auth user/pass
docker run --rm melsayed/htpasswd ${REGISTRY_USER} ${REGISTRY_PASS} >> basic-registry/nginx_config/registry.password

# Restart docker with self-signed certificates so that it can access the insecure registry
sudo mkdir -p /etc/docker/certs.d/${HOSTNAME}
sudo cp ~/certs/ca.pem /etc/docker/certs.d/${HOSTNAME}/ca.crt
sudo service docker restart

# Run docker-compose to start up the nginx server that will be serving your private registry
pushd basic-registry
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo docker-compose up -d
popd

# Pull in rancher scripts to handle mirroring images
wget -O rancher-images.txt https://github.com/rancher/rancher/releases/download/${RANCHER_SERVER_VERSION}/rancher-images.txt
wget -O rancher-save-images.sh https://github.com/rancher/rancher/releases/download/${RANCHER_SERVER_VERSION}/rancher-save-images.sh
wget -O rancher-load-images.sh https://github.com/rancher/rancher/releases/download/${RANCHER_SERVER_VERSION}/rancher-load-images.sh

# Modify scripts
sudo sed -i '58d' rancher-save-images.sh
sudo sed -i '76d' rancher-load-images.sh
chmod +x rancher-save-images.sh && chmod +x rancher-load-images.sh

# Add kdm images
jq_command=.K8sVersionRKESystemImages.\"${DOWNSTREAM_RKE_VERSION}\"[]
curl https://raw.githubusercontent.com/rancher/kontainer-driver-metadata/${KDM_BRANCH}/data/data.json \
    | docker run -i stedolan/jq -r "${jq_command}" > kdm-images.txt

# Pull in docker images from DockerHub based on images.txt
# docker pull <image>
./rancher-save-images.sh --image-list ./rancher-images.txt
./rancher-save-images.sh --image-list ./kdm-images.txt

# Login to the private registry
docker login ${HOSTNAME} -u ${REGISTRY_USER} -p ${REGISTRY_PASS}

# Mirror pulled in images to your private registry
# docker tag rancher/IMAGE ${HOSTNAME}/IMAGE
# docker push ${HOSTNAME}/IMAGE
./rancher-load-images.sh --image-list ./rancher-images.txt --registry ${HOSTNAME}
./rancher-load-images.sh --image-list ./kdm-images.txt --registry ${HOSTNAME}
