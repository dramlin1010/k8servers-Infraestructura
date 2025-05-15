output "instance_public_ip" {
  description = "IP pública de la instancia K3S"
  value       = aws_eip.k3s_node_eip.public_ip
}

output "ssh_command" {
  description = "Comando para conectar via SSH"
  value       = "ssh -i ../${var.key_name}.pem ubuntu@${aws_eip.k3s_node_eip.public_ip}"
}

output "kubeconfig_setup_command" {
  description = "Comando para copiar KUBECONFIG desde la instancia (ejecutar localmente)"
  value       = "scp -i ../${var.key_name}.pem ubuntu@${aws_eip.k3s_node_eip.public_ip}:/home/ubuntu/.kube/config ~/.kube/config-${var.project_name} | kubectl --kubeconfig=/home/daniel/.kube/config-${var.project_name} get all"
}