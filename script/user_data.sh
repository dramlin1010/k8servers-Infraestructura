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

NODE_PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
if [ -z "$NODE_PRIVATE_IP" ]; then
    echo "ERROR CRÍTICO: No se pudo obtener la IP privada del nodo desde los metadatos."
    exit 1
fi
echo "IP Privada del Nodo: $NODE_PRIVATE_IP"

apt-get install -y curl wget git unzip jq apt-transport-https ca-certificates gnupg lsb-release mariadb-server nfs-common php-cli php-mysql

# Hacer accesible mariadb desde cualquier IP

MARIADB_CONFIG_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"

if [ -f "$MARIADB_CONFIG_FILE" ]; then
    echo "Configurando MariaDB para escuchar en todas las interfaces (0.0.0.0)..."
    sed -i -E 's/^\s*bind-address\s*=\s*127\.0\.0\.1/#bind-address = 127.0.0.1/' "$MARIADB_CONFIG_FILE"
    if ! grep -q "^\s*bind-address\s*=\s*0\.0\.0\.0" "$MARIADB_CONFIG_FILE"; then
        if grep -q "\[mysqld\]" "$MARIADB_CONFIG_FILE"; then
            sed -i '/\[mysqld\]/a bind-address = 0.0.0.0' "$MARIADB_CONFIG_FILE"
        elif grep -q "\[mariadb\]" "$MARIADB_CONFIG_FILE"; then
            sed -i '/\[mariadb\]/a bind-address = 0.0.0.0' "$MARIADB_CONFIG_FILE"
        else
            echo "ADVERTENCIA: No se encontró la sección [mysqld] o [mariadb] para añadir bind-address = 0.0.0.0. MariaDB podría no escuchar externamente."
        fi
    fi
    echo "bind-address configurado."
else
    echo "ADVERTENCIA: No se encontró el fichero de configuración de MariaDB en $MARIADB_CONFIG_FILE. El bind-address podría no estar configurado para acceso externo."
fi

systemctl restart mariadb

apt-get install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
rm -rf awscliv2.zip aws

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

echo "Instalando K3s..."
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--disable=traefik" \
  sh -s -

echo "Configurando kubectl para root..."
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config
export KUBECONFIG=/root/.kube/config

echo "Esperando al Kubernetes API…"
until kubectl get nodes &>/dev/null; do
  sleep 3
  echo "  aun no responde, esperando…"
done
echo "API server UP."

echo "Instalando Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

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
  --set controller.progressDeadlineSeconds=600 \
  --kubeconfig /root/.kube/config

echo "Esperando a que ingress-nginx-controller este listo…"
kubectl -n ingress-nginx wait \
  --for=condition=Available=True deployment ingress-nginx-controller \
  --timeout=180s

BASHRC_FILE="/root/.bashrc"
KUBECONFIG_LINE_BASHRC="export KUBECONFIG=/root/.kube/config"
grep -qF -- "$KUBECONFIG_LINE_BASHRC" "$BASHRC_FILE" || echo "$KUBECONFIG_LINE_BASHRC" >> "$BASHRC_FILE"

CERT_MANAGER_VERSION="v1.14.5"
echo "Instalando cert-manager $CERT_MANAGER_VERSION..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml
echo "Esperando a que cert-manager este completamente disponible..."
kubectl wait --for=condition=Available=True deployment --all -n cert-manager --timeout=300s


# DEJAR ESTO PARA EL FINAL QUE SI NO LET'S ENCRYPT NO ME DEJA ASIGNAR EL CERTIFICADO
# echo "Creando ClusterIssuer letsencrypt-prod..."
# cat <<EOT_ISSUER | kubectl apply -f -
# apiVersion: cert-manager.io/v1
# kind: ClusterIssuer
# metadata:
#   name: letsencrypt-prod
# spec:
#   acme:
#     server: https://acme-v02.api.letsencrypt.org/directory
#     email: ${TF_VAR_admin_email} # O la variable que uses
#     privateKeySecretRef:
#       name: letsencrypt-prod-account-key
#     solvers:
#     - http01:
#         ingress: {}
# EOT_ISSUER
# echo "ClusterIssuer letsencrypt-prod comentado/deshabilitado temporalmente."

