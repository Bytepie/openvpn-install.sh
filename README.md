# openvpn-install.sh
Basic openserver installation with torrent blocking iptable rules

the script accepts two positional arguments. First is port then is protocol. Default values are '1194 udp'

    ./openvpn-install.sh 443 tcp

## Torrent Blocking rules
This is not a complete fail-proof solution but it manages to block some traffic. 

## One Configuration on multiple devices
This configuration uses duplicate-cn setting in the server so that one client configuration can be used across different clients.
As this is not considered best practice and if you want you can remove this from the configuration and restart openvpn server.

    sudo nano /etc/openvpn/server.conf

remove 'duplicate-cn'

save the file. 

then restart the openvpn server.

    sudo systemctl restart openvpn@server
