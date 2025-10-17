git clone https://github.com/SpecterOps/BloodHound.git
cd BloodHound/examples/docker-compose
cp docker-compose.yml docker-compose.bak
cp .env.example .env
sed -i 's/BLOODHOUND_HOST=127.0.0.1/BLOODHOUND_HOST=0.0.0.0/' .env
sudo docker compose up 
