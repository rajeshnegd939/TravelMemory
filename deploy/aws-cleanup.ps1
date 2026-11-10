# TravelMemory - delete every AWS resource created by aws-setup.ps1
# Run: powershell -ExecutionPolicy Bypass -File deploy\aws-cleanup.ps1

$env:AWS_DEFAULT_REGION = "ap-south-1"

$confirm = Read-Host "This deletes the TravelMemory load balancer, servers, IPs and security groups. Type DELETE to continue"
if ($confirm -ne "DELETE") { Write-Host "Cancelled."; exit }

Write-Host "Load balancer..."
$alb = aws elbv2 describe-load-balancers --names tm-alb --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null
if ($LASTEXITCODE -eq 0 -and $alb -and $alb -ne "None") {
    aws elbv2 delete-load-balancer --load-balancer-arn $alb
    aws elbv2 wait load-balancers-deleted --load-balancer-arns $alb
}

Write-Host "Target groups..."
foreach ($tg in "tm-backend-tg", "tm-frontend-tg") {
    $arn = aws elbv2 describe-target-groups --names $tg --query "TargetGroups[0].TargetGroupArn" --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and $arn -and $arn -ne "None") { aws elbv2 delete-target-group --target-group-arn $arn }
}

Write-Host "Elastic IP..."
$eips = aws ec2 describe-addresses --filters Name=tag:Project,Values=TravelMemory --query "Addresses[].[AllocationId,AssociationId]" --output text
foreach ($line in ($eips -split "`n" | Where-Object { $_.Trim() })) {
    $parts = $line -split "\s+"
    if ($parts[1] -and $parts[1] -ne "None") { aws ec2 disassociate-address --association-id $parts[1] }
    aws ec2 release-address --allocation-id $parts[0]
}

Write-Host "EC2 instances..."
$ids = aws ec2 describe-instances --filters Name=tag:Project,Values=TravelMemory `
       Name=instance-state-name,Values=pending,running,stopping,stopped --query "Reservations[].Instances[].InstanceId" --output text
if ($ids) {
    $idList = $ids -split "\s+" | Where-Object { $_ }
    aws ec2 terminate-instances --instance-ids $idList | Out-Null
    aws ec2 wait instance-terminated --instance-ids $idList
}

Write-Host "Security groups..."
foreach ($sg in "app-sg", "fe-public-sg", "alb-sg") {
    $id = aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg" --query "SecurityGroups[0].GroupId" --output text
    if ($id -and $id -ne "None") { aws ec2 delete-security-group --group-id $id }
}

Write-Host "Key pair..."
aws ec2 delete-key-pair --key-name travel-key | Out-Null
Remove-Item (Join-Path $HOME ".ssh\travel-key.pem") -Force -ErrorAction SilentlyContinue

Write-Host "All TravelMemory resources deleted." -ForegroundColor Green