echo "Creando ClusterIssuer letsencrypt-staging..."
cat <<EOT_STAGING_ISSUER | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${TF_VAR_admin_email}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOT_STAGING_ISSUER
echo "ClusterIssuer letsencrypt-staging creado."



echo "Instalando Python3 y pip (si no existen) y botocore..."
apt-get install -y python3 python3-pip
pip3 install botocore
echo "botocore instalado."

EFS_FILE_SYSTEM_ID="${TF_VAR_efs_fs_id}"
EFS_MOUNT_POINT="/mnt/efs-panel-web"
PANEL_FILES_HOST_PATH="${EFS_MOUNT_POINT}/app-files"

echo "Asegurando punto de montaje EFS ${EFS_MOUNT_POINT}..."
mkdir -p "${EFS_MOUNT_POINT}"

echo "Montando EFS ${EFS_FILE_SYSTEM_ID} en ${EFS_MOUNT_POINT}..."
if ! mountpoint -q "${EFS_MOUNT_POINT}"; then
    mount -t efs "${EFS_FILE_SYSTEM_ID}:/" "${EFS_MOUNT_POINT}"
    if [ $? -ne 0 ]; then
        echo "ERROR CRÍTICO: Fallo al montar EFS ${EFS_FILE_SYSTEM_ID} en ${EFS_MOUNT_POINT}."
        echo "Verifica la configuración de DNS de la VPC, los Mount Targets de EFS y los Security Groups."
        exit 1
    else
        echo "EFS montado exitosamente en ${EFS_MOUNT_POINT}."
    fi
else
    echo "EFS ya parece estar montado en ${EFS_MOUNT_POINT}."
fi

SFTP_EFS_BASE_PATH="/mnt/efs-clientes"
echo "Creando directorio base para SFTP y sitios de clientes en ${SFTP_EFS_BASE_PATH}..."
mkdir -p "${SFTP_EFS_BASE_PATH}"

groupadd sftpusers || echo "Grupo sftpusers ya existe."

chown root:101 "${SFTP_EFS_BASE_PATH}"
chmod 775 "${SFTP_EFS_BASE_PATH}"

echo "Permisos iniciales para ${SFTP_EFS_BASE_PATH} establecidos."

echo "Creando directorio para archivos de la aplicación en ${PANEL_FILES_HOST_PATH}..."
mkdir -p "${PANEL_FILES_HOST_PATH}"

GIT_REPO_OWNER_AND_NAME="dramlin1010/k8servers_web"
GIT_HOST="github.com"
GIT_TOKEN_TF="${TF_VAR_git_pat}"
GIT_USERNAME_TF="${TF_VAR_git_clone_username}"
GIT_REPO_URL_WITH_TOKEN="https://$GIT_USERNAME_TF:$GIT_TOKEN_TF@$GIT_HOST/$GIT_REPO_OWNER_AND_NAME.git"

echo "Clonando/actualizando archivos de la aplicación en ${PANEL_FILES_HOST_PATH} usando token de TF vars..."
if [ -d "${PANEL_FILES_HOST_PATH}/.git" ]; then
    echo "Actualizando repositorio existente..."
    cd "${PANEL_FILES_HOST_PATH}"
    git remote set-url origin "${GIT_REPO_URL_WITH_TOKEN}"
    git pull
    cd /
