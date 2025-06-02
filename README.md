# vector

This is a [make87](https://make87.com) app that wraps [Vector](https://vector.dev), the high-performance observability data pipeline built in Rust.

It provides an opinionated production-ready deployment, easy integration into your systems, and streamlined configuration from within the make87 platform — including support for Vector’s powerful log and metric routing features.

![Vector Banner](https://github.com/vectordotdev/vector/raw/master/website/static/img/diagram.svg)

> **Licensing Notice**:  
> This app wraps the official [Vector](https://github.com/vectordotdev/vector) project, which is licensed under the Mozilla Public License 2.0 ([MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0/)).  
> All original rights and trademarks belong to [Datadog](https://www.datadoghq.com), the creators of Vector.

---

## Features

- 🧩 Full Vector support (sources, transforms, sinks)
- 🛠️ Easy configuration via make87 UI or API
- 🪵 Unified logging on the node you choose to deploy on
- 📊 Configurable sinks to easily use diffrent types of visualizaitons

---

## Configuration

Vector’s configuration is managed via `vector.yaml`, rendered dynamically from make87’s config interface. You can define sources, transforms, and sinks just like in native Vector.

Example (inside make87 view):

```yaml
sources:
  my_logs:
    type: file
    include:
      - /var/log/my-service.log

transforms:
  parse:
    type: remap
    inputs: ["my_logs"]
    source: |
      . = parse_json!(.message)

sinks:
  stdout:
    type: console
    inputs: ["parse"]
    target: stdout
