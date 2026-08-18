terraform {
  backend "s3" {
    bucket         = "spartan-tfstate-7"
    key            = "devbox/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
