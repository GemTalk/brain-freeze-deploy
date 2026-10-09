# -- where -----------------------------------------------------------------------

variable "project_id" {
  description = "The GCP project to deploy into."
  type        = string
}

variable "region" {
  description = "The region for the VM, the data disk and the backups bucket."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "The two zones the data disk is replicated across. One instance group stands in each; active_zone says which one runs the VM."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b"]

  validation {
    condition     = length(var.zones) == 2
    error_message = "A regional disk replicates across exactly two zones."
  }
}

variable "active_zone" {
  description = "Which of the zones runs the VM. To fail over, set this to the other one and apply (README.md, \"Failing over\")."
  type        = string
  default     = "us-central1-a"
}

variable "force_attach" {
  description = "Let a new VM take the data disk from a VM the API still reports as RUNNING. Only for a zone outage, where the old VM cannot let go: set it, fail over, then set it back."
  type        = bool
  default     = false
}

variable "name" {
  description = "Prefix for every resource's name."
  type        = string
  default     = "brainfreeze"
}

# -- what the site is ----------------------------------------------------------------

variable "domain" {
  description = "The site's domain, e.g. brainfreeze.example.com. Its links -- policies, ID cards, claims -- are https://<domain>/..., so this, like the static IP, should never change."
  type        = string
}

variable "dns_managed_zone" {
  description = "A Cloud DNS managed zone in this project that holds the domain. If set, the A record is made here; if empty, point the domain at the static_ip output yourself."
  type        = string
  default     = ""
}

# -- how big -------------------------------------------------------------------------

variable "machine_type" {
  description = "The VM's machine type. Each app instance answers one request at a time and keeps a core busy while it does, and the database wants one more."
  type        = string
  default     = "e2-standard-4"
}

variable "image" {
  description = "The VM's boot image. An arm64 machine type needs an arm64 image (ubuntu-2404-lts-arm64); GemDB runs on both."
  type        = string
  default     = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
}

variable "app_instances" {
  description = "How many instances of the Flask app serve behind HAProxy. Each is a database session; the free license allows 10, the database uses 2, and backups and releases need 1 each."
  type        = number
  default     = 3

  validation {
    condition     = var.app_instances >= 1 && var.app_instances <= 6
    error_message = "1 to 6: the free GemStone license allows 10 sessions in all."
  }
}

variable "page_cache_mb" {
  description = "The database's shared page cache, in MB. Null leaves GemDB Code's 100 MB."
  type        = number
  default     = null
}

variable "data_disk_size_gb" {
  description = "The data disk: the engine, the database (GemDB reserves the free license's full 10 GB up front), its logs, and room to stage a backup."
  type        = number
  default     = 50

  validation {
    condition     = var.data_disk_size_gb >= 30
    error_message = "At least 30 GB: 10 GB of extent, 2 GB of engine, and room for logs and a backup."
  }
}

variable "data_disk_override" {
  description = "Serve from this regional disk instead of the one Terraform made: a disk restored from a snapshot (README.md, \"Restoring\"). Empty serves Terraform's."
  type        = string
  default     = ""
}

# -- what runs -------------------------------------------------------------------------

variable "app_repo" {
  description = "Where the app, brain-freeze, is cloned from, once, on the data disk's first boot. The VM clones without credentials, so it must be public (or a URL that carries its own access)."
  type        = string
  default     = "https://github.com/GemTalk/brain-freeze.git"
}

variable "app_ref" {
  description = "The brain-freeze ref the first boot checks out. Later releases are ./deploy.sh, not this."
  type        = string
  default     = "main"
}

variable "deploy_repo" {
  description = "Where this repository, brain-freeze-deploy, is cloned from on the first boot: the VM runs its node/ scripts. Cloned without credentials, like app_repo."
  type        = string
}

variable "deploy_ref" {
  description = "The brain-freeze-deploy ref the first boot checks out."
  type        = string
  default     = "main"
}

variable "gemdb_code_version" {
  description = "The GemDB Code release whose setup builds the database on first boot. 1.6.0 carries GemStone 4.0.0.a4."
  type        = string
  default     = "1.6.0"
}

variable "node_version" {
  description = "Node.js, for GemDB Code's setup on first boot only."
  type        = string
  default     = "22.12.0"
}

# -- keeping it safe ---------------------------------------------------------------------

variable "snapshot_every_hours" {
  description = "How often the data disk is snapshotted."
  type        = number
  default     = 4
}

variable "snapshot_retention_days" {
  description = "How long disk snapshots are kept."
  type        = number
  default     = 14
}

variable "backup_retention_days" {
  description = "How long database backups and transaction logs are kept in the bucket."
  type        = number
  default     = 30
}

variable "requests_per_minute" {
  description = "Requests a single client IP may make a minute before Cloud Armor answers 429."
  type        = number
  default     = 300
}

variable "writes_per_minute" {
  description = "POSTs -- quotes, policies, claims -- a single client IP may make a minute. Every one is stored, against the free license's 10 GB."
  type        = number
  default     = 20
}

variable "autoheal_initial_delay_sec" {
  description = "How long a new VM has before autohealing judges it. The first boot sets GemDB up and takes 10-20 minutes; later boots take 2-3."
  type        = number
  default     = 1800
}

# -- who hears about it ---------------------------------------------------------------------

variable "alert_email" {
  description = "Where alerts go. Empty makes the alert policies with no one to tell."
  type        = string
  default     = ""
}
