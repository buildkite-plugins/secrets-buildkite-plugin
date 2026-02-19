# Secrets Buildkite Plugin

A Buildkite plugin to fetch secrets from multiple providers and inject them into your build environment.

Supported providers:
- [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets) (default)
- [GCP Secret Manager](https://cloud.google.com/secret-manager)

## Changes to consider when upgrading to `v2.0.0`

If upgrading from v1.x.x, note these changes:

- **Log format**: Uses structured prefixes (`[INFO]`, `[WARNING]`, `[ERROR]`) instead of emoji
- **Removed**: `dump_env` function removed for security
- **New default**: Secrets auto-redacted from logs (requires agent v3.67.0+). Opt out with `skip-redaction: true`
- **Stricter errors**: Invalid base64-encoded secrets now fail immediately

## Buildkite Secrets Provider

The default provider fetches secrets from [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets).

You can create a secret in your Buildkite cluster(s) from the Buildkite UI following the instructions in the documentation [here](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets#create-a-secret-using-the-buildkite-interface).

### Individual Variables

Create a Buildkite secret for each variable that you need to store. Paste the value of the secret into buildkite.com directly.

A `pipeline.yml` like this will read each secret out into an environment variable:

```yml
steps:
  - command: echo "The content of ANIMAL is \$ANIMAL"
    plugins:
      - secrets#v2.0.0:
          variables:
            ANIMAL: llamas
            FOO: bar
```

### Batch (Base64-Encoded)

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
      - secrets#v2.0.0:
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
      - secrets#v2.0.0:
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
      - secrets#v2.0.0:
          provider: gcp
          gcp-project: my-project-id
          env: "ci-env-secrets"
```

### Combining Both Methods

You can use `env` and `variables` together to fetch both batch and individual secrets:

```yaml
steps:
  - command: build.sh
    plugins:
      - gcp-workload-identity-federation#v1.5.0:
          audience: "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/buildkite"
          service-account: "my-service-account@my-project-id.iam.gserviceaccount.com"
      - secrets#v2.0.0:
          provider: gcp
          gcp-project: my-project-id
          env: "ci-env-secrets"
          variables:
            DEPLOY_KEY: deploy-key-secret
```

## Options

### Common Options

These options apply to all providers.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `provider` | string | `buildkite` | The secrets provider to use. Supported values: `buildkite`, `gcp`. |
| `env` | string | - | Secret key name for fetching batch secrets (base64-encoded `KEY=value` format). |
| `variables` | object | - | Map of `ENV_VAR_NAME: secret-path` pairs to inject as environment variables. |
| `skip-redaction` | boolean | `false` | If `true`, secrets will not be automatically redacted from logs. |
| `retry-max-attempts` | number | `5` | Maximum retry attempts for transient failures. |
| `retry-base-delay` | number | `2` | Base delay in seconds for exponential backoff between retries. |

### GCP Provider Options

These options only apply when `provider: gcp` is set.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `gcp-project` | string | - | GCP project ID. Falls back to `CLOUDSDK_CORE_PROJECT` or `gcloud config`. |
| `gcp-secret-version` | string | `latest` | The secret version to fetch. |

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
      - secrets#v2.0.0:
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
      - secrets#v2.0.0:
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
