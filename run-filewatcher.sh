#!/bin/bash

export IMAGE_REPO=public.ecr.aws/d3a2n4s9/zscaler-file-watcher-svc

echo -n "Enter the name of existing sftp folder else press Enter to create new folder [zscaler-files]: "
read sftp_folder_name

# Default to envfile.txt if not provided
export sftp_folder_name=${sftp_folder_name:-zscaler-files}

if [ -d "$sftp_folder_name" ]; then
    echo "Using existing folder: $sftp_folder_name"
else
    echo "No existing folder found. Creating new folder: $sftp_folder_name"
    mkdir -p $sftp_folder_name
fi

get_value_from_file() {
  local file=$1
  local key=$2
  if [ -f "$file" ]; then
    grep -w "$key" "$file" | awk -F'=' '{print $2}'
  else
    echo ""
  fi
}

update_config_file() {
  local file=$1
  local key=$2
  local value=$3
  if grep "^$key=" "$file" > /dev/null 2>&1; then
    sed -i "s/^$key=.*/$key=$value/" "$file"
  else
    echo "$key=$value" >> "$file"
  fi
}

create_envfile() {
echo -n "Enter the name of existing envfile else press Enter to create new file [envfile.txt]: "
read env_file_name

# Default to envfile.txt if not provided
export env_file_name=${env_file_name:-envfile.txt}

if [ -f "$env_file_name" ]; then
    echo "Using existing env file: $env_file_name"
else
    echo "No existing file found. Creating a new env file: $env_file_name"
    touch "$env_file_name"
fi

# Filewatcher variables to configure
configs=(
  "container_name_prefix"
  "AZURE_CLIENT_ID"
  "AZURE_CLIENT_SECRET"
  "AZURE_TENANT_ID"
  "image_version"
  "source_folder"
  "file_processor_thread_pool_size"
  "file_process_wait_time_in_millis"
  "delete_folders_older_than"
  "health_check_interval_in_sec"
)

hostConfigs=("system_uid" "host_ip_address")

for config in "${configs[@]}"; do
  current_value=''
  new_value=''
  current_value=$(get_value_from_file "$env_file_name" "$config")

  case $config in
        'AZURE_CLIENT_SECRET')
            if [ -n "$current_value" ]; then
              obfuscated_value="****"
            fi
            ;;
        'file_processor_thread_pool_size')
            if [ -z "$current_value" ]; then
              current_value="8"
              update_config_file "$env_file_name" "$config" "$current_value"
            fi
            ;;
        'file_process_wait_time_in_millis')
            if [ -z "$current_value" ]; then
              current_value="5000"
              update_config_file "$env_file_name" "$config" "$current_value"
            fi
            ;;
        'delete_folders_older_than')
            if [ -z "$current_value" ]; then
              current_value="7"
              update_config_file "$env_file_name" "$config" "$current_value"
            fi
            ;;
        'health_check_interval_in_sec')
            if [ -z "$current_value" ]; then
              current_value="300"
              update_config_file "$env_file_name" "$config" "$current_value"
            fi
            ;;
        'source_folder')
            if [ -z "$current_value" ]; then
              current_value="/var/data"
              update_config_file "$env_file_name" "$config" "$current_value"
            fi
            ;;
        *)
            ;;
    esac
  
  # Prompt user for the value, showing the current one or [None]
    while [ -z "$new_value" ]; do
      if [ "$config" == "AZURE_CLIENT_SECRET" ]; then
        echo -n "Enter the value for $config [${obfuscated_value}]: "
        read -s new_value
	echo
      else
        echo -n "Enter the value for $config [${current_value}]: "
        read new_value
      fi

     if [ -z "$new_value" ] && [ -z "$current_value" ]; then
        echo
        echo "Value for $config cannot be empty. Please provide a valid value."
    else
	break 
     fi
    done
    # Update the value if the user provided a new one
    if [ -n "$new_value" ]; then
      export new_container=yes
      update_config_file "$env_file_name" "$config" "$new_value"
    fi
done

for config in "${hostConfigs[@]}"; do
    current_value=$(get_value_from_file "$env_file_name" "$config")
    
    case $config in
        'host_ip_address')
            update_config_file "$env_file_name" "$config" "$(hostname -I | awk '{print $1}')"
            ;;
        'system_uid')
            if [ -z "$current_value" ]; then
                update_config_file "$env_file_name" "$config" "$(cat /proc/sys/kernel/random/uuid)"
            fi
            ;;
        *)
            echo "Unknown config: $config"
            ;;
    esac
done

echo "Configuration complete."
echo -e "\n"

}



run_container() {
    echo "=================================="
    echo "Starting new container"
    fw_name=file-watcher-$(date +%s)
    if [ "$tool" == "docker" ]; then
        container_id=$(docker run -d --restart=always \
        --name $fw_name \
        --env-file  $env_file_name -u $(id -u):$(id -g)  \
        -v `pwd`/${sftp_folder_name}:$source_folder \
        $IMAGE_REPO:$image_version)
    elif [ "$tool" == "podman" ]; then
        container_id=$(podman run -d --restart=always \
        --name $fw_name \
        --env-file $env_file_name --userns=keep-id \
        -v `pwd`/${sftp_folder_name}:$source_folder:z -u $(id -u):$(id -g)  \
        $IMAGE_REPO:$image_version)
	mkdir -p ~/.config/systemd/user/  
        podman generate systemd --new --name ${fw_name}  > ~/.config/systemd/user/${fw_name}.service    
        systemctl --user daemon-reload 
        systemctl --user start ${fw_name}.service	
        systemctl --user enable ${fw_name}.service  
        systemctl --user status ${fw_name}.service  
        sudo loginctl enable-linger 
  fi

  if [[ $? -eq 0 ]]; then
    echo
    echo "Container started successfully with ID: $container_id"
    echo "Check logs with: $tool logs $container_id"
  else
    echo "Error starting the container: $container_id"
  fi
}


run_filewatcher() {
echo "======================================"
echo -n "Are you using docker or podman <docker,podman> [docker]:"
read tool
tool=${tool:-docker}
echo
export tool=$tool

image_version=$(get_value_from_file "$env_file_name" "image_version")
source_folder=$(get_value_from_file "$env_file_name" "source_folder")
image_id=$IMAGE_REPO:$image_version

containers=`$tool ps --format "{{.Names}}"`
containers_current_image=`$tool ps --filter "ancestor=$image_id" --format "{{.Names}}"`

if [ -z "$containers" ]; then
    echo "No containers found."
    run_container

else
    echo "No containers found with image provided"
    echo "Removing existing container to start a new container"
    echo
    echo "========================================"
    echo -n "containers running on host"
    echo
    echo "========================================"
    $tool ps
    
    echo "========================================"
    echo -n "Enter the name of the container to stop: "
    read container_name
    echo ''
    echo "Stopping existing running container"
    $tool stop "$container_name"
    stop_status=$?
    echo $stop_status
    echo ''
    if [ "$tool" == "podman" ]; then
        systemctl --user stop $container_name.service || true
    fi
    echo "========================================"
    echo -n "Do you want to remove the container(Optional)? [y/N]: "
    read remove
    if [[ "$remove" == "y" || "$remove" == "Y" ]]; then
        $tool rm "$container_name" || true
        rm -f ~/.config/systemd/user/$container_name.service || true
    fi
    
    if [[ $stop_status -eq 0 ]]; then
        echo "Container $container_name has been stopped."
        run_container 
    else
        echo "Error in stopping container. Pls check and execute script again"
        exit 1
    fi
    
fi

}


create_envfile
run_filewatcher