else
    echo "Clonando repositorio..."
    rm -rf "${PANEL_FILES_HOST_PATH:?}"/* "${PANEL_FILES_HOST_PATH:?}"/.[!.]* "${PANEL_FILES_HOST_PATH:?}"/..?*
    git clone "${GIT_REPO_URL_WITH_TOKEN}" "${PANEL_FILES_HOST_PATH}"
fi
echo "Archivos de la aplicación listos."

echo "Estableciendo permisos en ${PANEL_FILES_HOST_PATH} para UID/GID 101..."
chown -R 101:101 "${PANEL_FILES_HOST_PATH}"
find "${PANEL_FILES_HOST_PATH}" -type d -exec chmod 755 {} \;
find "${PANEL_FILES_HOST_PATH}" -type f -exec chmod 644 {} \;
echo "Permisos establecidos."

PANEL_PV_NAME="panel-web-efs-pv"
PANEL_PVC_NAME="panel-web-efs-pvc"
PHP_FPM_DEPLOYMENT_NAME="php-fpm-dep"
PHP_FPM_SERVICE_NAME="php-fpm-svc"
PHP_FPM_IMAGE_NAME="280972575853.dkr.ecr.us-east-1.amazonaws.com/web/k8servers:v1"
NGINX_DEPLOYMENT_NAME="nginx-dep"
NGINX_SERVICE_NAME="nginx-svc"
NGINX_CONFIGMAP_NAME="nginx-vhost-conf-cm"
NGINX_IMAGE_NAME="nginx:alpine"
PANEL_INGRESS_NAME="panel-web-ing"
PANEL_TLS_SECRET_NAME="panel-web-tls"

echo "Configurando credenciales AWS CLI para root..."
mkdir -p /root/.aws
cat <<-EOT_CREDS > /root/.aws/credentials
[default]
aws_access_key_id=${TF_VAR_aws_access_key_id}
aws_secret_access_key=${TF_VAR_aws_secret_access_key}
aws_session_token=${TF_VAR_aws_session_token}
EOT_CREDS
cat <<-CREDENTIALS_CONFIG > /root/.aws/config
[default]
region = ${TF_VAR_aws_region}
CREDENTIALS_CONFIG
chmod 600 /root/.aws/credentials /root/.aws/config
echo "Credenciales AWS CLI configuradas."

echo "Creando el secret aws-ecr-creds para ECR..."
kubectl create secret docker-registry aws-ecr-creds \
  --docker-server="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${TF_VAR_aws_region}.amazonaws.com" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region ${TF_VAR_aws_region})" \
  --docker-email="dramlin1010@g.educaand.es" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret aws-ecr-creds creado/actualizado."

echo "Aplicando manifiestos Kubernetes para el Panel Web..."
cat <<-EOT_K8S_RESOURCES | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PANEL_PV_NAME}
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
    path: "${PANEL_FILES_HOST_PATH}"
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PANEL_PVC_NAME}
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
  name: ${PHP_FPM_DEPLOYMENT_NAME}
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
          image: ${PHP_FPM_IMAGE_NAME}
          imagePullPolicy: Always
          ports:
            - name: fpm-port
              containerPort: 9000
          volumeMounts:
            - name: app-code-efs
              mountPath: "/var/www/html"
            - name: efs-client-data
              mountPath: "/mnt/efs-clientes"
      volumes:
        - name: app-code-efs
          persistentVolumeClaim:
            claimName: ${PANEL_PVC_NAME}
        - name: efs-client-data
          hostPath:
            path: "/mnt/efs-clientes"
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: ${PHP_FPM_SERVICE_NAME}
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
  name: ${NGINX_CONFIGMAP_NAME}
data:
  default.conf: |
    server {
        listen 80 default_server;
        server_name _;
        root /var/www/html;
        index index.php index.html;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location ~ \.php\$ {
            try_files \$uri =404;
            fastcgi_split_path_info ^(.+\.php)(/.+)\$;
            fastcgi_pass ${PHP_FPM_SERVICE_NAME}.default.svc.cluster.local:9000;
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
  name: ${NGINX_DEPLOYMENT_NAME}
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
          image: ${NGINX_IMAGE_NAME}
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
            - name: efs-client-data
              mountPath: "/mnt/efs-clientes"
      volumes:
        - name: nginx-vhost-volume
          configMap:
            name: ${NGINX_CONFIGMAP_NAME}
        - name: app-code-efs
          persistentVolumeClaim:
            claimName: ${PANEL_PVC_NAME}
        - name: efs-client-data
          hostPath:
            path: "/mnt/efs-clientes"
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: ${NGINX_SERVICE_NAME}
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
  name: ${PANEL_INGRESS_NAME}
  labels:
    app: panel-web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${TF_VAR_base_domain}
      secretName: ${PANEL_TLS_SECRET_NAME}
  rules:
    - host: ${TF_VAR_base_domain}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${NGINX_SERVICE_NAME}
                port:
                  number: 80
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb-host-svc
  namespace: default
spec:
  ports:
  - protocol: TCP
    port: 3306
    targetPort: 3306
---
apiVersion: v1
kind: Endpoints
metadata:
  name: mariadb-host-svc
  namespace: default
subsets:
  - addresses:
      - ip: ${NODE_PRIVATE_IP}
    ports:
      - port: 3306
        protocol: TCP
EOT_K8S_RESOURCES
echo "Manifiestos Kubernetes para el Panel Web aplicados."

echo "Clonando el repositorio de worker_k8s_provisioning..."

cd /tmp
git clone https://dramlin1010:$GIT_TOKEN_TF@$GIT_HOST/dramlin1010/k8servers-worker.git

cp k8servers-worker/worker_k8s_provisioning_real.sh /usr/local/bin/worker_k8s_provisioning_real.sh

chmod +x /usr/local/bin/worker_k8s_provisioning_real.sh
echo "Script clonado y permisos establecidos."

echo "Configurando SSHD para SFTP..."
SFTP_EFS_BASE_PATH="/mnt/efs-clientes"
mkdir -p "${SFTP_EFS_BASE_PATH}"
groupadd sftpusers || echo "Grupo sftpusers ya existe"
if ! grep -q "Match Group sftpusers" /etc/ssh/sshd_config; then
  echo '
Match Group sftpusers
    ChrootDirectory '"${SFTP_EFS_BASE_PATH}"'/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication no
' >> /etc/ssh/sshd_config
fi


if grep -q "^\s*Subsystem\s*sftp" /etc/ssh/sshd_config; then
    sed -i 's|^\s*Subsystem\s*sftp\s*.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config
elif ! grep -q "Subsystem sftp internal-sftp" /etc/ssh/sshd_config; then
    echo 'Subsystem sftp internal-sftp' >> /etc/ssh/sshd_config
fi


echo "Configurando MariaDB..."
systemctl start mariadb
systemctl enable mariadb

for i in {1..20}; do
  if mysqladmin ping -u root &>/dev/null; then
    echo "MariaDB está listo."
    break
  fi
  echo "Esperando a MariaDB... intento $i"
  sleep 3
done
if ! mysqladmin ping -u root &>/dev/null; then
  echo "ERROR CRÍTICO: MariaDB no parece estar listo después de 60 segundos."
  exit 1
fi

DB_NAME="k8servers"
DB_USER="daniel"
DB_PASSWORD="Kt3xa6RqSAgdpskCZyuWfX"

echo "Creando Base de Datos '${DB_NAME}' y Usuario '${DB_USER}' para diferentes hosts..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Localhost
mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"

# IP Privada del Nodo
mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${NODE_PRIVATE_IP}' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${NODE_PRIVATE_IP}';"

# Cualquier Host (%)
mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';"

mysql -u root -e "FLUSH PRIVILEGES;"
echo "Base de Datos y Usuario creados/actualizados y privilegios concedidos."

echo "Creando tablas en la base de datos '${DB_NAME}'..."

echo "Creando tablas en la base de datos '${DB_NAME}'..."

mysql -u root -D "${DB_NAME}" <<EOF
CREATE TABLE IF NOT EXISTS Cliente (
    ClienteID INT AUTO_INCREMENT PRIMARY KEY,
    Nombre VARCHAR(50) NOT NULL,
    Apellidos VARCHAR(70) NOT NULL,
    Email VARCHAR(100) NOT NULL UNIQUE,
    Passwd VARCHAR(255) NOT NULL,
    Telefono VARCHAR(20),
    Pais VARCHAR(50),
    Direccion VARCHAR(150),
    Fecha_Registro DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    Token VARCHAR(255) NULL,
    TokenExpira DATETIME NULL
);

CREATE TABLE IF NOT EXISTS Plan_Hosting (
    PlanHostingID VARCHAR(50) PRIMARY KEY,
    NombrePlan VARCHAR(100) NOT NULL,
    Descripcion TEXT,
    Precio DECIMAL(10, 2) NOT NULL,
    Activo BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS SitioWeb (
    SitioID INT AUTO_INCREMENT PRIMARY KEY,
    ClienteID INT NOT NULL,
    PlanHostingID VARCHAR(50) NOT NULL,
    SubdominioElegido VARCHAR(63) NOT NULL,
    DominioCompleto VARCHAR(255) NOT NULL UNIQUE,
    EstadoServicio VARCHAR(30) NOT NULL DEFAULT 'pendiente_pago',
    EstadoAprovisionamientoK8S VARCHAR(50) NOT NULL DEFAULT 'no_iniciado',
    DirectorioEFSRuta VARCHAR(255) NULL,
    FechaContratacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FechaProximaRenovacion DATE,
    FechaActualizacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (ClienteID) REFERENCES Cliente(ClienteID) ON DELETE CASCADE,
    FOREIGN KEY (PlanHostingID) REFERENCES Plan_Hosting(PlanHostingID)
);

CREATE TABLE IF NOT EXISTS Factura (
    FacturaID INT AUTO_INCREMENT PRIMARY KEY,
    ClienteID INT NOT NULL,
    SitioID INT NULL,
    Descripcion VARCHAR(255) NOT NULL,
    FechaEmision DATE NOT NULL,
    FechaVencimiento DATE,
    Monto DECIMAL(10, 2) NOT NULL,
    Estado VARCHAR(20) NOT NULL DEFAULT 'pendiente',
    MetodoPago VARCHAR(50) NULL,
    TransaccionID VARCHAR(100) NULL,
    FechaPago DATETIME NULL,
    FOREIGN KEY (ClienteID) REFERENCES Cliente(ClienteID) ON DELETE RESTRICT,
    FOREIGN KEY (SitioID) REFERENCES SitioWeb(SitioID) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS Ticket_Soporte (
    TicketID INT AUTO_INCREMENT PRIMARY KEY,
    ClienteID INT NOT NULL,
    SitioID INT NULL,
    FechaCreacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UltimaActualizacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    Asunto VARCHAR(150) NOT NULL,
    Estado VARCHAR(20) NOT NULL DEFAULT 'abierto',
    Prioridad VARCHAR(10) NOT NULL DEFAULT 'media',
    FOREIGN KEY (ClienteID) REFERENCES Cliente(ClienteID) ON DELETE CASCADE,
    FOREIGN KEY (SitioID) REFERENCES SitioWeb(SitioID) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS Mensaje_Ticket (
    MensajeID INT AUTO_INCREMENT PRIMARY KEY,
    TicketID INT NOT NULL,
    UsuarioID INT NULL,
    EsAdmin BOOLEAN NOT NULL DEFAULT FALSE,
    Contenido TEXT NOT NULL,
    FechaEnvio DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (TicketID) REFERENCES Ticket_Soporte(TicketID) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS Tareas_Aprovisionamiento_K8S (
    TareaID INT AUTO_INCREMENT PRIMARY KEY,
    SitioID INT NOT NULL UNIQUE,
    TipoTarea VARCHAR(50) NOT NULL DEFAULT 'aprovisionar_pod',
    EstadoTarea VARCHAR(50) NOT NULL DEFAULT 'pendiente',
    Intentos INT NOT NULL DEFAULT 0,
    UltimoError TEXT NULL,
    FechaSolicitud DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FechaActualizacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (SitioID) REFERENCES SitioWeb(SitioID) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS Log_Actividad (
    LogID INT AUTO_INCREMENT PRIMARY KEY,
    ClienteID INT NULL,
    TipoActividad VARCHAR(50) NOT NULL,
    Descripcion TEXT,
    DireccionIP VARCHAR(45),
    UserAgent VARCHAR(255),
    FechaLog DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT IGNORE INTO Plan_Hosting (PlanHostingID, NombrePlan, Descripcion, Precio, Activo)
VALUES ('developer_pro', 'Developer Pro Hosting', 'Nuestro plan todo incluido para desarrolladores y creativos.', 25.00, TRUE);
EOF

echo "Tablas creadas."

echo "Creando usuario administrador..."
ADMIN_EMAIL="admin@k8servers.es"
ADMIN_PASS_PLAIN="admin1234"
ADMIN_PASS_HASH=$(php -r "echo password_hash('$ADMIN_PASS_PLAIN', PASSWORD_DEFAULT);")

mysql -u root -D "${DB_NAME}" -e "
INSERT INTO Cliente (Nombre, Apellidos, Email, Passwd, Telefono, Pais, Direccion, Fecha_Registro)
VALUES ('Admin', 'K8Servers', '${ADMIN_EMAIL}', '${ADMIN_PASS_HASH}', '000000000', 'System', 'System Address', NOW())
ON DUPLICATE KEY UPDATE Nombre='Admin', Apellidos='K8Servers', Passwd='${ADMIN_PASS_HASH}', Telefono='000000000', Pais='System', Direccion='System Address';
"
echo "Usuario administrador 'admin@k8servers.es' creado/actualizado."

echo "--- User Data Script Finalizado ---"
