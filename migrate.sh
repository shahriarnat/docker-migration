#!/bin/bash

# Prompt for confirmation of SCP password and destination path
read -p "Enter the destination server username: " USER
read -p "Enter the destination server address: " SERVER
read -p "Enter the destination path on the new server: " DEST_PATH

# Verify SCP connectivity
ssh "$USER@$SERVER" "mkdir -p $DEST_PATH" || { echo "Error: Unable to connect to the destination server."; exit 1; }

# Ensure Docker is running
if ! command -v docker &>/dev/null; then
  echo "Error: Docker is not installed on this system."
  exit 1
fi

# Create directories to store backups
BACKUP_DIR="docker_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR/{containers,volumes,images}"

# Export containers
echo "Exporting containers..."
CONTAINERS=$(docker ps -a -q)
if [ -z "$CONTAINERS" ]; then
  echo "No containers to export."
else
  for CONTAINER in $CONTAINERS; do
    NAME=$(docker inspect --format='{{.Name}}' $CONTAINER | sed 's/\///')
    docker export "$CONTAINER" -o "$BACKUP_DIR/containers/$NAME.tar"
    echo "Exported $NAME."
  done
fi

# Export volumes
echo "Exporting volumes..."
VOLUMES=$(docker volume ls -q)
if [ -z "$VOLUMES" ]; then
  echo "No volumes to export."
else
  for VOLUME in $VOLUMES; do
    tar -cvf "$BACKUP_DIR/volumes/$VOLUME.tar" -C /var/lib/docker/volumes/ "$VOLUME" &>/dev/null
    echo "Exported volume $VOLUME."
  done
fi

# Save images
echo "Saving images..."
IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}")
if [ -z "$IMAGES" ]; then
  echo "No images to save."
else
  for IMAGE in $IMAGES; do
    FILE_NAME=$(echo "$IMAGE" | sed 's/\//_/g' | sed 's/:/_/g')
    docker save "$IMAGE" -o "$BACKUP_DIR/images/$FILE_NAME.tar"
    echo "Saved image $IMAGE."
  done
fi

# SCP transfer
echo "Transferring files to the new server..."
scp -r "$BACKUP_DIR" "$USER@$SERVER:$DEST_PATH" || { echo "Error: Failed to transfer files."; exit 1; }

# SSH commands to import on the new server
echo "Starting import on the new server..."
ssh "$USER@$SERVER" << EOF
  cd "$DEST_PATH/$BACKUP_DIR"

  echo "Importing containers..."
  if [ -d "containers" ]; then
    for FILE in containers/*.tar; do
      NAME=\$(basename "\$FILE" .tar)
      cat "\$FILE" | docker import - \$NAME
      echo "Imported container \$NAME."
    done
  else
    echo "No container backups found."
  fi

  echo "Importing volumes..."
  if [ -d "volumes" ]; then
    for FILE in volumes/*.tar; do
      NAME=\$(basename "\$FILE" .tar)
      tar -xvf "\$FILE" -C /var/lib/docker/volumes/ &>/dev/null
      echo "Imported volume \$NAME."
    done
  else
    echo "No volume backups found."
  fi

  echo "Loading images..."
  if [ -d "images" ]; then
    for FILE in images/*.tar; do
      docker load -i "\$FILE"
      echo "Loaded image from \$FILE."
    done
  else
    echo "No image backups found."
  fi
EOF

# Cleanup
read -p "Do you want to remove the backup files from the old server? (y/n): " CLEANUP
if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
  rm -rf "$BACKUP_DIR"
  echo "Backup files removed."
else
  echo "Backup files retained at $BACKUP_DIR."
fi

echo "Migration completed successfully!"
