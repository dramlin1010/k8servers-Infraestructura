resource "aws_security_group" "k3s_node_sg" {
  name        = "${var.project_name}-k3s-node-sg"
  description = "Grupo de seguridad para nodo k3s/SFTP/EFS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
    description = "Allow SSH"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS"
  }

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    self        = true # Permite trafico desde instancias en este mismo SG
    description = "Allow NFS for EFS from self"
  }

  # Trafico saliente
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-k3s-node-sg"
  }
}
