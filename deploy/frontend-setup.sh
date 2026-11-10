#!/bin/bash
# Frontend setup on a fresh Ubuntu EC2 instance
# Usage: bash frontend-setup.sh https://travel.yourdomain.com
set -e

BACKEND_URL="$1"
if [ -z "$BACKEND_URL" ]; then
  echo "Usage: bash frontend-setup.sh <backend-url>"
  exit 1
fi

sudo apt update
sudo apt install -y nginx git

curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# React build needs more RAM than a t2.micro has, so add 2 GB swap
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
fi

cd ~
[ -d TravelMemory ] || git clone https://github.com/rajeshnegd939/TravelMemory.git
cd TravelMemory/frontend

# url.js reads this value at build time
echo "REACT_APP_BACKEND_URL=$BACKEND_URL" > .env
npm ci
npm run build

sudo mkdir -p /var/www/travelmemory
sudo rm -rf /var/www/travelmemory/*
sudo cp -r build/* /var/www/travelmemory/

sudo cp ~/TravelMemory/deploy/nginx-frontend.conf /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx
echo ">>> Frontend is live on port 80"
