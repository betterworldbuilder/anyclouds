#!/usr/bin/env bash

echo "Stopping any existing OSPC2FLEX Web UI processes..."
# Kill any python process running uvicorn for this app
pkill -f "uvicorn app:app" || echo "No previous process found running."

# Ensure we are executing from the web_ui directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR" || exit 1

if [ ! -d "venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv venv
    
    # Check if python3 failed, fallback to python
    if [ $? -ne 0 ]; then
        python -m venv venv
    fi
fi

echo "Activating virtual environment..."
source venv/bin/activate

echo "Installing requirements..."
pip install -r requirements.txt

echo "Starting the API and Web UI on port 8000..."
# Use python (typically works for both python and python3 on Windows git bash/WSL)
python -m uvicorn app:app --port 8000 --host 0.0.0.0
