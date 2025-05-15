resource "aws_security_group" "efs_sg" {
  name        = "${var.project_name}-efs-sg"
  description = "Allow NFS traffic to EFS Mount Targets"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "NFS from K3s Node SG"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.k3s_node_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-efs-sg"
  }
}

resource "aws_efs_file_system" "panel_web_efs" {
  creation_token = "${var.project_name}-panel-web-efs"
  encrypted        = true

  tags = {
    Name = "${var.project_name}-panel-web-efs"
  }
}

resource "aws_efs_mount_target" "panel_web_efs_mt_public" {
  file_system_id  = aws_efs_file_system.panel_web_efs.id
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.efs_sg.id]

  depends_on = [aws_efs_file_system.panel_web_efs]
}
