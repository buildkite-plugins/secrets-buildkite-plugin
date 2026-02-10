# Secrets Buildkite Plugin

A Buildkite plugin used to fetch secrets from [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets) or [Azure Key Vault](https://azure.microsoft.com/en-us/products/key-vault).

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
      - secrets#v2.0.0:
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
      - secrets#v2.0.0:
          env: "llamas"
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
      - secrets#v2.0.0:
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
      - secrets#v2.0.0:
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
      - secrets#v2.0.0:
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

### Combining Both Methods

You can use both `env` and `variables` together:

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.0.0:
          provider: azure
          azure-vault-name: my-vault
          env: common-secrets
          variables:
            DEPLOY_KEY: deploy-key
```

### Pinning a Secret Version

By default, the latest version of each secret is fetched. To pin to a specific version:

```yaml
steps:
  - command: build.sh
    plugins:
      - azure-login#v1.0.1:
          client-id: "your-client-id"
          tenant-id: "your-tenant-id"
      - secrets#v2.0.0:
          provider: azure
          azure-vault-name: my-vault
          azure-secret-version: "a1b2c3d4e5f6"
          variables:
            API_KEY: my-api-key
```

## Options

### `provider` (optional, string, default: `buildkite`)

The secrets provider to use. Supported values: `buildkite`, `azure`.

### `env` (optional, string)
The secret key name containing base64-encoded `KEY=value` pairs. Used for fetching multiple secrets from a single stored value.

### `variables` (optional, object)
Specify a dictionary of `key: value` pairs to inject as environment variables, where the key is the name of the
environment variable to be set, and the value is the secret name in the provider.

### `azure-vault-name` (required when provider is `azure`, string)

The name of the Azure Key Vault to fetch secrets from.

### `azure-secret-version` (optional, string)

The version of the Azure Key Vault secret to fetch. If not specified, the latest version is used.

### `skip-redaction` (optional, boolean, default: `false`)

If set to `true`, secrets will not be automatically redacted from Buildkite logs. By default, all fetched secrets are automatically redacted using the buildkite-agent redactor feature.
Secret redaction requires buildkite-agent `v3.67.0` or later. If an older agent version is used, a warning will be issued.

### `retry-max-attempts` (optional, number, default: 5)

Maximum number of retry attempts for transient failures when fetching secrets (e.g., 5xx server errors, network issues).

### `retry-base-delay` (optional, number, default: 2)

Base delay in seconds for exponential backoff between retry attempts.

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
