#!/usr/bin/env bash
clear
echo "==============================="
echo " Solvionyx Recovery Environment"
echo "==============================="
echo "1) Restore System (Cloud Restore)"
echo "2) Repair Bootloader"
echo "3) Check Disk Health"
echo "4) Network Repair"
echo "5) Exit"
read -p "Choose: " CH

case $CH in
1) /usr/share/solvionyx-tools/cloud_restore.sh ;;
2) grub-install /dev/sda ;;
3) smartctl -a /dev/sda ;;
4) nmcli networking off && nmcli networking on ;;
esac
