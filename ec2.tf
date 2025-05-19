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
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1 # Cambiado el nombre del log si quieres
set -e
echo "--- Iniciando User Data con Payload Comprimido ---"

# Leer el contenido del fichero que YA ESTÁ en Base64
PAYLOAD_B64='${file("${path.module}/script/user_data.sh.gz.b64")}'
# El 'echo' y las comillas simples alrededor de file() ayudan a manejar saltos de línea
# que podrían estar en el fichero .b64 si no se usó -w 0, aunque es mejor asegurar -w 0.

DECOMPRESSED_SCRIPT_PATH="/tmp/user_data.sh" # Nombre del script descomprimido

echo "Decodificando y descomprimiendo payload..."
# Quitar saltos de línea del payload si los hubiera, aunque -w 0 debería evitarlos
echo "$${PAYLOAD_B64}" | tr -d '\n\r' | base64 -d | gzip -dc > "$${DECOMPRESSED_SCRIPT_PATH}"

if [ ! -s "$${DECOMPRESSED_SCRIPT_PATH}" ]; then
    echo "ERROR CRÍTICO: Fallo al decodificar o descomprimir el script."
    exit 1
fi

chmod +x "$${DECOMPRESSED_SCRIPT_PATH}"

echo "Ejecutando script descomprimido..."
export TF_VAR_admin_email="${var.admin_email}"
export TF_VAR_base_domain="${var.base_domain}"
export TF_VAR_efs_fs_id="${aws_efs_file_system.panel_web_efs.id}"
export TF_VAR_git_pat="${var.git_pat}"
export TF_VAR_git_clone_username="${var.git_clone_username}"
export TF_VAR_aws_access_key_id="${var.aws_access_key_id}"
export TF_VAR_aws_secret_access_key="${var.aws_secret_access_key}"
export TF_VAR_aws_session_token="${var.aws_session_token}"
export TF_VAR_aws_region="${var.aws_region}"

"$${DECOMPRESSED_SCRIPT_PATH}"

echo "--- User Data con Payload Comprimido Finalizado ---"
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