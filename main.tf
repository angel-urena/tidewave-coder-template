terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "docker" {
  host = var.socket
}

provider "coder" {
}

data "coder_workspace" "me" {
}

data "coder_workspace_owner" "me" {
}

data "coder_provisioner" "me" {
}

variable "socket" {
  type        = string
  description = <<-EOF
  The Unix socket that the Docker daemon listens on and how containers
  communicate with the Docker daemon.

  Either Unix or TCP
  e.g., unix:///var/run/docker.sock

  EOF
  default     = "unix:///var/run/docker.sock"
}

data "coder_parameter" "claude_code_oauth_token" {
  name         = "claude_code_oauth_token"
  display_name = "Claude Code OAuth Token"
  type         = "string"
  description  = "Claude Code OAuth token for authentication"
  mutable      = true
}

resource "coder_env" "claude_code_oauth_token" {
  agent_id = coder_agent.dev.id
  name     = "CLAUDE_CODE_OAUTH_TOKEN"
  value    = data.coder_parameter.claude_code_oauth_token.value
}

data "coder_parameter" "mise_github_token" {
  name         = "mise_github_token"
  display_name = "Mise GitHub Token"
  type         = "string"
  description  = "GitHub token for Mise to avoid rate limits"
  mutable      = true
  default      = ""
}

resource "coder_env" "mise_github_token" {
  agent_id = coder_agent.dev.id
  name     = "MISE_GITHUB_TOKEN"
  value    = data.coder_parameter.mise_github_token.value
}

resource "coder_env" "claude_use_oauth" {
  agent_id = coder_agent.dev.id
  name     = "CLAUDE_CODE_USE_OAUTH"
  value    = "1"
}

# The Claude Code module does the automatic task reporting
# Other agent modules: https://registry.coder.com/modules?search=agent
# Or use a custom agent:
module "claude-code" {
  count                   = data.coder_workspace.me.start_count
  source                  = "registry.coder.com/coder/claude-code/coder"
  version                 = "4.7.5"
  agent_id                = coder_agent.dev.id
  workdir                 = data.coder_parameter.repo_url.value != "" ? "/home/coder/projects/${trimsuffix(basename(data.coder_parameter.repo_url.value), ".git")}" : "/home/coder/projects"
  install_claude_code     = true
  claude_code_version     = "latest"
  claude_code_oauth_token = data.coder_parameter.claude_code_oauth_token.value
  model                   = "opus"
  order                   = 999
  post_install_script = data.coder_parameter.setup_script.value
}

module "tidewave" {
  count    = data.coder_workspace.me.start_count
  source   = "git::https://github.com/angel-urena/tidewave-coder-module.git"
  agent_id = coder_agent.dev.id
  port     = data.coder_parameter.tidewave_port.value

  extra_allowed_origins = [
    "http://${data.coder_workspace.me.name}.test:${data.coder_parameter.tidewave_port.value}",
  ]
}

# We are using presets to set the prompts, image, and set up instructions
# See https://coder.com/docs/admin/templates/extending-templates/parameters#workspace-presets
data "coder_workspace_preset" "default" {
  name    = "Default"
  default = true
  parameters = {
    "system_prompt" = <<-EOT
      You are a helpful assistant that can help with code. You are running inside a Coder Workspace and provide status updates to the user via Coder MCP. Stay on track, feel free to debug, but when the original plan fails, do not choose a different route/architecture without checking the user first.
    EOT

    "setup_script"    = <<-EOT
    # Set up projects dir
    mkdir -p /home/coder/projects
    cd /home/coder/projects

    # Clone repo if a URL was provided
    if [ -n "${data.coder_parameter.repo_url.value}" ]; then
      REPO_DIR=$(basename "${data.coder_parameter.repo_url.value}" .git)
      if [ ! -d "$REPO_DIR" ]; then
        git clone "${data.coder_parameter.repo_url.value}"
      else
        cd "$REPO_DIR"
        git fetch
        if git diff-index --quiet HEAD -- && \
          [ -z "$(git status --porcelain --untracked-files=no)" ] && \
          [ -z "$(git log --branches --not --remotes)" ]; then
          echo "Repo is clean. Pulling latest changes..."
          git pull
        else
          echo "Repo has uncommitted or unpushed changes. Skipping pull."
        fi
      fi
      cd /home/coder/projects/$REPO_DIR
    fi

    # Install dependencies if an install command was provided
    if [ -n "${data.coder_parameter.install_command.value}" ]; then
      echo "Installing dependencies..."
      ${data.coder_parameter.install_command.value}
    fi

    # Start the project dev server in the background if a start command was provided
    if [ -n "${data.coder_parameter.start_command.value}" ]; then
      echo "Starting project..."
      nohup ${data.coder_parameter.start_command.value} > /tmp/project.log 2>&1 &
    fi
    EOT
    "preview_port"    = "3000"
    "container_image" = "codercom/example-universal:ubuntu"
  }
}

