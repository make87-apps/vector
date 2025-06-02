#!/bin/sh
set -e

mkdir -p /etc/vector
: > /etc/vector/vector.toml  # clear or create the config file

# Extract app name for labeling
app_name=$(echo "$MAKE87_CONFIG" | jq -r '.application_info.deployed_application_name // empty')

# Build source list (array of names)
source_names=()

# Extract sources
has_sources=$(echo "$MAKE87_CONFIG" | jq -e '.config.sources | length > 0' 2>/dev/null || echo false)

if [ "$has_sources" = "true" ]; then
  echo "$MAKE87_CONFIG" | jq -c '.config.sources[]' | while read -r source; do
    name=$(echo "$source" | jq -r '.name')
    type=$(echo "$source" | jq -r '.type')

    echo "" >> /etc/vector/vector.toml
    echo "[sources.${name}]" >> /etc/vector/vector.toml
    echo "type = \"${type}\"" >> /etc/vector/vector.toml

    # Collect source name
    source_names+=("$name")

    # Copy additional fields
    echo "$source" | jq 'del(.name, .type)' | jq -r "to_entries[] | \"\(.key) = \(.value | @json)\"" >> /etc/vector/vector.toml
  done
else
  # Write fallback stdin source
  echo "" >> /etc/vector/vector.toml
  echo "[sources.stdin]" >> /etc/vector/vector.toml
  echo "type = \"stdin\"" >> /etc/vector/vector.toml
  source_names+=("stdin")
fi

# Choose first available source as default input fallback
default_input=${source_names[0]}

# Write sinks from interfaces
echo "$MAKE87_CONFIG" | jq -c '.interfaces | to_entries[]' | while read -r iface_entry; do
  iface=$(echo "$iface_entry" | jq -c '.value')
  iface_name=$(echo "$iface_entry" | jq -r '.key')

  echo "$iface" | jq -c '.clients | to_entries[]' | while read -r client_entry; do
    name=$(echo "$client_entry" | jq -r '.key')
    client=$(echo "$client_entry" | jq -c '.value')

    use_public=$(echo "$client" | jq -r '.use_public_ip // false')
    if [ "$use_public" = "true" ]; then
      host=$(echo "$client" | jq -r '.public_ip')
      port=$(echo "$client" | jq -r '.public_port')
    else
      host=$(echo "$client" | jq -r '.vpn_ip')
      port=$(echo "$client" | jq -r '.vpn_port')
    fi

    type=$(echo "$client" | jq -r '.sink_type')

    echo "" >> /etc/vector/vector.toml
    echo "[sinks.${iface_name}_${name}]" >> /etc/vector/vector.toml
    echo "type = \"${type}\"" >> /etc/vector/vector.toml
    echo "endpoint = \"${host}:${port}\"" >> /etc/vector/vector.toml

    # Get and validate inputs
    inputs=$(echo "$client" | jq -c '.inputs // empty')
    valid_inputs=()

    if [ "$inputs" != "null" ] && [ "$inputs" != "" ]; then
      for input in $(echo "$inputs" | jq -r '.[]'); do
        for known in "${source_names[@]}"; do
          if [ "$input" = "$known" ]; then
            valid_inputs+=("\"$input\"")
          fi
        done
      done
    fi

    # Fallback to stdin if no valid inputs
    if [ "${#valid_inputs[@]}" -eq 0 ]; then
      valid_inputs+=("\"$default_input\"")
    fi

    echo "inputs = [$(IFS=,; echo "${valid_inputs[*]}")]" >> /etc/vector/vector.toml

    # Loki labels
    if [ "$type" = "loki" ]; then
      echo "[sinks.${iface_name}_${name}.labels]" >> /etc/vector/vector.toml
      echo "app = \"${app_name}\"" >> /etc/vector/vector.toml
    fi

    # Optional nested config fields
    for key in encoding mode method compression namespace; do
      value=$(echo "$client" | jq -c --arg k "$key" 'if has($k) then .[$k] else null end')
      if [ "$value" != "null" ]; then
        if echo "$value" | grep -q '^{'; then
          echo "[sinks.${iface_name}_${name}.${key}]" >> /etc/vector/vector.toml
          echo "$value" | jq -r 'to_entries[] | .key + " = \"" + .value + "\"" ' >> /etc/vector/vector.toml
        else
          echo "$key = $value" >> /etc/vector/vector.toml
        fi
      fi
    done
  done
done

exec vector --config /etc/vector/vector.toml
