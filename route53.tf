variable "domain_name" {
  description = "Dominio raiz"
  type        = string
  default     = "k8servers.es"
}

data "aws_route53_zone" "main" {
  name         = "${var.domain_name}."
  private_zone = false
}

resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = ""
  type    = "A"
  ttl     = 300
  records = [
    aws_eip.k3s_node_eip.public_ip
  ]
  allow_overwrite = true
}
