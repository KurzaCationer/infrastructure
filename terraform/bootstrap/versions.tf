terraform {
  required_version = ">= 1.10, < 2.0"

  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
