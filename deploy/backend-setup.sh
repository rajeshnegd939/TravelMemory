#!/bin/bash
# Backend setup on a fresh Ubuntu EC2 instance
# Usage: bash backend-setup.sh
# Create backend/.env BEFORE running pm2 (see backend/.env.example)
set -e

sudo apt update
sudo apt install -y nginx git

# Node.js 20 + pm2
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2

# code
cd ~
[ -d TravelMemory ] || git clone https://github.com/rajeshnegd939/TravelMemory.git
cd TravelMemory/backend
npm ci --omit=dev

# nginx reverse proxy
sudo cp ~/TravelMemory/deploy/nginx-backend.conf /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

if [ ! -f .env ]; then
  echo ">>> backend/.env not found. Create it, then run:"
  echo "    cd ~/TravelMemory/backend && pm2 start index.js --name tm-backend && pm2 save"
  exit 0
fi

pm2 start index.js --name tm-backend
pm2 save
echo ">>> Done. Run the 'pm2 startup' command printed below so the app starts on reboot:"
pm2 startup
