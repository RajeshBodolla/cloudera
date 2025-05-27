
# CDP AutoScale Script - Documentation

## Overview

This script automates scale-up and scale-down operations for a Cloudera CDP cluster using Cloudera Manager (CM) APIs. It works with Terraform or a static host list.

## Usage

```bash
bash cdp_autoscale_core.sh <scaleup|scaledown> <count> [password|key] [run|resume] [true|false for resume]
```

- `scaleup` or `scaledown`: Action to perform.
- `count`: Number of hosts (informational, not enforced).
- `password` or `key`: SSH authentication method.
- `run`, `dry-run`, `plan`: Mode of execution.
- `true` or `false`: Whether to resume from previous failure.

## Modes

- `run`: Executes all commands.
- `dry-run`: Displays commands and payloads only.
- `plan`: Shows host list from the host file.

## Resume Mode

If a step fails, its name is stored in `autoscale.state`. Re-running with `true` resumes from that step.

```bash
bash cdp_autoscale_core.sh scaleup password run
```

## Host File

Hosts are listed in `/opt/scripts/host_list.txt`, one per line.

## Config File

`/opt/scripts/cdp_autoscale.conf` must contain:

```bash
CM_HOST=ccycloud-1.root.comops.site
CM_PORT=7180
CM_PROTOCOL=http
CM_USER=admin
CM_PASS=admin123
CM_REPO_URL="https://archive.cloudera.com/cm7/7.13.0.0/redhat8/yum/"
CLUSTER_NAME="Compute%20Cluster%201"
HOST_TEMPLATE="Compute%20node"
HOST_TAG="Compute node"
SSH_USER=root
SSH_PASS=cloudera123
SSH_PORT=22
```

Or for key-based auth:

```bash
SSH_KEY='-----BEGIN PRIVATE KEY-----...'
SSH_KEY_PASSPHRASE='yourpassphrase'
```

## Scale-Up Steps

1. **Install Hosts**: `/api/v31/cm/commands/hostInstall`
```json
{
  "hostNames": ["host1", "host2"],
  "sshPort": 22,
  "userName": "root",
  "password": "cloudera123"
}
```

2. **Register Hosts in Cluster**: `/api/v56/clusters/{cluster}/hosts`
```json
{
  "items": [
    { "hostId": "uuid", "hostname": "host1" }
  ]
}
```

3. **Verify Commissioning**: `/api/v56/clusters/{cluster}/hosts`

4. **Apply Host Template**: `/api/v56/clusters/{cluster}/hostTemplates/{template}/commands/applyHostTemplate`
```json
{ "items": ["host1"] }
```

5. **Verify Tags**: Check `_cldr_cm_host_template_name`

## Scale-Down Steps

1. **Remove Hosts**: `/api/v56/hosts/removeHostsFromCluster`
```json
{
  "hostsToRemove": ["host1"],
  "deleteHosts": true
}
```

## Timeout

Command retry logic:
- Default 60 retries
- 10 seconds sleep between retries
- Can be overridden via `CMD_RETRIES` and `CMD_RETRY_INTERVAL`

## Logs

- `/var/log/cdp_autoscale/cdp.log`
- `/opt/scripts/autoscale.state`

## Examples

```bash
bash cdp_autoscale_core.sh scaleup password run
bash cdp_autoscale_core.sh scaledown key resume true
bash cdp_autoscale_core.sh scaledown key run
```