# Advanced parameters (these are all set via preset)
data "coder_parameter" "system_prompt" {
  name         = "system_prompt"
  display_name = "System Prompt"
  type         = "string"
  form_type    = "textarea"
  description  = "System prompt for the agent with generalized instructions"
  mutable      = false
}
data "coder_parameter" "ai_prompt" {
  type        = "string"
  name        = "AI Prompt"
  default     = ""
  description = "Write a prompt for Claude Code"
  mutable     = true
}
data "coder_parameter" "setup_script" {
  name         = "setup_script"
  display_name = "Setup Script"
  type         = "string"
  form_type    = "textarea"
  description  = "Script to run before running the agent"
  mutable      = false
}
data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Repository URL"
  type         = "string"
  default      = ""
  description  = "Git repository URL to clone into the projects directory (leave empty to skip)"
  mutable      = false
}
data "coder_parameter" "install_command" {
  name         = "install_command"
  display_name = "Install Command"
  type         = "string"
  default      = ""
  description  = "Command to install project dependencies (e.g., pnpm install, npm install, pip install -r requirements.txt)"
  mutable      = false
}
data "coder_parameter" "start_command" {
  name         = "start_command"
  display_name = "Start Command"
  type         = "string"
  default      = ""
  description  = "Command to start the project dev server in the background (e.g., pnpm dev, npm run dev)"
  mutable      = false
}
data "coder_parameter" "container_image" {
  name         = "container_image"
  display_name = "Container Image"
  type         = "string"
  default      = "codercom/example-universal:ubuntu"
  mutable      = false
}
data "coder_parameter" "tidewave_port" {
  name         = "tidewave_port"
  display_name = "Tidewave Port"
  description  = "The port for Tidewave to listen on"
  type         = "number"
  default      = "9000"
  mutable      = true
}
data "coder_parameter" "preview_port" {
  name         = "preview_port"
  display_name = "Preview Port"
  description  = "The port the web app is running to preview in Tasks"
  type         = "number"
  default      = "3000"
  mutable      = false
}

# Other variables for Claude Code
resource "coder_env" "claude_task_prompt" {
  agent_id = coder_agent.dev.id
  name     = "CODER_MCP_CLAUDE_TASK_PROMPT"
  value    = data.coder_parameter.ai_prompt.value
}
resource "coder_env" "app_status_slug" {
  agent_id = coder_agent.dev.id
  name     = "CODER_MCP_APP_STATUS_SLUG"
  value    = "claude-code"
}
resource "coder_env" "claude_system_prompt" {
  agent_id = coder_agent.dev.id
  name     = "CODER_MCP_CLAUDE_SYSTEM_PROMPT"
  value    = data.coder_parameter.system_prompt.value
}

module "coder-login" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/coder-login/coder"
  agent_id = coder_agent.dev.id
}

module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/dotfiles/coder"
  agent_id = coder_agent.dev.id
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/code-server/coder"
  agent_id = coder_agent.dev.id
  folder   = data.coder_parameter.repo_url.value != "" ? "/home/coder/projects/${trimsuffix(basename(data.coder_parameter.repo_url.value), ".git")}" : "/home/coder/projects"
}

module "git-config" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/git-config/coder"
  agent_id = coder_agent.dev.id
}

resource "coder_agent" "dev" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  display_apps {
    vscode                 = true
    vscode_insiders        = false
    ssh_helper             = false
    port_forwarding_helper = true
    web_terminal           = true
  }

  startup_script_behavior = "non-blocking"
  connection_timeout      = 300

  env = {

    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
  }

  startup_script = <<EOT
#!/bin/sh

EOT

}

resource "coder_app" "preview" {
  agent_id     = coder_agent.dev.id
  slug         = "preview"
  display_name = "Preview your app"
  icon         = "${data.coder_workspace.me.access_url}/emojis/1f50e.png"
  url          = "http://localhost:${data.coder_parameter.preview_port.value}"
  share        = "authenticated"
  subdomain    = true
  open_in      = "tab"
  order        = 0
  healthcheck {
    url       = "http://localhost:${data.coder_parameter.preview_port.value}/"
    interval  = 5
    threshold = 15
  }
}

resource "docker_image" "workspace" {
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  build {
    context = path.module
  }
  triggers = {
    dockerfile_hash = filesha256("${path.module}/Dockerfile")
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.workspace.image_id
  # Uses lower() to avoid Docker restriction on container names.
  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = lower(data.coder_workspace.me.name)
  dns      = ["1.1.1.1"]

  # Use the docker gateway if the access URL is 127.0.0.1
  #entrypoint = ["sh", "-c", replace(coder_agent.dev.init_script, "127.0.0.1", "host.docker.internal")]

  # Use the docker gateway if the access URL is 127.0.0.1
  command = [
    "sh", "-c",
    <<EOT
    trap '[ $? -ne 0 ] && echo === Agent script exited with non-zero code. Sleeping infinitely to preserve logs... && sleep infinity' EXIT
    ${replace(coder_agent.dev.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")}
    EOT
  ]


  env = ["CODER_AGENT_TOKEN=${coder_agent.dev.token}"]
  volumes {
    container_path = "/home/coder/"
    volume_name    = docker_volume.coder_volume.name
    read_only      = false
  }
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  host {
    host = "${data.coder_workspace.me.name}.test"
    ip   = "127.0.0.1"
  }
  host {
    host = "${data.coder_workspace.me.name}.test"
    ip   = "::1"
  }
}

resource "docker_volume" "coder_volume" {
  name = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id
  item {
    key   = "image"
    value = data.coder_parameter.container_image.value
  }
}
