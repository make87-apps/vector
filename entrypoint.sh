#!/bin/sh
set -e

mkdir -p /etc/vector
: > /etc/vector/vector.toml  # clear or create the config file

# Write sources from .config.sources
echo "$MAKE87_CONFIG" | jq -c '.config.sources[]' | while read -r source; do
  name=$(echo "$source" | jq -r '.name')
  type=$(echo "$source" | jq -r '.type')

  echo "" >> /etc/vector/vector.toml
  echo "[sources.${name}]" >> /etc/vector/vector.toml
  echo "type = \"${type}\"" >> /etc/vector/vector.toml

  # Copy all other fields (excluding 'name' and 'type')
  echo "$source" | jq 'del(.name, .type)' | jq -r "to_entries[] | \"\(.key) = \(.value | @json)\"" >> /etc/vector/vector.toml
done

# Write sinks from all interfaces where protocol == vector
echo "$MAKE87_CONFIG" | jq -c '.interfaces | to_entries[]' | while read -r iface_entry; do
  iface=$(echo "$iface_entry" | jq -c '.value')
  iface_name=$(echo "$iface_entry" | jq -r '.key')
  protocol=$(echo "$iface" | jq -r '.protocol // empty')

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

    inputs=$(echo "$client" | jq -c '.inputs // ["stdin"]')
    echo "inputs = $inputs" >> /etc/vector/vector.toml
    echo "endpoint = \"${host}:${port}\"" >> /etc/vector/vector.toml

    for key in encoding labels mode method compression namespace; do
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
