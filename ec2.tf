data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "k3s_node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s_node_sg.id]
  key_name               = var.key_name
  #iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
set -e
echo "--- Iniciando User Data Script ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "Esperando a que se liberen los bloqueos de apt/dpkg..."
    sleep 5
done
apt-get upgrade -y
apt-get install -y curl wget git unzip jq apt-transport-https ca-certificates gnupg lsb-release mariadb-server nfs-common

apt-get install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
rm -rf awscliv2.zip aws

# --- Instalación de Rust y amazon-efs-utils ---
echo "Instalando dependencias para amazon-efs-utils y Rust..."
apt-get install -y git binutils build-essential pkg-config libssl-dev
echo "Instalando Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
source /root/.cargo/env
echo "Rust instalado."
echo "Instalando amazon-efs-utils desde GitHub..."
mkdir -p /opt/installers && cd /opt/installers && rm -rf ./efs-utils
git clone https://github.com/aws/efs-utils.git ./efs-utils && cd ./efs-utils
echo "Compilando amazon-efs-utils..."
PATH="/root/.cargo/bin:$PATH" ./build-deb.sh
echo "Instalando paquete .deb de amazon-efs-utils..."
apt-get -y install ./build/amazon-efs-utils*deb
cd / && rm -rf /opt/installers/efs-utils
echo "amazon-efs-utils instalado."
# --- Fin Instalación de Rust y amazon-efs-utils ---

# Instalar K3s
echo "Instalando K3s..."
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--disable=traefik" \
  sh -s -

# Configurar kubectl para root
echo "Configurando kubectl para root..."
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config

echo "Esperando al Kubernetes API…"
until kubectl get nodes &>/dev/null; do
  sleep 3
  echo "  aun no responde, esperando…"
done
echo "API server UP."

echo "Instalando Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
export PATH=$PATH:/usr/local/bin

echo "Añadiendo repo ingress-nginx…"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

echo "Desplegando ingress-nginx con Helm…"
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.hostPorts.http=true \
  --set controller.hostPorts.https=true \
  --set controller.service.type=NodePort \
  --set controller.ingressClassResource.default=true \
  --kubeconfig /root/.kube/config

echo "Esperando a que ingress-nginx-controller este listo…"
kubectl -n ingress-nginx wait \
  --for=condition=Available=True deployment ingress-nginx-controller \
  --timeout=120s


BASHRC_FILE="/root/.bashrc"
KUBECONFIG_LINE="export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
grep -qF -- "$KUBECONFIG_LINE" "$BASHRC_FILE" || echo "$KUBECONFIG_LINE" >> "$BASHRC_FILE"

# Instalar cert-manager
CERT_MANAGER_VERSION="v1.14.5"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$${CERT_MANAGER_VERSION}/cert-manager.yaml
kubectl wait --for=condition=Available=True deployment --all -n cert-manager --timeout=300s


