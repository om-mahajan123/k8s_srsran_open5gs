mkdir /dev/net
mknod /dev/net/tun c 10 200

ip netns add ue0

while true; do sleep 30; done;
