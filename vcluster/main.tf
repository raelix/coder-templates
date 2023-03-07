terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.6.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.12.1"
    }
    loft = {
      source = "registry.terraform.io/loft-sh/loft"
    }
  }
}

variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
}

variable "namespace" {
  type        = string
  sensitive   = true
  description = "The namespace to create workspaces in (must exist prior to creating workspaces)"
}

variable "home_disk_size" {
  type        = number
  description = "How large would you like your home volume to be (in GB)?"
  default     = 10
  validation {
    condition     = var.home_disk_size >= 1
    error_message = "Value must be greater than or equal to 1."
  }
}

variable "git_project" {
  type        = string
  description = "The git project to clone"
  default     = "git@github.com:raelix/raelix-cluster-v2.git"
}

provider "kubernetes" {
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

variable loft_host {
  type        = string
  default     = "https://10.43.123.71:443"
  description = "loft host"
}

variable loft_access_key {
  type        = string
  description = "loft access_key"
  sensitive = true
}

provider "loft" {
  host       = var.loft_host
  access_key = var.loft_access_key
  insecure   = true
}

resource "kubernetes_ingress_v1" "vcluster_ingress" {
  depends_on = [ loft_virtual_cluster.vcluster_with_sleep_mode ]
  
  metadata {
    name = "external-ingress"
    namespace = resource.loft_space.sleep_after.name
    annotations = {
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
      "nginx.ingress.kubernetes.io/ssl-passthrough" = "true"
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
    }
  }

  spec {
    rule {
      host = "${resource.loft_space.sleep_after.name}.raelix.com"
      http {
        path {
          backend {
            service {
              name = resource.loft_space.sleep_after.name
              port {
                number = 443
              }
            }
          }
          path = "/"
        }
      }
    }
    ingress_class_name = "nginx"
    tls {
      hosts = ["${resource.loft_space.sleep_after.name}.raelix.com"]
      # secret_name = "${resource.loft_space.sleep_after.cluster}.raelix.com"
    }
  }
}

data "kubernetes_secret_v1" "kubeconfig" {
  depends_on = [ loft_virtual_cluster.vcluster_with_sleep_mode ]
  metadata {
    name = "vc-${resource.loft_space.sleep_after.name}"
    namespace = resource.loft_space.sleep_after.name
  }
}

resource "coder_metadata" "pod_info" {
  depends_on = [data.coder_workspace.me, kubernetes_pod.main, data.kubernetes_secret_v1.kubeconfig, loft_virtual_cluster.vcluster_with_sleep_mode]
  count = data.coder_workspace.me.start_count
  resource_id = kubernetes_pod.main[0].id
  item {
    key   = "kubeconfig"
    value = yamlencode(local.out)
  }
}

locals {
  secret = yamldecode(data.kubernetes_secret_v1.kubeconfig.data["config"])

  merged = merge(local.secret.clusters[0].cluster, {server: "https://${resource.loft_space.sleep_after.name}.raelix.com"})

  dmerged = merge(local.secret.clusters[0], {cluster: local.merged})

  out = merge(yamldecode(data.kubernetes_secret_v1.kubeconfig.data["config"]), 
  {clusters: [local.dmerged]})
}


resource "loft_space" "sleep_after" {
  name        = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-home"
  cluster     = "loft-cluster"
  # sleep_after = "1h" # Sleep after 1 hour of inactivity
}

locals {
  values =<<EOF
syncer:
  extraArgs:
  - --tls-san=${resource.loft_space.sleep_after.name}.raelix.com
EOF
}

resource "loft_virtual_cluster" "vcluster_with_sleep_mode" {
  name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-home"
  cluster   = resource.loft_space.sleep_after.cluster
  namespace = resource.loft_space.sleep_after.name
  values = local.values
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<EOT
    #!/bin/bash

    # home folder can be empty, so copying default bash settings
    if [ ! -f ~/.profile ]; then
      cp /etc/skel/.profile $HOME
    fi
    if [ ! -f ~/.bashrc ]; then
      cp /etc/skel/.bashrc $HOME
    fi

    # install kubectl
    curl -LO https://dl.k8s.io/release/v1.26.0/bin/linux/amd64/kubectl
    chmod +x kubectl
    mv ./kubectl /usr/local/bin/kubectl 2>&1  | tee code-server-install.log
    # end
    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --version 4.8.3 | tee code-server-install.log
    code-server --auth none --port 13337 | tee code-server-install.log &
    # end
    echo "Cloning $GIT_PROJECT" | tee code-server-install.log 
    mkdir -p ~/.ssh
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
    git clone --progress "$GIT_PROJECT" &
    git config --global user.email "raelix@hotmail.it"
    git config --global user.name "raelix"
    # start VNC
    echo "Creating desktop..."
    mkdir -p "$XFCE_DEST_DIR"
    cp -rT "$XFCE_BASE_DIR" "$XFCE_DEST_DIR"
    # Skip default shell config prompt.
    cp /etc/zsh/newuser.zshrc.recommended $HOME/.zshrc
    echo "Initializing Supervisor..."
    nohup supervisord
  EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}
# Desktop
resource "coder_app" "novnc" {
  agent_id      = coder_agent.main.id
  slug = "vnc"
  name          = "noVNC Desktop"
  icon          = "https://ppswi.us/noVNC/app/images/icons/novnc-192x192.png"
  url           = "http://localhost:6081"
  relative_path = true
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${var.home_disk_size}Gi"
      }
    }
  }
}

locals {
  init_command = <<EOF
loft login $LOFT_URL --insecure --access-key $LOFT_ACCESS_KEY && 
loft use vcluster $VCLUSTER_NAME && 
kubectl config set-credentials administrator --token $LOFT_ACCESS_KEY && 
kubectl config set-context --current --user=administrator &&
install -c -o 1000 -g 1000  ~/.kube/config /home/coder/.kube/config
EOF
}

resource "kubernetes_pod" "main" {
  depends_on = [ loft_virtual_cluster.vcluster_with_sleep_mode ]
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  spec {
    security_context {
      run_as_user = "1000"
      fs_group    = "1000"
    }
    init_container {
      name    = "init"
      image = "loftsh/loft-ci:latest"
      command = [
      "sh", 
      "-c",
      local.init_command
       ]
      security_context {
        run_as_user = "0"
      }
      env {
        name  = "LOFT_URL"
        value = var.loft_host
      }
      env {
        name  = "LOFT_ACCESS_KEY"
        value = var.loft_access_key
      }
      env {
        name = "VCLUSTER_NAME"
        value = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-home"
      }
      volume_mount {
        mount_path = "/home/coder/.kube"
        name       = "shared"
        read_only  = false
      }
    }
    container {
      name    = "dev"
      //image   = "codercom/enterprise-base:ubuntu"
      image = "codercom/enterprise-vnc:ubuntu"
      command = ["sh", "-c", coder_agent.main.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      env {
        name  = "GIT_PROJECT"
        value = var.git_project
      }
      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
        read_only  = false
      }
      volume_mount {
        mount_path = "/home/coder/.kube"
        name       = "shared"
        read_only  = false
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }

    volume {
      name = "shared"
      empty_dir {
      }
    }


    affinity {
      pod_anti_affinity {
        // This affinity attempts to spread out all workspace pods evenly across
        // nodes.
        preferred_during_scheduling_ignored_during_execution {
          weight = 1
          pod_affinity_term {
            topology_key = "kubernetes.io/hostname"
            label_selector {
              match_expressions {
                key      = "app.kubernetes.io/name"
                operator = "In"
                values   = ["coder-workspace"]
              }
            }
          }
        }
      }
    }
  }
}
