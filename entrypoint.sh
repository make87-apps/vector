#!/bin/sh
set -e

target_file="/etc/vector/vector.toml"
target_file="/tmp/vector/vector.toml"

#mkdir -p /etc/vector
mkdir -p /tmp/vector
: > ${target_file}

# Extract the deployed application name (used for Loki labels)
app_name=$(echo "$MAKE87_CONFIG" | jq -r '.application_info.deployed_application_name // empty')

# Build the list of “known” sources
source_names=""
has_sources=$(echo "$MAKE87_CONFIG" | jq -e '.config.sources | length > 0' 2>/dev/null || echo false)

if [ "$has_sources" = "true" ]; then
  echo "$MAKE87_CONFIG" \
    | jq -c '.config.sources[]' \
    | while read -r source; do
      name=$(echo "$source" | jq -r '.name')
      type=$(echo "$source" | jq -r '.type')

      echo "" >> ${target_file}
      echo "[sources.${name}]" >> ${target_file}
      echo "type = \"${type}\"" >> ${target_file}

      source_names="${source_names}${name}\n"

      echo "$source" \
        | jq 'del(.name, .type)' \
        | jq -r 'to_entries[] | "\(.key) = \(.value | @json)"' \
        >> ${target_file}
    done
else
  echo "" >> ${target_file}
  echo "[sources.docker_logs]" >> ${target_file}
  echo "type = \"docker_logs\"" >> ${target_file}

  echo "" >> ${target_file}
  echo "[sources.host_metrics]" >> ${target_file}
  echo "type = \"host_metrics\"" >> ${target_file}

  source_names="docker_logs\nhost_metrics\n"
fi

# Default input fallback by sink type
default_input_for_sink() {
  case "$1" in
    loki|console|file|elasticsearch|kafka)
      echo "docker_logs"
      ;;
    prometheus_remote_write)
      echo "host_metrics"
      ;;
    *)
      echo "docker_logs"
      ;;
  esac
}

# Iterate over interfaces and clients
echo "$MAKE87_CONFIG" \
  | jq -c '.interfaces | to_entries[]' \
  | while read -r iface_entry; do
    iface=$(echo "$iface_entry" | jq -c '.value')
    iface_name=$(echo "$iface_entry" | jq -r '.key')

    echo "$iface" \
      | jq -c '.clients | to_entries[]' \
      | while read -r client_entry; do
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

        config=$(echo "$client" \
          | jq 'del(
              .vpn_ip,
              .vpn_port,
              .public_ip,
              .public_port,
              .same_node,
              .protocol,
              .spec,
              .key,
              .name,
              .interface_name,
              .use_public_ip
            )'
        )

        type=$(echo "$config" | jq -r '.sink_type // empty')
        if [ -z "$type" ] || [ "$type" = "null" ]; then
          echo "Missing or invalid sink_type for client $iface_name/$name"
          exit 1
        fi

        endpoint="${host}:${port}"

        echo "" >> ${target_file}
        echo "[sinks.${iface_name}_${name}]" >> ${target_file}
        echo "type = \"${type}\"" >> ${target_file}
        echo "endpoint = \"http://${endpoint}\"" >> ${target_file}

        inputs=$(echo "$config" | jq -c '.inputs // empty')
        valid_inputs=""
        if [ "$inputs" != "null" ] && [ "$inputs" != "" ]; then
          for input in $(echo "$inputs" | jq -r '.[]'); do
            echo "$source_names" | grep -qx "$input" && valid_inputs="${valid_inputs}\"$input\","
          done
        fi
        if [ -z "$valid_inputs" ]; then
          default_input=$(default_input_for_sink "$type")
          valid_inputs="\"$default_input\","
        fi
        valid_inputs="${valid_inputs%,}"
        echo "inputs = [$valid_inputs]" >> ${target_file}

        if [ "$type" = "loki" ]; then
          echo "labels = { app = \"${app_name}\" }" >> ${target_file}
        fi

        flat_config=$(echo "$config" | jq 'del(.inputs, .sink_type)')

        # Write flat (non-object) keys first
        echo "$flat_config" \
          | jq -c 'to_entries[] | select(.value | type != "object")' \
          | while read -r entry; do
            key=$(echo "$entry" | jq -r '.key')
            value=$(echo "$entry" | jq -c '.value')
            if echo "$value" | jq -e 'type == "string"' >/dev/null; then
              echo "${key} = ${value}" >> ${target_file}
            else
              echo "${key} = $(echo "$value" | jq -r tostring)" >> ${target_file}
            fi
          done

        # Then write nested objects as tables
        echo "$flat_config" \
          | jq -c 'to_entries[] | select(.value | type == "object")' \
          | while read -r entry; do
            key=$(echo "$entry" | jq -r '.key')
            value=$(echo "$entry" | jq -c '.value')
            echo "[sinks.${iface_name}_${name}.${key}]" >> ${target_file}
            echo "$value" \
              | jq -r 'to_entries[] | "\(.key) = \(.value | (if type=="string" then @json else tostring end))"' \
              >> ${target_file}
          done
      done
  done

cat ${target_file}
exec vector --config ${target_file}
