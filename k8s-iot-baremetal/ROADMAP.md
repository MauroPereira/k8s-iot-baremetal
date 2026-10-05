# ROADMAP — k8s-iot-baremetal

## Phase 1 — Cluster Foundation ✅ DONE
Vanilla Kubernetes 1.32 on bare metal, 3-node (1 control-plane + 2 workers).
- Ansible push automation (kubeadm, containerd, Cilium CNI)
- Local storage via `local-path-provisioner`
- GitOps via ArgoCD (automated sync + self-heal)
- Discord notifications on sync events

## Phase 2 — IoT Pipeline Core ✅ DONE
End-to-end telemetry pipeline, all components running in `iot` namespace.
- Mosquitto MQTT broker
- Telegraf (MQTT consumer → InfluxDB writer)
- InfluxDB v2 StatefulSet + PVC
- Grafana with InfluxDB datasource (NodePort :30300)
- IoT simulator script (`tests/02_iot_simulator.sh`)

## Phase 3 — IoT Pipeline Polish ✅ DONE
- Grafana dashboard legend improvements (Flux `map` + `drop`)
- Dashboard exported as JSON, provisioned via ConfigMap (IaC)
- Health check CronJob — publishes to MQTT every 1 min, verifies in InfluxDB
- "Control" Grafana dashboard — stat panel with healthcheck status (OK/FAIL/NO DATA)

## Phase 4 — Physical Hardware Validation 🔲 NEXT
- Expose Mosquitto via `NodePort` on port 1883 (currently `ClusterIP`, cluster-internal only)
- Connect real IoT devices: ESP32 boards and/or PLC via MQTT bridge
- Validate end-to-end pipeline with physical hardware (not just simulator)

## Phase 5 — Security 🔒 FUTURE
- TLS on MQTT (cert-manager + self-signed CA)
- Mosquitto authentication (username/password or mTLS)
- Ingress controller (nginx or Cilium Gateway API)

## Phase 6 — Multi-tenancy & Extensibility 🔒 FUTURE
- Multi-user login system for per-user data persistence
- Periodic storage snapshots (backup against failures and accidental deletion)
- Easy deployment of user-defined Grafana dashboards

