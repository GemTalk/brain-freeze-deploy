terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # Keep state somewhere shared before more than one person applies this:
  # a bucket made once by hand, then `terraform init -migrate-state`.
  #
  # backend "gcs" {
  #   bucket = "<project>-brainfreeze-tfstate"
  #   prefix = "brainfreeze"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
