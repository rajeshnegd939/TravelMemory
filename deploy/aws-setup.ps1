# TravelMemory - AWS infrastructure setup (Windows PowerShell + AWS CLI v2)
#
# Creates: key pair, 3 security groups, 2 backend + 2 frontend EC2 instances,
#          Elastic IP for frontend-1, 2 target groups, Application Load Balancer.
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File deploy\aws-setup.ps1
# Delete everything later: powershell -ExecutionPolicy Bypass -File deploy\aws-cleanup.ps1

$ErrorActionPreference = "Stop"

# ---------- settings ----------
$Region       = "ap-south-1"
$Domain       = "rajeshdevops.in"
$AppHost      = "travel.$Domain"   # CNAME -> load balancer
$FeHost       = "fe.$Domain"       # A record -> frontend-1 Elastic IP
$InstanceType = "t3.micro"
$KeyName      = "travel-key"
$RepoUrl      = "https://github.com/rajeshnegd939/TravelMemory.git"
$Project      = "TravelMemory"
$env:AWS_DEFAULT_REGION = $Region

function Invoke-Aws {
    $out = & aws @args
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $($args -join ' ')" }
    return $out
}

function Write-LfFile($Path, $Text) {
    # Linux needs LF line endings and no BOM
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

$Tags = "Key=Project,Value=$Project"
$TmpDir = Join-Path $env:TEMP "tm-setup"
New-Item -ItemType Directory -Force $TmpDir | Out-Null

# ---------- MongoDB connection string (typed, never stored in the repo) ----------
$secure   = Read-Host "Paste your MongoDB Atlas connection string" -AsSecureString
$MongoUri = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
              [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
if ($MongoUri -notmatch '^mongodb(\+srv)?://') { throw "That does not look like a MongoDB connection string." }

# ---------- network ----------
Write-Host "`n[1/7] Reading default VPC and subnets..." -ForegroundColor Cyan
$VpcId   = Invoke-Aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text
$Subnets = (Invoke-Aws ec2 describe-subnets --filters Name=default-for-az,Values=true `
            --query "sort_by(Subnets,&AvailabilityZone)[].SubnetId" --output text) -split "\s+"
$SubnetA = $Subnets[0]; $SubnetB = $Subnets[1]
$MyIp    = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
$AmiId   = Invoke-Aws ssm get-parameter `
            --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id `
            --query Parameter.Value --output text
Write-Host "VPC $VpcId | subnets $SubnetA, $SubnetB | Ubuntu AMI $AmiId | your IP $MyIp"

# ---------- key pair ----------
Write-Host "`n[2/7] Key pair..." -ForegroundColor Cyan
$KeyFile = Join-Path $HOME ".ssh\$KeyName.pem"
New-Item -ItemType Directory -Force (Split-Path $KeyFile) | Out-Null
$keyMaterial = Invoke-Aws ec2 create-key-pair --key-name $KeyName --key-type rsa `
               --tag-specifications "ResourceType=key-pair,Tags=[{$Tags}]" --query KeyMaterial --output text
Write-LfFile $KeyFile (($keyMaterial -join "`n") + "`n")
icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):R" | Out-Null   # ssh refuses keys others can read
Write-Host "Private key saved to $KeyFile"

# ---------- security groups ----------
Write-Host "`n[3/7] Security groups..." -ForegroundColor Cyan
function New-Sg($Name, $Desc) {
    Invoke-Aws ec2 create-security-group --group-name $Name --description $Desc --vpc-id $VpcId `
        --tag-specifications "ResourceType=security-group,Tags=[{$Tags},{Key=Name,Value=$Name}]" `
        --query GroupId --output text
}
$AlbSg = New-Sg "alb-sg"       "Load balancer - HTTP and HTTPS from the internet"
$AppSg = New-Sg "app-sg"       "App servers - HTTP from the load balancer, SSH from admin IP"
$FeSg  = New-Sg "fe-public-sg" "Frontend-1 direct access for the A record"

Invoke-Aws ec2 authorize-security-group-ingress --group-id $AlbSg --protocol tcp --port 80  --cidr 0.0.0.0/0 | Out-Null
Invoke-Aws ec2 authorize-security-group-ingress --group-id $AlbSg --protocol tcp --port 443 --cidr 0.0.0.0/0 | Out-Null
Invoke-Aws ec2 authorize-security-group-ingress --group-id $AppSg --protocol tcp --port 80  --source-group $AlbSg | Out-Null
Invoke-Aws ec2 authorize-security-group-ingress --group-id $AppSg --protocol tcp --port 22  --cidr "$MyIp/32" | Out-Null
Invoke-Aws ec2 authorize-security-group-ingress --group-id $FeSg  --protocol tcp --port 80  --cidr 0.0.0.0/0 | Out-Null
Write-Host "alb-sg $AlbSg | app-sg $AppSg | fe-public-sg $FeSg"

# ---------- user data (runs once on first boot) ----------
$BackendUserData = @"
#!/bin/bash
export HOME=/root
git clone $RepoUrl /root/TravelMemory
cat > /root/TravelMemory/backend/.env <<'EOF'
MONGO_URI='$MongoUri'
PORT=3000
CORS_ORIGIN=https://$AppHost,https://$FeHost,http://$FeHost
# Cloudflare -> ALB -> nginx
TRUST_PROXY=3
NODE_ENV=production
EOF
chmod 600 /root/TravelMemory/backend/.env
bash /root/TravelMemory/deploy/backend-setup.sh > /var/log/travelmemory-setup.log 2>&1
"@

$FrontendUserData = @"
#!/bin/bash
export HOME=/root
git clone $RepoUrl /root/TravelMemory
bash /root/TravelMemory/deploy/frontend-setup.sh https://$AppHost > /var/log/travelmemory-setup.log 2>&1
"@

$BeUdFile = Join-Path $TmpDir "backend-userdata.sh"
$FeUdFile = Join-Path $TmpDir "frontend-userdata.sh"
Write-LfFile $BeUdFile $BackendUserData
Write-LfFile $FeUdFile $FrontendUserData

# ---------- EC2 instances ----------
Write-Host "`n[4/7] Launching 4 EC2 instances..." -ForegroundColor Cyan
function New-Instance($Name, $SubnetId, $UdFile, [string[]]$SgIds) {
    Invoke-Aws ec2 run-instances --image-id $AmiId --instance-type $InstanceType --key-name $KeyName `
        --subnet-id $SubnetId --security-group-ids $SgIds --associate-public-ip-address `
        --user-data "file://$UdFile" `
        --tag-specifications "ResourceType=instance,Tags=[{$Tags},{Key=Name,Value=$Name}]" `
        --query "Instances[0].InstanceId" --output text
}
try {
    $Be1 = New-Instance "tm-backend-1"  $SubnetA $BeUdFile @($AppSg)
    $Be2 = New-Instance "tm-backend-2"  $SubnetB $BeUdFile @($AppSg)
    $Fe1 = New-Instance "tm-frontend-1" $SubnetA $FeUdFile @($AppSg, $FeSg)
    $Fe2 = New-Instance "tm-frontend-2" $SubnetB $FeUdFile @($AppSg)
} finally {
    Remove-Item $BeUdFile, $FeUdFile -ErrorAction SilentlyContinue   # contains the DB password
}
Write-Host "backend: $Be1, $Be2 | frontend: $Fe1, $Fe2"
Invoke-Aws ec2 wait instance-running --instance-ids $Be1 $Be2 $Fe1 $Fe2

# ---------- Elastic IP for frontend-1 ----------
Write-Host "`n[5/7] Elastic IP for tm-frontend-1..." -ForegroundColor Cyan
$AllocId = Invoke-Aws ec2 allocate-address --domain vpc `
           --tag-specifications "ResourceType=elastic-ip,Tags=[{$Tags},{Key=Name,Value=tm-frontend-1-eip}]" `
           --query AllocationId --output text
Invoke-Aws ec2 associate-address --instance-id $Fe1 --allocation-id $AllocId | Out-Null
$FeEip = Invoke-Aws ec2 describe-addresses --allocation-ids $AllocId --query "Addresses[0].PublicIp" --output text

# ---------- target groups ----------
Write-Host "`n[6/7] Target groups..." -ForegroundColor Cyan
$BeTg = Invoke-Aws elbv2 create-target-group --name tm-backend-tg --protocol HTTP --port 80 --vpc-id $VpcId `
        --health-check-path /health --matcher HttpCode=200 --tags $Tags `
        --query "TargetGroups[0].TargetGroupArn" --output text
$FeTg = Invoke-Aws elbv2 create-target-group --name tm-frontend-tg --protocol HTTP --port 80 --vpc-id $VpcId `
        --health-check-path / --matcher HttpCode=200 --tags $Tags `
        --query "TargetGroups[0].TargetGroupArn" --output text
Invoke-Aws elbv2 register-targets --target-group-arn $BeTg --targets "Id=$Be1" "Id=$Be2" | Out-Null
Invoke-Aws elbv2 register-targets --target-group-arn $FeTg --targets "Id=$Fe1" "Id=$Fe2" | Out-Null

# ---------- load balancer ----------
Write-Host "`n[7/7] Application Load Balancer..." -ForegroundColor Cyan
$AlbArn = Invoke-Aws elbv2 create-load-balancer --name tm-alb --type application --scheme internet-facing `
          --subnets $SubnetA $SubnetB --security-groups $AlbSg --tags $Tags `
          --query "LoadBalancers[0].LoadBalancerArn" --output text
$ListenerArn = Invoke-Aws elbv2 create-listener --load-balancer-arn $AlbArn --protocol HTTP --port 80 `
               --default-actions "Type=forward,TargetGroupArn=$FeTg" `
               --query "Listeners[0].ListenerArn" --output text

# API paths go to the backend, everything else to the frontend
$CondFile = Join-Path $TmpDir "conditions.json"
Write-LfFile $CondFile '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/trip","/trip/*","/uploads/*","/health"]}}]'
Invoke-Aws elbv2 create-rule --listener-arn $ListenerArn --priority 10 `
    --conditions "file://$CondFile" --actions "Type=forward,TargetGroupArn=$BeTg" | Out-Null
Remove-Item $CondFile

Invoke-Aws elbv2 wait load-balancer-available --load-balancer-arns $AlbArn
$AlbDns = Invoke-Aws elbv2 describe-load-balancers --load-balancer-arns $AlbArn `
          --query "LoadBalancers[0].DNSName" --output text

# ---------- summary ----------
Write-Host "`n================ DONE ================" -ForegroundColor Green
Write-Host "Load balancer DNS : $AlbDns"
Write-Host "Frontend-1 EIP    : $FeEip"
Write-Host ""
Write-Host "Cloudflare DNS records to add:"
Write-Host "  CNAME  travel  ->  $AlbDns   (Proxied)"
Write-Host "  A      fe      ->  $FeEip    (Proxied)"
Write-Host "Cloudflare SSL/TLS mode: Flexible"
Write-Host ""
Write-Host "The servers need ~10 minutes to install everything (frontend build is slow)."
Write-Host "Check target health with:"
Write-Host "  aws elbv2 describe-target-health --target-group-arn $BeTg --query `"TargetHealthDescriptions[].[Target.Id,TargetHealth.State]`" --output table"
Write-Host "  aws elbv2 describe-target-health --target-group-arn $FeTg --query `"TargetHealthDescriptions[].[Target.Id,TargetHealth.State]`" --output table"
Write-Host "SSH into a server: ssh -i $KeyFile ubuntu@<public-ip>"
