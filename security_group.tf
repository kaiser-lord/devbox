resource "aws_security_group" "devbox_sg" {
  name        = "devbox-sg"
  description = "Security group for the development box"

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project     = "devbox"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
