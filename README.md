# Secrets Buildkite Plugin

A Buildkite plugin used to fetch secrets from [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets),

## Changes to consider when upgrading to `v2.0.0`

If you're upgrading from `v1.x.x` to `v2.0.0`, please note the potential changes to your workflow:

### Log Format Changes
Log output now uses structured prefixes (`[INFO]`, `[WARNING]`, `[ERROR]`) instead of emoji-based indicators. If you have log parsing scripts or monitoring that relies on specific log formats, you may need to update them.

Before:
```
⚠️ Unable to find secret at my-key
```

After:
```
[ERROR]: Unable to find secret at my-key
```

### Removed Features
- The `dump_env` function has been removed. This debugging feature has been removed for security reasons. If you were using `dump_env: true`, please remove it from your pipeline configuration.

### New Defaults
- Secrets are now automatically redacted from logs by default (requires buildkite-agent v3.67.0+). To opt out, set `skip-redaction: true`.

### Stricter Error Handling
- Malformed or invalid base64-encoded secrets now cause builds to fail immediately, rather than silently continuing. If you have secrets that fail to decode, you will need to fix them before upgrading to v2.0.0. This change helps catch configuration errors early rather than allowing builds to continue with missing secrets.

If these changes are breaking for your use case, we recommend updating your usage to conform with the more secure `v2.0.0`.

## Storing Secrets

There are two options for storing and fetching secrets.

You can create a secret in your Buildkite cluster(s) from the Buildkite UI following the instructions in the documentation [here](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets#create-a-secret-using-the-buildkite-interface).

### One at a time

Create a Buildkite secret for each variable that you need to store. Paste the value of the secret into buildkite.com directly.

A `pipeline.yml` like this will read each secret out into a ENV variable:

```yml
steps:
  - command: echo "The content of ANIMAL is \$ANIMAL"
    plugins:
      - secrets#v1.0.2:
          variables:
            ANIMAL: llamas
            FOO: bar
```

### Multiple

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
      - secrets#v1.0.2:
          env: "llamas"
```

## Options

### `provider` (optional, string, default: `buildkite`)

The secrets provider to use. Currently only `buildkite` is supported.

### `env` (optional, string)
The secret key name to fetch multiple from Buildkite secrets.

### `variables` (optional, object)
Specify a dictionary of `key: value` pairs to inject as environment variables, where the key is the name of the
environment variable to be set, and the value is the Buildkite Secret key.

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
      - secrets#v1.0.2:
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
      - secrets#v1.0.2:
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
