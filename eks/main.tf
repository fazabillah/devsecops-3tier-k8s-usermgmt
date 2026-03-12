provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "devopsfaza_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "devopsfaza-vpc"
  }
}

resource "aws_subnet" "devopsfaza_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.devopsfaza_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.devopsfaza_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["us-east-1a", "us-east-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "devopsfaza-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "devopsfaza_igw" {
  vpc_id = aws_vpc.devopsfaza_vpc.id

  tags = {
    Name = "devopsfaza-igw"
  }
}

resource "aws_route_table" "devopsfaza_route_table" {
  vpc_id = aws_vpc.devopsfaza_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.devopsfaza_igw.id
  }

  tags = {
    Name = "devopsfaza-route-table"
  }
}

resource "aws_route_table_association" "devopsfaza_association" {
  count          = 2
  subnet_id      = aws_subnet.devopsfaza_subnet[count.index].id
  route_table_id = aws_route_table.devopsfaza_route_table.id
}

resource "aws_security_group" "devopsfaza_cluster_sg" {
  vpc_id = aws_vpc.devopsfaza_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsfaza-cluster-sg"
  }
}

resource "aws_security_group" "devopsfaza_node_sg" {
  vpc_id = aws_vpc.devopsfaza_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsfaza-node-sg"
  }
}

resource "aws_eks_cluster" "devopsfaza" {
  name     = "devopsfaza-cluster"
  role_arn = aws_iam_role.devopsfaza_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.devopsfaza_subnet[*].id
    security_group_ids = [aws_security_group.devopsfaza_cluster_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.devopsfaza_cluster_role_policy,
  ]
}

data "tls_certificate" "devopsfaza" {
  url = aws_eks_cluster.devopsfaza.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "devopsfaza" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.devopsfaza.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.devopsfaza.identity[0].oidc[0].issuer
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.devopsfaza.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver_role.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.devopsfaza,
    aws_iam_role_policy_attachment.ebs_csi_driver_policy,
  ]
}

resource "aws_eks_node_group" "devopsfaza" {
  cluster_name    = aws_eks_cluster.devopsfaza.name
  node_group_name = "devopsfaza-node-group"
  node_role_arn   = aws_iam_role.devopsfaza_node_group_role.arn
  subnet_ids      = aws_subnet.devopsfaza_subnet[*].id

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  instance_types = ["t2.medium"]

  remote_access {
    ec2_ssh_key               = var.ssh_key_name
    source_security_group_ids = [aws_security_group.devopsfaza_node_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.devopsfaza_node_group_role_policy,
    aws_iam_role_policy_attachment.devopsfaza_node_group_cni_policy,
    aws_iam_role_policy_attachment.devopsfaza_node_group_registry_policy,
    aws_iam_role_policy_attachment.devopsfaza_node_group_ebs_policy,
  ]
}

resource "aws_iam_role" "devopsfaza_cluster_role" {
  name = "devopsfaza-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "devopsfaza_cluster_role_policy" {
  role       = aws_iam_role.devopsfaza_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "devopsfaza_node_group_role" {
  name = "devopsfaza-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "devopsfaza_node_group_role_policy" {
  role       = aws_iam_role.devopsfaza_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "devopsfaza_node_group_cni_policy" {
  role       = aws_iam_role.devopsfaza_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "devopsfaza_node_group_registry_policy" {
  role       = aws_iam_role.devopsfaza_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "devopsfaza_node_group_ebs_policy" {
  role       = aws_iam_role.devopsfaza_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "ebs_csi_driver_role" {
  name = "devopsfaza-ebs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.devopsfaza.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.devopsfaza.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.devopsfaza.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy" {
  role       = aws_iam_role.ebs_csi_driver_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
