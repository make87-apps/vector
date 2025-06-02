#!/bin/sh
set -e

target_file="/etc/vector/vector.toml"

mkdir -p /etc/vector
: > ${target_file}

# Extract the deployed application name (used for Loki labels)
app_name=$(echo "$MAKE87_CONFIG" | jq -r '.application_info.deployed_application_name // empty')

# Build the list of “known” sources
source_names=""
has_sources=$(echo "$MAKE87_CONFIG" | jq -e '.config.sources | length > 0' 2>/dev/null || echo false)

if [ "$has_sources" = "true" ]; then
  # If the user provided “config.sources”, write each under [sources.NAME]
  echo "$MAKE87_CONFIG" \
    | jq -c '.config.sources[]' \
    | while read -r source; do
      name=$(echo "$source" | jq -r '.name')
      type=$(echo "$source" | jq -r '.type')

      echo ""                                      >> ${target_file}
      echo "[sources.${name}]"                     >> ${target_file}
      echo "type = \"${type}\""                   >> ${target_file}

      source_names="${source_names}${name}\n"
      echo "$source" \
        | jq 'del(.name, .type)' \
        | jq -r 'to_entries[] | "\(.key) = \(.value | @json)"' \
        >> ${target_file}
    done
else
  # No “config.sources” given → inject two defaults
  echo ""                     >> ${target_file}
  echo "[sources.stdin]"      >> ${target_file}
  echo "type = \"stdin\""     >> ${target_file}

  echo ""                     >> ${target_file}
  echo "[sources.host_metrics]" >> ${target_file}
  echo "type = \"host_metrics\"" >> ${target_file}

  source_names="stdin\nhost_metrics\n"
fi

# If a sink has no valid inputs, choose a fallback based on sink type
default_input_for_sink() {
  case "$1" in
    loki|console|file|elasticsearch|kafka)
      echo "stdin"
      ;;
    prometheus_remote_write)
      echo "host_metrics"
      ;;
    *)
      echo "stdin"
      ;;
  esac
}

# Iterate over every interface
echo "$MAKE87_CONFIG" \
  | jq -c '.interfaces | to_entries[]' \
  | while read -r iface_entry; do
    iface=$(echo "$iface_entry" | jq -c '.value')
    iface_name=$(echo "$iface_entry" | jq -r '.key')

    # Within each interface, iterate over clients
    echo "$iface" \
      | jq -c '.clients | to_entries[]' \
      | while read -r client_entry; do
        name=$(echo "$client_entry" | jq -r '.key')
        client=$(echo "$client_entry" | jq -c '.value')

        # Extract fixed fields (vpn vs public)
        use_public=$(echo "$client" | jq -r '.use_public_ip // false')
        if [ "$use_public" = "true" ]; then
          host=$(echo "$client" | jq -r '.public_ip')
          port=$(echo "$client" | jq -r '.public_port')
        else
          host=$(echo "$client" | jq -r '.vpn_ip')
          port=$(echo "$client" | jq -r '.vpn_port')
        fi

        # Build ‘config’ by removing fixed fields
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

        # The sink type must be in config.sink_type
        type=$(echo "$config" | jq -r '.sink_type // empty')
        if [ -z "$type" ] || [ "$type" = "null" ]; then
          echo "Missing or invalid sink_type for client $iface_name/$name"
          exit 1
        fi

        endpoint="${host}:${port}"

        echo ""                                            >> ${target_file}
        echo "[sinks.${iface_name}_${name}]"               >> ${target_file}
        echo "type = \"${type}\""                          >> ${target_file}
        echo "endpoint = \"${endpoint}\""                  >> ${target_file}

        # Validate “inputs” against known sources
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

        # If this is a Loki sink, inject its labels block
        if [ "$type" = "loki" ]; then
          echo "[sinks.${iface_name}_${name}.labels]" >> ${target_file}
          echo "app = \"${app_name}\""             >> ${target_file}
        fi

        # Write every other key in “config” as a KV or a nested table
        echo "$config" \
          | jq 'del(.inputs, .sink_type)' \
          | jq -c 'to_entries[]' \
          | while read -r entry; do
            key=$(echo "$entry" | jq -r '.key')
            value=$(echo "$entry" | jq -c '.value')

            if echo "$value" | jq -e 'type == "object"' >/dev/null; then
              # Nested table
              echo "[sinks.${iface_name}_${name}.${key}]" >> ${target_file}
              echo "$value" \
                | jq -r 'to_entries[] | "\(.key) = \(.value | (if type=="string" then @json else tostring end))"' \
                >> ${target_file}
            else
              # Simple key = value
              if echo "$value" | jq -e 'type == "string"' >/dev/null; then
                echo "${key} = ${value}" >> ${target_file}
              else
                echo "${key} = $(echo "$value" | jq -r tostring)" >> ${target_file}
              fi
            fi
          done
      done
  done

cat ${target_file}
exec vector --config ${target_file}
