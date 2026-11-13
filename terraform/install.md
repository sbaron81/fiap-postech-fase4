sudo apt-get update && sudo apt-get install -y gnupg software-properties-common

wget -O- https://apt.releases.hashicorp.com/gpg | \\ngpg --dearmor | \\nsudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null\nwget -O- https://apt.releases.hashicorp.com/gpg | \\ngpg --dearmor | \\nsudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null\nwget -O- https://apt.releases.hashicorp.com/gpg | \\ngpg --dearmor | \\nsudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null\n

gpg --no-default-keyring \\n--keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg \\n--fingerprint\n

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update

sudo apt-get install terraform
