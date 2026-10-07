# A random suffix so repeated applies cannot collide on names.
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

locals {
  name_prefix = "${var.environment}-tf-${random_string.suffix.result}"
}

# Pull the image. Terraform treats it as a resource with its own lifecycle.
resource "docker_image" "nginx" {
  name         = "nginx:${var.nginx_version}"
  keep_locally = true
}

# A generated index page, written to disk by the local provider,
# then bind-mounted into every container.
resource "local_file" "index" {
  filename = "${path.module}/generated/index.html"
  content  = <<-HTML
    <!doctype html>
    <html><head><title>Terraform-managed nginx</title></head>
    <body style="font-family:system-ui;text-align:center;padding-top:3rem">
      <h1>Provisioned by Terraform</h1>
      <p>environment: <b>${var.environment}</b></p>
      <p>replicas: <b>${var.replica_count}</b></p>
      <p>image: <b>nginx:${var.nginx_version}</b></p>
    </body></html>
  HTML
}

# count: the declarative way to ask for N of something.
resource "docker_container" "web" {
  count = var.replica_count

  name  = "${local.name_prefix}-web-${count.index}"
  image = docker_image.nginx.image_id

  ports {
    internal = 80
    external = var.base_port + count.index
  }

  volumes {
    host_path      = abspath(local_file.index.filename)
    container_path = "/usr/share/nginx/html/index.html"
    read_only      = true
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }
  labels {
    label = "environment"
    value = var.environment
  }
}
