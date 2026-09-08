terraform {
  required_version = ">= 1.11.0" # write-only arguments

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83.0" # value_wo on aws_ssm_parameter
    }
  }
}
