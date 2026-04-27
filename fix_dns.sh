#!/bin/bash
ssh -o ControlPath=/tmp/ssh-ubuntu@104.239.169.89:22 ubuntu@104.239.169.89 "sudo rm -f /etc/resolv.conf && echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
