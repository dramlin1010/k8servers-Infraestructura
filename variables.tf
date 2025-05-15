variable "aws_region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key_id" {
  description = "AWS Access Key ID"
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key"
  type        = string
  sensitive   = true
}

variable "aws_session_token" {
  description = "AWS Session Token"
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "Instancia EC2"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Nombre del par de claves EC2 existente"
  type        = string
}

variable "hosted_zone_id" {
  description = "ID de la Hosted Zone pública de Route 53"
  type        = string
}

variable "base_domain" {
  description = "Dominio base"
  type        = string
   
}

variable "admin_email" {
  description = "Email para la cuenta de Let's Encrypt"
  type        = string
   
}

variable "aws_email" {
  description = "Email de AWS"
  type        = string
   
}

variable "ssh_allowed_cidr" {
  description = "CIDR permitido para SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "project_name" {
  description = "Nombre para etiquetar recursos"
  type        = string
  default     = "k8servers"
}

variable "efs_mount_path" {
  description = "Ruta local en la EC2 donde se montara EFS"
  type        = string
  default     = "/efs-data"
}

variable "git_pat" {
  description = "Personal Access Token para clonar el repositorio Git privado."
  type        = string
  sensitive   = true
}

variable "git_clone_username" {
  description = "Username a usar con el PAT para clonar (ej. 'x-access-token' para GitHub PATs)."
  type        = string
  default     = "x-access-token"
  sensitive   = true
}

variable "git_commit_user_name" {
  description = "Nombre de usuario para los commits de Git (si se hicieran desde la instancia)."
  type        = string
  default     = "dramlin1010"
}

variable "git_commit_user_email" {
  description = "Email para los commits de Git (si se hicieran desde la instancia)."
  type        = string
  default     = "dramlin1010@g.educaand.es"
}
