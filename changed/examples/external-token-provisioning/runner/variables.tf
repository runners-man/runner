variable "name" {
  type    = string
  default = "payments-ci"
}

variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "state_bucket" {
  type = string
}

variable "runner_auth_token_version" {
  description = "Bump in the same merge request as a token rotation. Nothing else can tell the instance to re-read SSM."
  type        = number
  default     = 1
}
