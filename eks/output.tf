output "cluster_id" {
  value = aws_eks_cluster.devopsfaza.id
}

output "node_group_id" {
  value = aws_eks_node_group.devopsfaza.id
}

output "vpc_id" {
  value = aws_vpc.devopsfaza_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.devopsfaza_subnet[*].id
}
