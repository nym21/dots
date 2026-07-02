# Reduce delayed ACK (helps cloudflared↔brk + bitcoind p2p)
sudo sysctl -w net.inet.tcp.delayed_ack=0

# Increase listen backlog (bitcoind accepts inbound peers)
sudo sysctl -w kern.ipc.somaxconn=2048

# Detect dead connections (bitcoind peers, screen sharing)
sudo sysctl -w net.inet.tcp.always_keepalive=1

# Cloudflare DNS
sudo networksetup -setdnsservers Ethernet 1.1.1.1 1.0.0.1

# Disable Spotlight
sudo mdutil -a -i off

# Never sleep
sudo pmset -a sleep 0 disksleep 0 powernap 0
