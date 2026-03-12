# Terraform AWS EKS Template

A flat Terraform template that spins up a production-ready EKS cluster on AWS. No modules — everything is in `main.tf` so it's easy to read and modify.

## What this provisions

- VPC (10.0.0.0/16) with 2 public subnets in us-east-1a and us-east-1b
- Internet Gateway and route table (0.0.0.0/0)
- EKS cluster with a dedicated security group
- Managed node group: 3x `t2.medium` nodes with SSH access
- EBS CSI Driver addon for persistent volume support
- IAM roles for the cluster and node group with the standard AWS managed policies

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for interacting with the cluster post-deploy
- An EC2 key pair in the target region for SSH access to nodes

## Fields to customize per project

Before running, review these and change what applies:

| What | Where | Default |
|------|-------|---------|
| Region | `main.tf` line 2 | `us-east-1` |
| Availability zones | `main.tf` line 17 | `us-east-1a`, `us-east-1b` |
| Cluster name | `main.tf` — `aws_eks_cluster` resource | `devopsfaza-cluster` |
| Node instance type | `main.tf` — `instance_types` | `t2.medium` |
| Node count | `main.tf` — `scaling_config` | `3` |
| SSH key pair name | `variable.tf` or `-var ssh_key_name=<name>` | `DevOps-Faza` |
| IAM role names | `main.tf` — `aws_iam_role` resources | `devopsfaza-cluster-role`, `devopsfaza-node-group-role` |

## Usage

```bash
# 1. Clone and enter the directory
git clone <repo-url>
cd <repo-dir>

# 2. Edit variables as needed (or pass them at runtime)
# At minimum, set ssh_key_name to a key pair that exists in your AWS account

# 3. Initialize Terraform
terraform init

# 4. Preview the changes
terraform plan -var="ssh_key_name=<your-key-pair>"

# 5. Apply
terraform apply -var="ssh_key_name=<your-key-pair>"

# 6. Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name devopsfaza-cluster
kubectl get nodes
```

To tear everything down:

```bash
terraform destroy -var="ssh_key_name=<your-key-pair>"
```

## RBAC setup

After the cluster is up, apply the Jenkins ServiceAccount RBAC config from `RBAC/rbac.md`:

```bash
kubectl apply -f <rbac-yaml>
```

See `RBAC/rbac.md` for the full YAML and namespace details.

## State

State is stored locally by default. For team use, add an S3 + DynamoDB backend block to `main.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "<your-bucket>"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "<your-lock-table>"
  }
}
```
