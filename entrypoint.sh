#!/bin/sh
set -e

mkdir -p /etc/vector

# We will build a single JSON object with two top‐level keys:
#   "sources": { <source_name>: { ... }, ... }
#   "sinks":   { <sink_name>:   { ... }, ... }
#
# To do that, we invoke jq once on MAKE87_CONFIG and construct the final object.

config_json=$(
  echo "$MAKE87_CONFIG" | jq -c '
    # 1) Determine "sources" section:
    # If .config.sources exists and is a nonempty array, use it; otherwise, inject defaults.
    ( .config.sources? | select(type == "array" and length > 0)
      // [ { name:"stdin",       type:"stdin" },
           { name:"host_metrics", type:"host_metrics" } ]
    )
    # Turn each element { name, type, … } into { (name): { type: …, … } }
    | map(
        { ( .name ): ( { type: .type } + ( del(.name, .type) ) ) }
      )
    | add as $sources

    # 2) Build "sinks" section by iterating all interfaces → clients:
    | .interfaces
    | to_entries      # [ {key, value} … ] where key=interfaceName, value={...}
    | map(
        .value.clients? // {}             # clients object or {} if none
        | to_entries                      # [ {key, value} … ] where key=clientName
        | map(
            # For each client entry, build a single‐key object { "<iface>_<client>": { … } }
            . as $entry
            | $entry.key as $clientName
            | $entry.value as $clientObj

            # Determine which IP/port to use:
            | ($clientObj.use_public_ip? // false) as $use_public
            | ( if $use_public
                then $clientObj.public_ip + ":" + ($clientObj.public_port|tostring)
                else $clientObj.vpn_ip + ":" + ($clientObj.vpn_port|tostring)
              ) as $endpoint

            # Build the “inner” sink object:
            #   start with type: .sink_type (error if missing)
            | ($clientObj.sink_type? // error("Missing sink_type for " + $clientName)) as $stype

            # Start assembling the sink spec:
            | { type: $stype,
                endpoint: $endpoint }
              # + inputs if present and valid, otherwise fallback
            | ( if $clientObj.inputs? then
                  # Validate each input against $sources keys
                  $clientObj.inputs
                  | map(select(. as $i | ($sources|has($i))))
                  | select(length > 0)
                  | { inputs: . }
                else
                  # fallback based on type:
                  if ($stype | IN({"loki", "console", "file", "elasticsearch", "kafka"})) then
                    { inputs: ["stdin"] }
                  else
                    { inputs: ["host_metrics"] }
                  end
                end
              )
            # + encoding if present
            + ( $clientObj.encoding?   | select(type == "object") | { encoding: . } // {} )
            # + labels only if this is a Loki sink
            + ( if $stype == "loki" then
                  { labels: { app: .application_info.deployed_application_name } }
                else
                  {}
                end )
            # + all remaining fields in clientObj, minus the fixed keys
            + (
                $clientObj
                | del(
                    .vpn_ip,
                    .vpn_port,
                    .public_ip,
                    .public_port,
                    .use_public_ip,
                    .same_node,
                    .protocol,
                    .spec,
                    .key,
                    .name,
                    .interface_name,
                    .sink_type,
                    .inputs,
                    .encoding
                  )
              )
            | { ( ( . as $parent | $parent | "" ) ;   # placeholder for key
                  ($ifaceEntry.key + "_" + $clientName)
                ) : . }
        )
        | add
      )
    # Flatten the array of sink‐objects into one big object
    | add as $sinks

    # 3) Emit final JSON: { sources: $sources, sinks: $sinks }
    | { sources: $sources, sinks: $sinks }
  '
)

# Write the JSON to disk
echo "$config_json" > /etc/vector/vector.json

# Run Vector with that JSON
exec vector --config /etc/vector/vector.json
