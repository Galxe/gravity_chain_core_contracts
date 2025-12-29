#!/bin/bash

# Cleanup script to remove demo files from specific directories
# This script cleans up demo files while preserving folder structure

set -e  # Exit on any error

echo "Starting cleanup process..."

# Function to check if directory exists before cleaning
cleanup_directory() {
    local dir="$1"
    local preserve_folders="$2"
    
    if [ -d "$dir" ]; then
        echo "  Cleaning: $dir"
        if [ "$preserve_folders" = "true" ]; then
            # Remove files and symbolic links but preserve folders
            find "$dir" -type f -delete
            find "$dir" -type l -delete
        else
            # Remove everything
            rm -rf "$dir"/*
        fi
    else
        echo "  Directory $dir does not exist, skipping..."
    fi
}

echo "Cleaning src/ directory..."
cleanup_directory "src" "false"

echo "Cleaning test directories..."
cleanup_directory "test/unit" "true"
cleanup_directory "test/fuzz" "true"
cleanup_directory "test/invariant" "true"

echo "Cleaning audit/ directory..."
cleanup_directory "audit" "true"

echo "Cleaning script/releases/ directory (preserving README.md)..."
if [ -d "script/releases" ]; then
    echo "  Cleaning: script/releases"
    # Create a temporary directory to store README.md
    if [ -f "script/releases/README.md" ]; then
        cp "script/releases/README.md" "/tmp/releases_readme_backup.md"
    fi
    # Remove everything in releases
    rm -rf script/releases/*
    # Restore README.md if it existed
    if [ -f "/tmp/releases_readme_backup.md" ]; then
        cp "/tmp/releases_readme_backup.md" "script/releases/README.md"
        rm "/tmp/releases_readme_backup.md"
    fi
else
    echo "  Directory script/releases does not exist, skipping..."
fi

echo "Cleanup completed successfully!"