# Crear ClusterIssuer
echo "Creando ClusterIssuer..."
cat <<EOT_ISSUER | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${var.admin_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress: {}
EOT_ISSUER

echo "Instalando Python3 y pip (si no existen) y botocore..."
apt-get install -y python3 python3-pip
pip3 install botocore
echo "botocore instalado."

# --- Montaje de EFS y Preparación de Archivos de la Aplicación ---
# El ID del EFS ahora viene de Terraform
EFS_FILE_SYSTEM_ID="${aws_efs_file_system.panel_web_efs.id}"
EFS_MOUNT_POINT="/mnt/efs-panel-web"
PANEL_FILES_HOST_PATH="$${EFS_MOUNT_POINT}/app-files" # Ruta en el nodo para el hostPath del PV

echo "Asegurando punto de montaje EFS $${EFS_MOUNT_POINT}..."
mkdir -p "$${EFS_MOUNT_POINT}"

echo "Montando EFS $${EFS_FILE_SYSTEM_ID} en $${EFS_MOUNT_POINT}..."
if ! mountpoint -q "$${EFS_MOUNT_POINT}"; then
    # Quitado -o tls porque el ayudante mount.efs lo usa por defecto si está disponible
    # y si falla, el problema suele ser de red/DNS, no de la opción tls en sí.
    mount -t efs "$${EFS_FILE_SYSTEM_ID}:/" "$${EFS_MOUNT_POINT}"
    if [ $? -ne 0 ]; then
        echo "ERROR CRÍTICO: Fallo al montar EFS $${EFS_FILE_SYSTEM_ID} en $${EFS_MOUNT_POINT}."
        echo "Verifica la configuración de DNS de la VPC, los Mount Targets de EFS y los Security Groups."
        exit 1
    else
        echo "EFS montado exitosamente en $${EFS_MOUNT_POINT}."
    fi
else
    echo "EFS ya parece estar montado en $${EFS_MOUNT_POINT}."
fi

echo "Creando directorio para archivos de la aplicación en $${PANEL_FILES_HOST_PATH}..."
mkdir -p "$${PANEL_FILES_HOST_PATH}"

GIT_REPO_OWNER_AND_NAME="dramlin1010/k8servers_web"
GIT_HOST="github.com"

# Usar las variables de Terraform interpoladas
GIT_TOKEN_TF="${var.git_pat}"
GIT_USERNAME_TF="${var.git_clone_username}"

GIT_REPO_URL_WITH_TOKEN="https://$${GIT_USERNAME_TF}:$${GIT_TOKEN_TF}@$${GIT_HOST}/$${GIT_REPO_OWNER_AND_NAME}.git"

echo "Clonando/actualizando archivos de la aplicación en $${PANEL_FILES_HOST_PATH} usando token de TF vars..."
if [ -d "$${PANEL_FILES_HOST_PATH}/.git" ]; then
    echo "Actualizando repositorio existente..."
    cd "$${PANEL_FILES_HOST_PATH}"
    git remote set-url origin "$${GIT_REPO_URL_WITH_TOKEN}"
    git pull
    cd /
else
    echo "Clonando repositorio..."
    rm -rf "$${PANEL_FILES_HOST_PATH:?}"/* "$${PANEL_FILES_HOST_PATH:?}"/.[!.]* "$${PANEL_FILES_HOST_PATH:?}"/..?*
    git clone "$${GIT_REPO_URL_WITH_TOKEN}" "$${PANEL_FILES_HOST_PATH}"
fi
echo "Archivos de la aplicación listos."


echo "Estableciendo permisos en $${PANEL_FILES_HOST_PATH} para UID/GID 101..."
chown -R 101:101 "$${PANEL_FILES_HOST_PATH}"
find "$${PANEL_FILES_HOST_PATH}" -type d -exec chmod 755 {} \;
find "$${PANEL_FILES_HOST_PATH}" -type f -exec chmod 644 {} \;
echo "Permisos establecidos."
# --- Fin Montaje EFS y Preparación de Archivos ---

# --- INICIO: Despliegue Panel Web Principal (con EFS montado manualmente) ---
echo "Desplegando Panel Web Principal..."
PANEL_FILES_HOST_PATH="/mnt/efs-panel-web/app-files"
mkdir -p $${PANEL_FILES_HOST_PATH}

echo "Clonando archivos de la aplicación (ejemplo)..."
if [ -d "$${PANEL_FILES_HOST_PATH}/.git" ]; then
    echo "Actualizando repositorio existente en $${PANEL_FILES_HOST_PATH}..."
    cd "$${PANEL_FILES_HOST_PATH}" && git pull && cd /
elif [ "$(ls -A $${PANEL_FILES_HOST_PATH})" ]; then # Si hay archivos pero no es git, limpiar
    echo "Limpiando directorio $${PANEL_FILES_HOST_PATH} antes de clonar..."
    rm -rf "$${PANEL_FILES_HOST_PATH:?}"/* "$${PANEL_FILES_HOST_PATH:?}"/.[!.]* "$${PANEL_FILES_HOST_PATH:?}"/..?*
    git clone $${GIT_REPO_URL} "$${PANEL_FILES_HOST_PATH}"
else # Si está vacío, clonar
    git clone $${GIT_REPO_URL} "$${PANEL_FILES_HOST_PATH}"
fi
echo "Archivos de la aplicación clonados/actualizados en $${PANEL_FILES_HOST_PATH}."
# --- FIN COPIA/CLONACIÓN DE ARCHIVOS ---

echo "Estableciendo permisos en $${PANEL_FILES_HOST_PATH} para el usuario/grupo 101 (nginx en Alpine)..."
chown -R 101:101 "$${PANEL_FILES_HOST_PATH}"
find "$${PANEL_FILES_HOST_PATH}" -type d -exec chmod 755 {} \;
find "$${PANEL_FILES_HOST_PATH}" -type f -exec chmod 644 {} \;
echo "Permisos establecidos."
# --- Fin Montaje EFS y Preparación de Archivos ---

PANEL_PV_NAME="panel-web-efs-pv"
PANEL_PVC_NAME="panel-web-efs-pvc"
PANEL_DEPLOYMENT_NAME="panel-web-dep"
PANEL_SERVICE_NAME="panel-web-svc"
PANEL_INGRESS_NAME="panel-web-ing"
PANEL_DOMAIN_NAME="${var.base_domain}"
PANEL_TLS_SECRET_NAME="panel-web-tls"
WEB_DOC_ROOT_IN_POD="/var/www/html/"

PHP_FPM_DEPLOYMENT_NAME="php-fpm-dep"
PHP_FPM_SERVICE_NAME="php-fpm-svc"
PHP_FPM_IMAGE_NAME="280972575853.dkr.ecr.us-east-1.amazonaws.com/web/k8servers:v1"

NGINX_DEPLOYMENT_NAME="nginx-dep"
NGINX_SERVICE_NAME="nginx-svc"
NGINX_CONFIGMAP_NAME="nginx-vhost-conf-cm"
NGINX_IMAGE_NAME="nginx:alpine" # Imagen estándar de Nginx

# Configuración de AWS CLI para root (usando /root/.aws)
echo "Configurando credenciales AWS CLI para root..."
mkdir -p ~/.aws
cat <<-EOT_CREDS > ~/.aws/credentials
[default]
aws_access_key_id=${var.aws_access_key_id}
aws_secret_access_key=${var.aws_secret_access_key}
aws_session_token=${var.aws_session_token}
EOT_CREDS

cat <<-CREDENTIALS > ~/.aws/config
[default]
region = ${var.aws_region}
CREDENTIALS

# Crear Secret de ECR usando las credenciales de AWS (para root)
echo "Creando el secret aws-ecr-creds..."
kubectl create secret docker-registry aws-ecr-creds \
  --docker-server="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)" \
  --docker-email="dramlin1010@g.educaand.es"

# Aplicar manifiestos de Kubernetes para el Panel Web
echo "Aplicando manifiestos Kubernetes para el Panel Web..."
cat <<-EOT_PANEL | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $${PANEL_PV_NAME}
  labels:
    type: local-efs-panel
spec:
  storageClassName: ""
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: "$${PANEL_FILES_HOST_PATH}"
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $${PANEL_PVC_NAME}
  labels:
    app: panel-web
spec:
  storageClassName: ""
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  selector:
    matchLabels:
      type: local-efs-panel
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $${PHP_FPM_DEPLOYMENT_NAME}
  labels:
    app: php-fpm-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-fpm-app
  template:
    metadata:
      labels:
        app: php-fpm-app
    spec:
      securityContext:
        fsGroup: 101
      imagePullSecrets:
        - name: aws-ecr-creds
      containers:
        - name: php-fpm-container
          image: $${PHP_FPM_IMAGE_NAME}
          imagePullPolicy: Always
          ports:
            - name: fpm-port
              containerPort: 9000
          volumeMounts:
            - name: app-code-efs
              mountPath: "/var/www/html"
      volumes:
        - name: app-code-efs
          persistentVolumeClaim:
            claimName: $${PANEL_PVC_NAME}
---
apiVersion: v1
kind: Service
metadata:
  name: $${PHP_FPM_SERVICE_NAME}
  labels:
    app: php-fpm-app
spec:
  selector:
    app: php-fpm-app
  ports:
    - name: fpm
      protocol: TCP
      port: 9000
      targetPort: fpm-port
  type: ClusterIP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $${NGINX_CONFIGMAP_NAME}
data:
  default.conf: |
    server {
        listen 80 default_server;
        server_name _;
        root /var/www/html/;
        index index.php index.html;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location ~ \.php\$ {
            try_files \$uri =404;
            fastcgi_split_path_info ^(.+\.php)(/.+)\$;
            fastcgi_pass $${PHP_FPM_SERVICE_NAME}.default.svc.cluster.local:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
            include fastcgi_params;
        }

        location ~ /\.ht {
            deny all;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $${NGINX_DEPLOYMENT_NAME}
  labels:
    app: nginx-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-app
  template:
    metadata:
      labels:
        app: nginx-app
    spec:
      securityContext:
        fsGroup: 101
      containers:
        - name: nginx-container
          image: $${NGINX_IMAGE_NAME}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80
          volumeMounts:
            - name: nginx-vhost-volume
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
            - name: app-code-efs
              mountPath: "/var/www/html"
      volumes:
        - name: nginx-vhost-volume
          configMap:
            name: $${NGINX_CONFIGMAP_NAME}
        - name: app-code-efs
          persistentVolumeClaim:
            claimName: $${PANEL_PVC_NAME}
---
apiVersion: v1
kind: Service
metadata:
  name: $${NGINX_SERVICE_NAME}
  labels:
    app: nginx-app
spec:
  selector:
    app: nginx-app
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $${PANEL_INGRESS_NAME}
  labels:
    app: panel-web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${var.base_domain}
      secretName: $${PANEL_TLS_SECRET_NAME}
  rules:
    - host: ${var.base_domain}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $${NGINX_SERVICE_NAME}
                port:
                  number: 80
EOT_PANEL
echo "Manifiestos del Panel Web aplicados."
# --- FIN: Despliegue Panel Web Principal ---

# Configurar SSHD para SFTP chroot (EFS para clientes)
echo "Configurando SSHD para SFTP (con EFS montado manualmente)..."
SFTP_EFS_BASE_PATH="/mnt/efs-clientes"
mkdir -p $${SFTP_EFS_BASE_PATH}
groupadd sftpusers || echo "Grupo sftpusers ya existe"
grep -q "Match Group sftpusers" /etc/ssh/sshd_config || echo '
Match Group sftpusers
    ChrootDirectory $${SFTP_EFS_BASE_PATH}/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication no
' >> /etc/ssh/sshd_config
sed -i 's/^Subsystem\s*sftp\s*.*/Subsystem sftp internal-sftp/' /etc/ssh/sshd_config
grep -q "Subsystem sftp internal-sftp" /etc/ssh/sshd_config || echo 'Subsystem sftp internal-sftp' >> /etc/ssh/sshd_config
systemctl reload sshd

# Configurar MariaDB
echo "Configurando MariaDB..."
systemctl start mariadb
systemctl enable mariadb
sleep 10

DB_NAME="k8servers"
DB_USER="daniel"
DB_PASSWORD="Kt3xa6RqSAgdpskCZyuWfX"

echo "Creando Base de Datos $${DB_NAME} y Usuario $${DB_USER}..."
mysql -e "CREATE DATABASE IF NOT EXISTS \`$${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '$${DB_USER}'@'localhost' IDENTIFIED BY '$${DB_PASSWORD}';"
mysql -e "GRANT ALL PRIVILEGES ON \`$${DB_NAME}\`.* TO '$${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"
echo "Base de Datos y Usuario creados."

# Instalar AWS CLI
echo "Instalando AWS CLI..."
apt-get install -y awscli

echo "--- User Data Script Finalizado ---"
  EOF

  tags = { Name = "${var.project_name}-k3s-node" }
}

resource "aws_eip" "k3s_node_eip" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-k3s-node-eip" }
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.k3s_node.id
  allocation_id = aws_eip.k3s_node_eip.id
}