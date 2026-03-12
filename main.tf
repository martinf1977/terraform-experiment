terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

variable "yacht_admin_password" {
  type        = string
  description = "Initial Yacht admin password used on first startup"
  sensitive   = true
  nullable    = false
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "docker-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "docker-public-subnet"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "docker-public-subnet-b"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "docker-private-subnet"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.12.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "docker-private-subnet-b"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "docker-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "docker-public-rt"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "docker-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "docker-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "docker-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "instance" {
  name        = "docker-instance-sg"
  description = "Allow app traffic from ALB and all outbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "docker-instance-sg"
  }
}

resource "aws_security_group" "alb" {
  name_prefix = "docker-alb-sg-"
  description = "Allow HTTP 8081 from internet and all outbound traffic"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "docker-alb-sg"
  }
}

resource "aws_lb" "web" {
  name               = "docker-web-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_b.id]

  tags = {
    Name = "docker-web-alb"
  }
}

resource "aws_lb_target_group" "web" {
  name     = "docker-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/index.html"
    matcher             = "200"
    interval            = 15
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_target_group" "yacht" {
  name     = "docker-yacht-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 15
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener" "web_8081" {
  load_balancer_arn = aws_lb.web.arn
  port              = 8081
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_listener" "yacht_8082" {
  load_balancer_arn = aws_lb.web.arn
  port              = 8082
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.yacht.arn
  }
}

resource "aws_iam_role" "ec2_ssm_role" {
  name = "docker-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "docker-ec2-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

resource "aws_launch_template" "docker" {
  name_prefix   = "docker-lt-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = "t2.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance.id]
  }

  user_data = base64encode(<<-EOF
		#!/bin/bash
		set -euxo pipefail
		exec > >(tee -a /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

		retry() {
			local attempts=$1
			shift
			local n=1
			until "$@"; do
				if [ "$n" -ge "$attempts" ]; then
					return 1
				fi
				n=$((n + 1))
				sleep 5
			done
		}

		ensure_docker() {
			if ! command -v docker >/dev/null 2>&1; then
				if command -v dnf >/dev/null 2>&1; then
					retry 5 dnf makecache -y || true
					retry 5 dnf install -y docker || retry 5 dnf install -y moby-engine
				elif command -v yum >/dev/null 2>&1; then
					retry 5 yum install -y docker
				else
					echo "No supported package manager found for Docker install"
					exit 1
				fi
			fi

			if ! command -v docker >/dev/null 2>&1; then
				echo "Docker installation did not complete"
				exit 1
			fi

			systemctl enable --now docker
			retry 12 docker info

			if ! id -nG ec2-user | grep -qw docker; then
				usermod -aG docker ec2-user
			fi
		}

		deploy_nginx() {
			mkdir -p /opt/app
			INSTANCE_NAME=$(hostname)
			DEPLOY_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
			printf '%s\n' \
			  'FROM nginx:alpine' \
			  'COPY index.html /usr/share/nginx/html/index.html' \
			  'EXPOSE 80' \
			  > /opt/app/Dockerfile

			echo '${base64encode(file("${path.module}/index.html"))}' | base64 -d > /opt/app/index.html

			sed -i \
			  -e "s|__INSTANCE_NAME__|$${INSTANCE_NAME}|g" \
			  -e "s|__DEPLOY_TIME__|$${DEPLOY_TIME}|g" \
			  /opt/app/index.html

			docker build -t ec2-docker-demo:latest /opt/app
			docker rm -f ec2-docker-demo >/dev/null 2>&1 || true
			docker run -d --name ec2-docker-demo -p 80:80 --restart unless-stopped ec2-docker-demo:latest
		}

		deploy_yacht() {
			docker volume create yacht-data >/dev/null
			docker rm -f yacht >/dev/null 2>&1 || true
			docker run -d --name yacht -p 8000:8000 --restart unless-stopped \
			  -e ADMIN_EMAIL=admin@yacht.local \
			  -e ADMIN_PASSWORD='${var.yacht_admin_password}' \
			  -v /var/run/docker.sock:/var/run/docker.sock \
			  -v yacht-data:/config \
			  selfhostedpro/yacht:latest
		}

		ensure_docker
		deploy_nginx
		deploy_yacht
	EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "docker-instance"
    }
  }
}

resource "aws_autoscaling_group" "docker" {
  name                      = "docker-asg"
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  health_check_type         = "ELB"
  health_check_grace_period = 300
  vpc_zone_identifier       = [aws_subnet.private.id, aws_subnet.private_b.id]
  target_group_arns         = [aws_lb_target_group.web.arn, aws_lb_target_group.yacht.arn]

  launch_template {
    id      = aws_launch_template.docker.id
    version = aws_launch_template.docker.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 180
    }
  }

  tag {
    key                 = "Name"
    value               = "docker-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

output "website_port" {
  value = 8081
}

output "website_url" {
  value = "http://${aws_lb.web.dns_name}:8081"
}

output "yacht_port" {
  value = 8082
}

output "yacht_url" {
  value = "http://${aws_lb.web.dns_name}:8082"
}
