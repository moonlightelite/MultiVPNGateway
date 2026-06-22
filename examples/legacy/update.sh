#!/bin/bash

#nordvpn login --legacy
apt -y update
apt -y upgrade
nordvpn set technology nordlynx

nordvpn connect Taiwan
sleep 2
sudo wg show && sudo wg showconf nordlynx > /etc/wireguard/wg0.conf
sleep 2
nordvpn disconnect
sleep 2

nordvpn connect Singapore
sleep 2
sudo wg show && sudo wg showconf nordlynx > /etc/wireguard/wg1.conf
sleep 2
nordvpn disconnect
sleep 2

nordvpn connect Netherlands
sleep 2
sudo wg show && sudo wg showconf nordlynx > /etc/wireguard/wg2.conf
sleep 2
nordvpn disconnect
sleep 2

nordvpn connect United_States
sleep 2
sudo wg show && sudo wg showconf nordlynx > /etc/wireguard/wg3.conf
sleep 2
nordvpn disconnect
sleep 2

nordvpn connect Japan
sleep 2
sudo wg show && sudo wg showconf nordlynx > /etc/wireguard/wg4.conf
sleep 2
nordvpn disconnect
sleep 2

#reboot now
