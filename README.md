# 🏡 Minimal Home Server

**A lightweight and minimal home server** built using 🐧 **Alpine Linux**, 🐳 **Docker**, 🔒 **Iptables**, 💾 **OpenZFS**, and 📁 **SMB (Samba)**. Designed for simplicity, low resource usage, and maintainability.

---

## 🔧 Technologies Used

- **Alpine Linux** – Minimal base OS
- **Docker** – Containerized service deployment
- **OpenZFS** – Reliable, advanced filesystem with snapshot and compression support
- **Iptables** – Secure firewall rules
- **Samba (SMB)** – File sharing across devices
- **Whoogle** – Self-hosted, ad-free Google search proxy (via `whoogle.env`)

---

## 📁 Project Structure

home-server/

- iptables/ # Firewall rules

-  samba/ # Samba configuration

- script.sh # Setup or automation script

- whoogle.env # Env vars for Whoogle container

-  README.md # This file


---

## 🚀 Getting Started

1. **Clone the repo:**

```bash
git clone https://github.com/400hoops/home-server.git
cd home-server
```

2. **Review and run the setup script:**

```bash
chmod +x script.sh
./script.sh
```
    Load firewall rules (example):

sudo iptables-restore < iptables/rules.v4

    Configure Samba:

sudo cp samba/smb.conf /etc/samba/smb.conf
sudo systemctl restart smbd

    Use whoogle.env with your Docker Compose or container config to run Whoogle privately.

## 📌 Features

- 🔐 Secure by default (iptables preconfigured)

- 🐳 Docker-ready service isolation

- 💾 ZFS-native storage support

- 📤 Fast SMB file sharing

- 🕵️‍♂️ Private search via Whoogle

- ⚡ Runs on minimal resources

## 📄 License

This project is licensed under the MIT License. See the LICENSE file for details.
🙌 Acknowledgments

- Alpine Linux

- OpenZFS

- Docker

- Whoogle
