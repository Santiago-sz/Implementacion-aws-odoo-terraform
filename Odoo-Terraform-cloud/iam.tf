# 1. El Rol: Define que una EC2 puede "asumir" este papel
resource "aws_iam_role" "odoo_instance_role" {
  name = "odoo-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# 2. La Política: Usamos una de AWS que ya tiene los permisos de CloudWatch
resource "aws_iam_role_policy_attachment" "cw_agent_policy" {
  role       = aws_iam_role.odoo_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# 3. El Perfil de Instancia: Este es el "contenedor" que se pega a la EC2
resource "aws_iam_instance_profile" "odoo_profile" {
  name = "odoo-instance-profile"
  role = aws_iam_role.odoo_instance_role.name
}