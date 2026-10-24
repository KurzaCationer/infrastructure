variable "state_bucket" {
  description = "Existing S3 bucket containing the cluster and bootstrap states."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the existing state bucket."
  type        = string
}
