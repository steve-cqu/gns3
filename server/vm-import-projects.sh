#!/bin/bash
# Import GNS3 projects
# Usage: ./vm-import-projects.sh <project-list>
# Example: ./vm-import-projects.sh projects.txt
# The project list file should contain one project name per line, e.g.
#   GNS-Intro-Solution
#   GNS3-Advanced-Solution

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <project-list>"
    exit 1
fi

PROJECT_DIR="/home/gns3/projects"

PROJECT_LIST=$1

if [ ! -f "$PROJECT_LIST" ]; then
    echo "Project list file '$PROJECT_LIST' not found!"
    exit 1
fi

# Loop through each project name in the list
while IFS= read -r PROJECT_NAME; do
    if [ -z "$PROJECT_NAME" ]; then
        continue
    fi

    echo "Importing project: $PROJECT_NAME"

    # Unzip project file to temp directory
    TEMP_DIR=$(mktemp -d)
    cp "$PROJECT_DIR/$PROJECT_NAME.gns3project" "$PROJECT_DIR/$PROJECT_NAME.zip"
    unzip -q "$PROJECT_DIR/$PROJECT_NAME.zip" -d "$TEMP_DIR"
    rm "$PROJECT_DIR/$PROJECT_NAME.zip"

    # The .gns3 file is now in $TEMP_DIR and contains a "project_id" field. Grab the value of the field.
    # File format:
    # "project_id": "some-uuid",
    PROJECT_ID=$(grep -oP '"project_id": "\K[^"]+' "$TEMP_DIR/project.gns3")
    
    # Do not process project if project_id already exists in /opt/gns3/projects
    if [ -d "/opt/gns3/projects/$PROJECT_ID" ]; then
        echo "Project '$PROJECT_NAME' with ID '$PROJECT_ID' already exists. Skipping."
        rm -rf "$TEMP_DIR"
        continue
    fi

    # Import the project using the GNS3 API with curl
    curl -X POST http://localhost/v2/projects/$PROJECT_ID/import --data-binary @$PROJECT_DIR/$PROJECT_NAME.gns3project
    if [ $? -ne 0 ]; then
        echo "Failed to import project '$PROJECT_NAME' via API."
        rm -rf "$TEMP_DIR"
        continue
    fi

    rm -rf "$TEMP_DIR"

done < "$PROJECT_LIST"
