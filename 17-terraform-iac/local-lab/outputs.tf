output "container_names" {
  description = "Names of the containers Terraform created"
  value       = docker_container.web[*].name
}

output "urls" {
  description = "Where each replica is reachable"
  value       = [for i in range(var.replica_count) : "http://localhost:${var.base_port + i}"]
}

output "image_id" {
  description = "Resolved image ID (proves the image resource was used, not the tag)"
  value       = docker_image.nginx.image_id
}
