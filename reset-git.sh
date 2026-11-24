#!/bin/bash

# This will reset current directory to be exactly the same as the remote repository and delete all the changes.
# make sure you save the changes or stash it before you run this

# 1. Download the new commits from the remote without merging them yet
git fetch origin

# 2. Force your server to point directly to the new remote commits
git reset --hard origin/main

# 3. Permanently delete all your local untracked files and folders
git clean -fd

