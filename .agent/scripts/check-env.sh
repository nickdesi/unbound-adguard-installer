#!/bin/bash

# check-env.sh
# Checks if the environment is ready for Antigravity Workflows

echo "🔍 Checking Antigravity Environment..."
echo "-----------------------------------"

# Check Node.js
if command -v node &> /dev/null; then
    NODE_VERSION=$(node -v)
    echo "✅ Node.js: $NODE_VERSION"
else
    echo "❌ Node.js: Not found (Required for frontend workflows)"
fi

# Check Python
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version)
    echo "✅ Python: $PYTHON_VERSION"
else
    echo "❌ Python: Not found (Required for testing/scripting)"
fi

# Check Git
if command -v git &> /dev/null; then
    GIT_VERSION=$(git --version)
    echo "✅ Git: $GIT_VERSION"
else
    echo "❌ Git: Not found (Required)"
fi

# Check Playwright (Optional but recommended)
if pip3 show playwright &> /dev/null; then
    echo "✅ Playwright (Python): Installed"
else
    echo "⚠️  Playwright (Python): Not found (Install for webapp-testing)"
fi

echo "-----------------------------------"
if command -v node &> /dev/null && command -v python3 &> /dev/null && command -v git &> /dev/null; then
    echo "🚀 Good to go! Your environment is ready."
else
    echo "⚠️  Some dependencies are missing. Please install them."
fi
