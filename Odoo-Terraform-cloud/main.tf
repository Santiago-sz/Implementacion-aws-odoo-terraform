# ─────────────────────────────────────────────────────────────────────────────
# 1. BLOQUE TERRAFORM Y PROVEEDOR
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.1"
    }
  }
}

provider "aws" {
  region = "sa-east-1"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. BÚSQUEDA DE AMI (UBUNTU 22.04)
# ─────────────────────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. RED VIRTUAL PRIVADA (VPC) Y SUBREDES
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "odoo_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "odoo-vpc" }
}

resource "aws_internet_gateway" "odoo_igw" {
  vpc_id = aws_vpc.odoo_vpc.id
  tags = { Name = "odoo-igw" }
}

resource "aws_subnet" "odoo_subnet" {
  vpc_id                  = aws_vpc.odoo_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "sa-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "odoo-subnet" }
}

resource "aws_route_table" "odoo_rt" {
  vpc_id = aws_vpc.odoo_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.odoo_igw.id
  }
  tags = { Name = "odoo-rt" }
}

resource "aws_route_table_association" "odoo_rta" {
  subnet_id      = aws_subnet.odoo_subnet.id
  route_table_id = aws_route_table.odoo_rt.id
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. SECURITY GROUP (FIREWALL)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "odoo_sg" {
  name        = "odoo-sg"
  description = "Permite trafico a Odoo y SSH"
  vpc_id      = aws_vpc.odoo_vpc.id

  ingress {
    from_port   = 8069
    to_port     = 8069
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "odoo-sg" }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. PAR DE CLAVES SSH
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_key_pair" "odoo_key" {
  key_name   = "odoo-key"
  public_key = file("${path.module}/odoo-key.pub")
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. INSTANCIA EC2 Y CONFIGURACIÓN (DOcker + CloudWatch)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_instance" "odoo" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.odoo_subnet.id
  vpc_security_group_ids = [aws_security_group.odoo_sg.id]
  key_name               = aws_key_pair.odoo_key.key_name

  # Vinculamos el perfil de CloudWatch que está en security.tf
  iam_instance_profile   = aws_iam_instance_profile.odoo_profile.name

  user_data = <<EOF
#!/bin/bash
set -e

apt-get update -y
apt-get install -y docker.io docker-compose wget

wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb

mkdir -p /opt/odoo/config /opt/odoo/addons /opt/odoo/logs
chmod -R 777 /opt/odoo/logs

cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json <<'EOC'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/odoo/logs/odoo-server.log",
            "log_group_name": "odoo-app-logs",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "odoo-system-logs",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
EOC

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

cat > /opt/odoo/config/odoo.conf <<'CONF'
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
admin_passwd = admin123
db_host = db
db_port = 5432
db_user = odoo
db_password = odoo_pass
logfile = /var/log/odoo/odoo-server.log
CONF

cat > /opt/odoo/docker-compose.yml <<'COMPOSE'
services:
  db:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: odoo_pass
    volumes:
      - odoo-db-data:/var/lib/postgresql/data

  web:
    image: odoo:17.0
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "8069:8069"
    environment:
      HOST: db
      USER: odoo
      PASSWORD: odoo_pass
    volumes:
      - odoo-web-data:/var/lib/odoo
      - ./config:/etc/odoo
      - ./addons:/mnt/extra-addons
      - ./logs:/var/log/odoo
volumes:
  odoo-db-data:
  odoo-web-data:
COMPOSE

cd /opt/odoo
docker-compose up -d
EOF

  tags = {
    Name = "odoo-server"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────
output "instance_id" {
  value = aws_instance.odoo.id
}

output "odoo_url" {
  value = "http://${aws_instance.odoo.public_ip}:8069"
}

output "ssh_command" {
  value = "ssh -i odoo-key ubuntu@${aws_instance.odoo.public_ip}"
}