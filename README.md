# Secrets Buildkite Plugin

A Buildkite plugin to fetch secrets from multiple providers and inject them into your build environment.

Supported providers:
- [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets) (default)
- [GCP Secret Manager](https://cloud.google.com/secret-manager)
- [Azure Key Vault](https://azure.microsoft.com/en-us/products/key-vault)
- [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/)
- [1Password](https://1password.com/)

## Changes to consider when upgrading to `v2.0.0`

If upgrading from v1.x.x, note these changes:

- **Log format**: Uses structured prefixes (`[INFO]`, `[WARNING]`, `[ERROR]`) instead of emoji
- **Removed**: `dump_env` function removed for security
- **New default**: Secrets auto-redacted from logs (requires agent v3.67.0+). Opt out with `skip-redaction: true`
- **Stricter errors**: Invalid base64-encoded secrets now fail immediately

## Buildkite Secrets Provider (Default)

The default provider fetches secrets from [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets).

You can create a secret in your Buildkite cluster(s) from the Buildkite UI following the instructions in the documentation [here](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets#create-a-secret-using-the-buildkite-interface).

### Individual Variables

Create a Buildkite secret for each variable that you need to store. Paste the value of the secret into buildkite.com directly.

A `pipeline.yml` like this will read each secret out into an environment variable:

```yml
steps:
  - command: echo "The content of ANIMAL is \$ANIMAL"
    plugins:
      - secrets#v2.4.0:
          variables:
            ANIMAL: llamas
            FOO: bar
```

### Batch Secrets (Base64)

Create a single Buildkite secret with one variable per line, encoded as base64 for storage.

For example, setting three variables looks like this in a file:

```shell
Foo=bar
SECRET_KEY=llamas
COFFEE=more
```

Then encode the file:

```shell
cat data.txt | base64
```

Next, upload the base64 encoded data to buildkite.com in your browser with a
key of your choosing - like `llamas`. The three secrets can be read into the
job environment using a pipeline.yml like this:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          env: "llamas"
```

## GCP Secret Manager Provider

Fetches secrets from [GCP Secret Manager](https://cloud.google.com/secret-manager).

### Prerequisites

- The [gcloud CLI](https://cloud.google.com/sdk/docs/install) must be installed and available on the Buildkite agent.
- The agent must be authenticated to GCP with permissions to access Secret Manager (e.g., the `roles/secretmanager.secretAccessor` role). For Buildkite-hosted agents, use the [gcp-workload-identity-federation](https://github.com/buildkite-plugins/gcp-workload-identity-federation-buildkite-plugin) plugin to authenticate.
- The Secret Manager API must be enabled on the GCP project.

### GCP Project Configuration

The GCP project is resolved in this order:

1. The `gcp-project` plugin option
2. The `CLOUDSDK_CORE_PROJECT` environment variable
3. The active `gcloud config` project (`gcloud config get-value project`)

### Individual Variables

Create secrets in GCP Secret Manager, then map them to environment variables:

```yaml
steps:
  - command: build.sh
    plugins:
      - gcp-workload-identity-federation#v1.5.0:
          audience: "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/buildkite"
          service-account: "my-service-account@my-project-id.iam.gserviceaccount.com"
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          variables:
            API_KEY: my-api-key-secret
            DB_PASSWORD: my-db-password-secret
```

Each key under `variables` becomes the environment variable name, and the value is the GCP secret ID to fetch.

### Batch (Base64-Encoded)

Store multiple `KEY=value` pairs in a single GCP secret, base64-encoded:

```shell
# Create a file with your variables
cat > secrets.txt <<EOF
API_KEY=sk-abc123
DB_HOST=db.example.com
DB_PASSWORD=supersecret
EOF

# Base64-encode and store in GCP Secret Manager
base64 secrets.txt | gcloud secrets create ci-env-secrets --data-file=-
```

Then reference the secret in your pipeline:

```yaml
steps:
  - command: build.sh
    plugins:
      - gcp-workload-identity-federation#v1.5.0:
          audience: "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/buildkite"
          service-account: "my-service-account@my-project-id.iam.gserviceaccount.com"
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          env: "ci-env-secrets"
```

## Azure Key Vault Provider

Use `provider: azure` to fetch secrets from [Azure Key Vault](https://azure.microsoft.com/en-us/products/key-vault).

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) installed on your Buildkite agent
- The agent must be authenticated to Azure. Use the [azure-login](https://github.com/buildkite-plugins/azure-login-buildkite-plugin) plugin to authenticate via managed identity or service principal.
- The authenticated identity must have the `Key Vault Secrets User` role (or equivalent `get` permission) on the vault

### Configuration

Set `provider: azure` and `azure-vault-name` in your plugin configuration:

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.4.0:
          provider: azure
          azure-vault-name: my-vault
          variables:
            API_KEY: my-api-key-secret
```

### Individual Variables

Each key in `variables` maps to an Azure Key Vault secret name. The secret's value is fetched and exported as the corresponding environment variable:

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.4.0:
          provider: azure
          azure-vault-name: my-vault
          variables:
            DB_PASSWORD: db-password
            API_TOKEN: api-token
            SSH_KEY: deploy-ssh-key
```

Azure Key Vault secret names must contain only alphanumeric characters and hyphens, and must start with an alphanumeric character.

### Batch Secrets (Base64)

Store multiple `KEY=value` pairs as a single base64-encoded Azure Key Vault secret, then use `env` to fetch and decode them all at once:

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.4.0:
          provider: azure
          azure-vault-name: my-vault
          env: batch-secrets
```

To create the batch secret:

```shell
# Create a file with KEY=value pairs
cat > data.txt <<EOF
DB_HOST=mydb.example.com
DB_PASSWORD=supersecret
API_KEY=abc123
EOF

# Base64 encode and store in Azure Key Vault
az keyvault secret set --vault-name my-vault --name batch-secrets --value "$(base64 < data.txt)"
```

## AWS Secrets Manager Provider

Use `provider: aws` to fetch secrets from [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/).

### Prerequisites

- The [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (`aws`) installed on your Buildkite agent.
- The agent must be authenticated to AWS with permissions to call `secretsmanager:GetSecretValue` on the relevant secrets. Use the [aws-assume-role-with-web-identity](https://buildkite.com/resources/plugins/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin/) plugin to authenticate via OIDC; an instance profile or static credentials in the environment also work.
- [jq](https://jqlang.github.io/jq/) installed on the agent if you use `json-variables` (see below).

### AWS Region Configuration

The AWS region is resolved in this order:

1. The `aws-region` plugin option
2. The AWS CLI's configured region (e.g. `AWS_REGION`, `AWS_DEFAULT_REGION`, or the agent's instance/profile configuration)

### Individual Variables

Create secrets in AWS Secrets Manager, then map them to environment variables:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          variables:
            API_KEY: my-api-key-secret
            DB_PASSWORD: my-db-password-secret
```

Each key under `variables` becomes the environment variable name, and the value is the AWS secret name or ARN to fetch.

### Batch (Base64-Encoded)

Store multiple `KEY=value` pairs in a single AWS secret, base64-encoded:

```shell
# Create a file with your variables
cat > secrets.txt <<EOF
API_KEY=sk-abc123
DB_HOST=db.example.com
DB_PASSWORD=supersecret
EOF

# Base64-encode and store in AWS Secrets Manager
aws secretsmanager create-secret --name ci-env-secrets --secret-string "$(base64 < secrets.txt)"
```

Then reference the secret in your pipeline:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          env: "ci-env-secrets"
```

### JSON Secrets as Environment Variables (`json-variables`)

AWS Secrets Manager commonly stores secrets as a single JSON object (e.g. `{"username": "admin", "password": "supersecret"}`). Use `json-variables` to expand the keys of a JSON object directly into environment variables, without needing to base64-encode anything or invoke `jq` yourself:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          json-variables:
            - secret-id: rds/my-database-credentials
```

If `rds/my-database-credentials` resolves to:

```json
{
  "username": "admin",
  "password": "supersecret",
  "port": 5432
}
```

Then `username`, `password`, and `port` are each exported as environment variables.

Each entry takes:

- `secret-id` (required) — the AWS secret name or ARN to fetch.
- `json-key` (optional, default `.`) — a [`jq`](https://jqlang.github.io/jq/manual/) path into the secret's JSON content to expand. Use this when the keys you want live under a nested object rather than at the root:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          json-variables:
            - secret-id: my-secret-id
              json-key: ".Variables"
```

With a secret called `my-secret-id` containing:

```json
{
  "Variables": {
    "MY_SECRET": "value",
    "MY_OTHER_SECRET": "other value"
  }
}
```

This sets the `MY_SECRET` and `MY_OTHER_SECRET` environment variables.

Only keys with string, number, or boolean values are expanded — nested objects/arrays are skipped. Keys are sanitized into valid shell variable names by replacing any character that isn't a letter, digit, or underscore with `_`, and prefixing the result with `_` if it would otherwise start with a digit (e.g. `My-great key!` becomes `My_great_key_`).

## 1Password Provider

Use `provider: op` to fetch secrets from [1Password](https://1password.com/) using the `op` CLI.

### Prerequisites

- The [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`) installed on your Buildkite agent
- One of the following authentication methods configured on the agent:
  - **Connect Server** (recommended for self-hosted agents): set `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN`
  - **Service Account**: set `OP_SERVICE_ACCOUNT_TOKEN`
  - **Interactive session**: sign in with `op signin` before the build runs

### Secret References

Secrets can be specified in either short or full form:

- **Short form**: `vault/item/field` — the `op://` prefix is added automatically
- **Full form**: `op://vault/item/field` — explicit, useful when mixing with other tooling

Where:
- `vault` — the name or ID of your 1Password vault
- `item` — the name or ID of the item within that vault
- `field` — the field to read from the item (e.g. `password`, `credential`, or a custom field label)

### Individual Variables

Map environment variable names to secret references:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: op
          variables:
            API_KEY: my-vault/my-api-key/credential
            DB_PASSWORD: my-vault/db-creds/password
```

### Batch Secrets (Base64)

Store multiple `KEY=value` pairs in a single 1Password item field, base64-encoded, and use `env` to fetch and decode them all at once:

```shell
# Create a file with KEY=value pairs
cat > data.txt <<EOF
DB_HOST=mydb.example.com
DB_PASSWORD=supersecret
API_KEY=abc123
EOF

# Base64 encode and store as a 1Password item (e.g. in a "Password" or "Text" field)
op item create --category=login --title="ci-batch-secrets" --vault=my-vault \
  credential="$(base64 < data.txt)"
```

Then reference it in your pipeline:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: op
          env: my-vault/ci-batch-secrets/credential
```

## Combining Both Methods

You can use `env` and `variables` together to fetch both batch and individual secrets in a single plugin call.

**GCP:**

```yaml
steps:
  - command: build.sh
    plugins:
      - gcp-workload-identity-federation#v1.5.0:
          audience: "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/buildkite"
          service-account: "my-service-account@my-project-id.iam.gserviceaccount.com"
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          env: "ci-env-secrets"
          variables:
            DEPLOY_KEY: deploy-key-secret
```

**Azure:**

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.4.0:
          provider: azure
          azure-vault-name: my-vault
          env: batch-secrets
          variables:
            DEPLOY_KEY: deploy-key-secret
```

**AWS:**

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          env: "ci-env-secrets"
          variables:
            DEPLOY_KEY: deploy-key-secret
          json-variables:
            - secret-id: rds/my-database-credentials
```

**1Password:**

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: op
          env: my-vault/ci-batch-secrets/credential
          variables:
            DEPLOY_KEY: my-vault/deploy-key/credential
```

## Pinning a Secret Version (GCP)

By default, the latest version of each secret is fetched. To pin to a specific version:

```yaml
steps:
  - command: build.sh
    plugins:
      - gcp-workload-identity-federation#v1.5.0:
          audience: "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/buildkite"
          service-account: "my-service-account@my-project-id.iam.gserviceaccount.com"
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          gcp-secret-version: "5"
          variables:
            API_KEY: my-api-key-secret
```

## Pinning a Secret Version (Azure)

By default, the latest version of each secret is fetched. To pin to a specific version:

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.4.0:
          provider: azure
          azure-vault-name: my-vault
          azure-secret-version: "a1b2c3d4e5f6"
          variables:
            API_KEY: my-api-key
```

## Pinning a Secret Version (AWS)

By default, the `AWSCURRENT` staged version of each secret is fetched. To pin to a specific version:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          aws-secret-version-id: "EXAMPLE1-90ab-cdef-fedc-ba987EXAMPLE"
          variables:
            API_KEY: my-api-key-secret
```

Or pin to a staging label (e.g. `AWSPREVIOUS`) with `aws-secret-version-stage`:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: aws
          aws-region: us-east-1
          aws-secret-version-stage: "AWSPREVIOUS"
          variables:
            API_KEY: my-api-key-secret
```

## Git Credentials for Checkout

Use the `git-credentials` option to fetch git credentials from any of the
supported providers and configure them for the agent's checkout, without storing
them as a Kubernetes Secret or a static file on the agent.

The plugin runs in the `environment` hook, which the Agent runs inside the
checkout container before the repository is cloned. The referenced secret
value is used as a [git credentials file
entry](https://git-scm.com/docs/git-credential-store#_storage_format), and the
plugin configures git's store credential helper to use it:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          git-credentials: github-https-credentials
```

Store the secret value in the standard git credentials format, one entry per
line:

```
https://x-access-token:ghp_yourtoken@github.com
```

The fetched credentials are written to a private, job-scoped file and removed again in the
`pre-exit` hook. Set `git-credentials-file` to control where the file is
written. By default, this will create a temporary file.

The credentials may be stored raw or base64-encoded. The plugin detects and decodes
base64 automatically.

`git-credentials` and `git-ssh-key` are mutually exclusive. Configure one git
auth method per step. Setting both will result in an `exit 1`.

## SSH Keys for Checkout

For SSH-based checkouts such as `git@host:...` or `ssh://...` remotes, use `git-ssh-key`.
The plugin fetches an SSH private key from the active provider, writes it to a
private file, and configures git's `core.sshCommand` to use it, with host key
verification enabled. The configured ssh ignores user and system ssh_config,
to ensure that tokens are used per-job, opposed to agent-wide.

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          git-ssh-key: deploy-key
```

Host key verification uses GitHub's published host keys by default. To verify a
different host such as a self-hosted git server, supply your own
`known_hosts` contents:

```yaml
      - secrets#v2.4.0:
          provider: gcp
          gcp-project: my-project-id
          git-ssh-key: deploy-key
          git-ssh-known-hosts: |
            git.internal.example.com ssh-ed25519 AAAA...
```

The key is written to a private job scoped file and removed again in the
`pre-exit` hook. The key may be stored raw or base64-encoded. The plugin
detects and decodes base64 automatically.

`git-credentials` and `git-ssh-key` are mutually exclusive. Configure one git
auth method per step. Setting both will result in an `exit 1`.

This plugin never writes or modifies `~/.gitconfig`. It injects config only through
job scoped `GIT_CONFIG_*` environment variables that apply to this job's git
processes. The credential helper is scoped to each host in your secret, and for those
hosts it first resets any inherited helper so nothing else can intercept the request
or store the token. Any credential helper the agent already had keeps working for
every other host, and the injected `core.sshCommand` applies only to this job. The
`pre-exit` hook removes the secret file it wrote.

## Choosing between git-credentials and git-ssh-key

Match the option to how the repository is cloned. `git-credentials` authenticates HTTPS remotes and `git-ssh-key` authenticates SSH remotes. The two do not cross over,
so an HTTPS credential cannot authenticate an SSH clone. If your pipeline checks out over SSH, you will need to select `git-ssh-key`. If it checks out over HTTPS you need `git-credentials`.

Because the plugin runs before the checkout, the fetched `git-credentials` or `git-ssh-key` will be used for the repo's own checkout, not only repositories you clone later in the build.
As such, the method you select should to match your pipeline repo's clone URL, not just the URLs you use in your build steps.

`git-ssh-key` configures a job wide `core.sshCommand`, so the fetched key becomes the only SSH identity git uses for the whole job, including the checkout.
Any pre-existing SSH identity is not used while the key is configured.

### Agent Stack for Kubernetes

On the [Agent Stack for Kubernetes](https://buildkite.com/docs/agent/v3/agent-stack-k8s) the environment hook runs in every container that runs the plugin phase, which is
both the checkout container and the command container in this case. Each one fetches the secret and configures git locally, so the credential is available for the `checkout` and for
`command` phases you run in your build. The token will be destroyed in the `pre-exit` phase.

By default, the Buildkite Agent ships with `git` and `ssh` which are required for this plugin,if you are using a custom image, please ensure that `git`, `ssh` and if your token is base64 encoded, `base64`
are installed.

## Options

### Common Options

These options apply to all providers.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `provider` | string | `buildkite` | The secrets provider to use. Supported values: `buildkite`, `gcp`, `azure`, `aws`, `op`. |
| `env` | string | - | Secret key name for fetching batch secrets (base64-encoded `KEY=value` format). |
| `variables` | object | - | Map of `ENV_VAR_NAME: secret-path` pairs to inject as environment variables. |
| `json-variables` | array | - | List of `{ secret-id, json-key }` objects (AWS only). Expands the JSON object at `json-key` (a jq path, default `.`) within each secret into one environment variable per key. |
| `mute-log` | boolean | `true` | If `true` (default), the "Fetching secrets" header renders as a de-emphasized `~~~` group. Set to `false` to use the bold `---` style. |
| `skip-redaction` | boolean | `false` | If `true`, secrets will not be automatically redacted from logs. |
| `retry-max-attempts` | number | `5` | Maximum retry attempts for transient failures. |
| `retry-base-delay` | number | `2` | Base delay in seconds for exponential backoff between retries. |
| `git-credentials` | string | - | Secret holding HTTPS git credentials for the checkout. |
| `git-credentials-file` | string | - | Absolute path to write the credentials to. Defaults to a private temp file. |
| `git-ssh-key` | string | - | Secret holding an SSH private key for the checkout. |
| `git-ssh-known-hosts` | string | GitHub | `known_hosts` contents to verify the SSH host. Defaults to GitHub's keys. |

### GCP Provider Options

These options only apply when `provider: gcp` is set.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `gcp-project` | string | - | GCP project ID. Falls back to `CLOUDSDK_CORE_PROJECT` or `gcloud config`. |
| `gcp-secret-version` | string | `latest` | The secret version to fetch. |

### Azure Provider Options

These options only apply when `provider: azure` is set.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `azure-vault-name` | string | - | The Azure Key Vault name (required when provider is azure). |
| `azure-secret-version` | string | latest | The secret version to fetch. If not specified, the latest version is used. |

### AWS Provider Options

These options only apply when `provider: aws` is set.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `aws-region` | string | - | AWS region to fetch secrets from. Falls back to the AWS CLI's configured region. |
| `aws-secret-version-id` | string | - | The Secrets Manager version ID to fetch. Defaults to the `AWSCURRENT` staged version. |
| `aws-secret-version-stage` | string | - | The Secrets Manager staging label to fetch (e.g. `AWSPREVIOUS`). Defaults to `AWSCURRENT`. |

### 1Password Provider Options

The `op` provider has no additional plugin options. Authentication is handled via agent environment variables (`OP_CONNECT_HOST`+`OP_CONNECT_TOKEN` for Connect Server, or `OP_SERVICE_ACCOUNT_TOKEN` for service accounts) or an existing `op` session. All secret paths are specified directly as `op://vault/item/field` references in `env` and `variables`.

## Secret Redaction

By default, this plugin automatically redacts all fetched secrets from your Buildkite logs to prevent accidental exposure. This includes:

- The raw secret values
- Shell-escaped versions of secrets
- Base64-decoded versions of secrets (if the secret appears to be base64-encoded)

The redaction feature uses the `buildkite-agent redactor add` command, which requires buildkite-agent `v3.67.0` or later. If you're running an older version, the plugin will log a warning and continue without redaction.

To disable automatic redaction (not recommended), set `skip-redaction: true`:

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          env: "llamas"
          skip-redaction: true
```

## Retry Behavior

This plugin implements automatic retry logic with exponential backoff for secret calls. This will occur for 5xx server errors or any local network issues. If a 4xx code is received, a fast failure will be served.

By default, the base delay will be 2 seconds, with a maximum of 5 retries.

### Example with Custom Retry

```yaml
steps:
  - command: build.sh
    plugins:
      - secrets#v2.4.0:
          env: "llamas"
          retry-max-attempts: 10
          retry-base-delay: 2
```

## Testing

You can run the tests using `docker-compose`:

```bash
docker compose run --rm tests
```

## License

MIT (see [LICENSE](LICENSE))
