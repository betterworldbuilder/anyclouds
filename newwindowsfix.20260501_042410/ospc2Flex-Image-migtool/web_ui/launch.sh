#!/usr/bin/env bash

# Ensure we are in the correct directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR" || exit 1

# Make sure all node processes associated with this app are killed
echo "Stopping any existing web ui processes..."
pkill -f "node server.cjs" || echo "No existing backend server running."

if [ ! -d "node_modules" ]; then
    echo "Installing Node.js dependencies..."
    npm install
fi

echo "Starting Vite Frontend and Express Backend..."
# We use concurrently via npx to run both smoothly in one terminal
npx concurrently -n "api,ui" -c "bgBlue.bold,bgMagenta.bold" \
  "node server.cjs" \
  "npm run dev -- --port 8080 --host 0.0.0.0"
