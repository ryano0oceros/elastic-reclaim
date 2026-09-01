output "ecr_repository_url" {
  description = "Push the proxy image here before the ECS service can start tasks."
  value       = aws_ecr_repository.proxy.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.proxy.name
}

output "cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.proxy.name
}

output "security_group_id" {
  value = aws_security_group.proxy.id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "alb_dns_name" {
  description = "Stable hostname for the proxy - survives deployments, unlike task IPs."
  value       = aws_lb.proxy.dns_name
}

output "task_public_ip_command" {
  description = "Debugging only: AWS CLI one-liner for the current task's public IP. Port 8000 is no longer internet-reachable directly - use the ALB."
  value       = "aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name ${aws_ecs_service.proxy.name} --query 'taskArns[0]' --output text | xargs -I{} aws ecs describe-tasks --cluster ${aws_ecs_cluster.this.name} --tasks {} --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}
