#!/bin/bash
set -xe

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root: sudo $0"
    exit 1
fi

# Define OpenVPN port and protocol
OVPN_PORT=${1:-1194}
OVPN_PROTO=${2:-udp}  # Default to UDP, can be changed to TCP

# Stop OpenVPN if running
systemctl stop openvpn@server || true

# Uninstall OpenVPN if previously installed
apt remove --purge -y openvpn easy-rsa || true
rm -rf /etc/openvpn /etc/openvpn/* /etc/openvpn/easy-rsa

# Install required packages
apt update && apt upgrade -y
apt install -y openvpn easy-rsa iptables-persistent curl ipset

# Define variables
EASYRSA_DIR="/etc/openvpn/easy-rsa"
OVPN_DIR="/etc/openvpn"
CLIENT_CONFIG="$HOME/client.ovpn"

# Remove old client config before regenerating if its present
rm -f "$CLIENT_CONFIG"

# Set up EasyRSA
make-cadir "$EASYRSA_DIR"
cd "$EASYRSA_DIR"

# Initialize PKI
./easyrsa init-pki
echo -ne '\n' | ./easyrsa build-ca nopass

# Generate server and client keys
./easyrsa gen-req server nopass
./easyrsa sign-req server server <<< "yes"
./easyrsa gen-dh
./easyrsa gen-req client nopass
./easyrsa sign-req client client <<< "yes"
openvpn --genkey --secret ta.key

# Copy server files
cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key "$OVPN_DIR/"

# Create OpenVPN server configuration
cat > "$OVPN_DIR/server.conf" <<EOF
port $OVPN_PORT
proto $OVPN_PROTO
dev tun
ca $OVPN_DIR/ca.crt
cert $OVPN_DIR/server.crt
key $OVPN_DIR/server.key
dh $OVPN_DIR/dh.pem
tls-auth $OVPN_DIR/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-CBC
auth SHA256
persist-key
persist-tun
verb 3
duplicate-cn
EOF

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl --system

# Get primary network interface
PRIMARY_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

# Flush old firewall rules
iptables -F
iptables -t nat -F
iptables -X
ipset destroy || true  # Destroy existing ipsets if they exist

# Create ipset collections for torrent blocking
ipset create torrent_ports bitmap:port range 0-65535 timeout 0
ipset create torrent_ips hash:ip timeout 86400

# Block common torrent ports
for port in 6881 6889 6969 1337 51413 45000 65000 32400; do
    ipset add torrent_ports $port
done

# Block known P2P-related IP ranges
for subnet in 109.121.134.0/24 212.129.118.0/24 91.216.110.0/24; do
    ipset add torrent_ips $subnet
done

# NAT for OpenVPN
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$PRIMARY_IF" -j MASQUERADE

# Allow VPN traffic
iptables -A INPUT -p $OVPN_PROTO --dport $OVPN_PORT -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow HTTP, HTTPS, and DNS
iptables -A FORWARD -i tun0 -p tcp --dport 80 -j ACCEPT
iptables -A FORWARD -i tun0 -p tcp --dport 443 -j ACCEPT
iptables -A FORWARD -i tun0 -p udp --dport 53 -j ACCEPT

# Allow VoIP and messaging apps (Skype, Zoom, WhatsApp)
for port in 3478 3479 3480 19302 19303 19304 34783 49152 49153 49154 49155; do
    iptables -A FORWARD -i tun0 -p udp --dport $port -j ACCEPT
done

# Block torrent traffic
iptables -A FORWARD -i tun0 -m set --match-set torrent_ports dst -j REJECT
iptables -A FORWARD -i tun0 -m set --match-set torrent_ips dst -j REJECT
iptables -A FORWARD -i tun0 -m string --algo bm --string "BitTorrent" -j REJECT
iptables -A FORWARD -i tun0 -m string --algo bm --string "peer_id=" -j REJECT

# Block all other UDP traffic
iptables -A FORWARD -i tun0 -p udp -j REJECT

# Save firewall rules
ipset save > /etc/iptables/ipset.rules
iptables-save > /etc/iptables/rules.v4
systemctl enable netfilter-persistent

# Start OpenVPN
systemctl enable openvpn@server
systemctl restart openvpn@server

# cd ~/
# touch $CLIENT_CONFIG

# Generate client configuration
cat > "$CLIENT_CONFIG" <<EOF
client
dev tun
proto $OVPN_PROTO
remote $(curl -s ifconfig.me) $OVPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-CBC
verb 3

<ca>
$(cat "$OVPN_DIR/ca.crt")
</ca>

<cert>
$(cat "$EASYRSA_DIR/pki/issued/client.crt")
</cert>

<key>
$(cat "$EASYRSA_DIR/pki/private/client.key")
</key>

<tls-auth>
$(cat "$OVPN_DIR/ta.key")
</tls-auth>
key-direction 1
EOF

# Copy client config to home directory
# cp "$CLIENT_CONFIG" ~/client.ovpn

echo "OpenVPN setup complete!"
echo "Client config saved at ~/client.ovpn"
