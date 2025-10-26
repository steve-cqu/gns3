#!/bin/sh
# GitHub setup script — runs as 'student' even if started by root

STUDENT_USER="student"
STUDENT_HOME="/home/$STUDENT_USER"

# If running as root, switch to student and re-run the script
if [ "$(id -u)" -eq 0 ]; then
    echo "Running as root — switching to user '$STUDENT_USER'..."
    exec su - "$STUDENT_USER" -c "/bin/setup-github.sh"
fi

# --- Now running as 'student' ---
echo "=== GitHub Setup Script (as $USER) ==="
echo "This will configure Git for your GitHub account using a Personal Access Token (PAT)."
echo

# Prompt for GitHub info
read -p "Enter your GitHub username: " GH_USER
read -s -p "Enter your GitHub Personal Access Token: " GH_TOKEN
echo
read -p "Enter your GitHub repository name (e.g. coit12345-journal): " GH_REPO

# Configure git for this user
git config --global user.name "$GH_USER"
git config --global user.email "$GH_USER@users.noreply.github.com"

# Store credentials in student's home (plaintext, for simplicity)
git config --global credential.helper store
echo "https://$GH_USER:$GH_TOKEN@github.com" > "$STUDENT_HOME/.git-credentials"
chmod 600 "$STUDENT_HOME/.git-credentials"

# Prepare repo folder
mkdir -p "$STUDENT_HOME/git"
cd "$STUDENT_HOME/git" || exit 1

# Clone the repo
echo "Cloning your repository..."
git clone "https://github.com/$GH_USER/$GH_REPO.git" "$STUDENT_HOME/git/$GH_REPO"

if [ $? -eq 0 ]; then
    echo "✅ Repository cloned successfully!"
    echo "You can find it at: $STUDENT_HOME/git/$GH_REPO"
else
    echo "❌ Failed to clone repository. Check your token or repo name."
    echo "The URL used was: https://github.com/$GH_USER/$GH_REPO.git"
    echo "You can reset GitHub credentials using /bin/reset-github.sh"
fi