#!/bin/bash
# Bash script to quickly install, set up, and start Pepper

echo "Installing the needed system packages"

sudo apt install build-essential cpanminus libmysqlclient-dev perl-doc zlib1g-dev apache2 apache2-utils

echo "Installing Pepper"

sudo cpanm Pepper

echo "Setting up Pepper - Please answer carefully"

sudo pepper setup

echo "Starting Pepper"
pepper start

echo "Pepper now running at http://127.0.0.1:5000"