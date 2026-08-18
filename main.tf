resource "aws_instance" "devbox" {
  ami                  = data.aws_ami.debian_13_arm64.id
  instance_type        = "t4g.medium"
  iam_instance_profile = "cubesat-devbox-role"

  vpc_security_group_ids = [
    aws_security_group.devbox_sg.id
  ]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = file("${path.module}/bootstrap.sh")

  tags = {
    Name        = "cubesat-devbox"
    Project     = "devbox"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
