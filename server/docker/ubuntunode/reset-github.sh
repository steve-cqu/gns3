#!/bin/sh
# Remove GitHub credentials and unset credential helper

STUDENT_USER="student"
STUDENT_HOME="/home/$STUDENT_USER"

# If running as root, switch to student and re-run the script
if [ "$(id -u)" -eq 0 ]; then
    echo "Running as root — switching to user '$STUDENT_USER'..."
    exec su - "$STUDENT_USER" -c "/bin/reset-github.sh"
fi

rm -f "$STUDENT_HOME/.git-credentials"
git config --global --unset credential.helper