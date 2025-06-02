#!/bin/sh
set -e

mkdir -p /etc/vector
: > /etc/vector/vector.toml

# Extract the deployed application name (used for Loki labels)
app_name=$(echo "$MAKE87_CONFIG" | jq -r '.application_info.deployed_application_name // empty')

# Build the list of “known” sources
source_names=""
has_sources=$(echo "$MAKE87_CONFIG" | jq -e '.config.sources | length > 0' 2>/dev/null || echo false)

if [ "$has_sources" = "true" ]; then
  # If the user provided “config.sources”, write each one exactly
  echo "$MAKE87_CONFIG" \
    | jq -c '.config.sources[]' \
    | while read -r source; do
      name=$(echo "$source" | jq -r '.name')
      type=$(echo "$source" | jq -r '.type')

      echo ""                                      >> /etc/vector/vector.toml
      echo "[sources.${name}]"                     >> /etc/vector/vector.toml
      echo "type = \"${type}\""                   >> /etc/vector/vector.toml

      source_names="${source_names}${name}\n"
      # Write all other fields under this source
      echo "$source" \
        | jq 'del(.name, .type)' \
        | jq -r 'to_entries[] | "\(.key) = \(.value | @json)"' \
        >> /etc/vector/vector.toml
    done
else
  # No “config.sources” given → inject two defaults
  echo ""                     >> /etc/vector/vector.toml
  echo "[sources.stdin]"      >> /etc/vector/vector.toml
  echo "type = \"stdin\""     >> /etc/vector/vector.toml

  echo ""                     >> /etc/vector/vector.toml
  echo "[sources.host_metrics]" >> /etc/vector/vector.toml
  echo "type = \"host_metrics\"" >> /etc/vector/vector.toml

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

# Iterate every interface ↓
echo "$MAKE87_CONFIG" \
  | jq -c '.interfaces | to_entries[]' \
  | while read -r iface_entry; do
    iface=$(echo "$iface_entry" | jq -c '.value')
    iface_name=$(echo "$iface_entry" | jq -r '.key')

    # Within each interface, iterate every client ↓
    echo "$iface" \
      | jq -c '.clients | to_entries[]' \
      | while read -r client_entry; do
        name=$(echo "$client_entry" | jq -r '.key')
        client=$(echo "$client_entry" | jq -c '.value')

        # ── Pull out the “fixed” fields: vpn_ip/vpn_port vs. public_ip/public_port ──
        use_public=$(echo "$client" | jq -r '.use_public_ip // false')
        if [ "$use_public" = "true" ]; then
          host=$(echo "$client" | jq -r '.public_ip')
          port=$(echo "$client" | jq -r '.public_port')
        else
          host=$(echo "$client" | jq -r '.vpn_ip')
          port=$(echo "$client" | jq -r '.vpn_port')
        fi

        # ── Build a “config” object that excludes all those fixed fields ──
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

        # Sink type must come from either config.sink_type or be invalid
        type=$(echo "$config" | jq -r '.sink_type // empty')
        if [ -z "$type" ] || [ "$type" = "null" ]; then
          echo "Missing or invalid sink_type for client $iface_name/$name"
          exit 1
        fi

        endpoint="${host}:${port}"

        echo ""                                            >> /etc/vector/vector.toml
        echo "[sinks.${iface_name}_${name}]"               >> /etc/vector/vector.toml
        echo "type = \"${type}\""                          >> /etc/vector/vector.toml
        echo "endpoint = \"${endpoint}\""                  >> /etc/vector/vector.toml

        # ── Validate “inputs” from config; fall back if none valid ──
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
        echo "inputs = [$valid_inputs]" >> /etc/vector/vector.toml

        # ── If this is Loki, inject a labels block using app_name ──
        if [ "$type" = "loki" ]; then
          echo "[sinks.${iface_name}_${name}.labels]" >> /etc/vector/vector.toml
          echo "app = \"${app_name}\""             >> /etc/vector/vector.toml
        fi

        # ── Write every remaining key in “config” as either a simple KV or a nested table ──
        echo "$config" \
          | jq 'del(.inputs, .sink_type)' \
          | jq -c 'to_entries[]' \
          | while read -r entry; do
            key=$(echo "$entry" | jq -r '.key')
            value=$(echo "$entry" | jq -c '.value')

            # If it’s an object, produce a nested [table] header + its keys
            if echo "$value" | jq -e 'type == "object"' >/dev/null; then
              echo "[sinks.${iface_name}_${name}.${key}]" >> /etc/vector/vector.toml
              echo "$value" \
                | jq -r 'to_entries[] | "\(.key) = \(.value | (if type=="string" then @json else tostring end))"' \
                >> /etc/vector/vector.toml

            # Otherwise, emit a simple “key = value” line (quoting strings)
            else
              if echo "$value" | jq -e 'type == "string"' >/dev/null; then
                echo "${key} = ${value}" >> /etc/vector/vector.toml
              else
                echo "${key} = $(echo "$value" | jq -r tostring)" >> /etc/vector/vector.toml
              fi
            fi
          done
      done
  done

exec vector --config /etc/vector/vector.toml
