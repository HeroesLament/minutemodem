defmodule Mix.Tasks.License.Sign do
  @shortdoc "Sign a new license key"
  @moduledoc """
  Create a signed license key.

      mix license.sign --email user@example.com --tier pro --expires 2027-01-01 --key path/to/license_private.key

  Outputs the full license key string (MM-...) to stdout.
  """
  use Mix.Task

  alias LicenseCore.{License, Key}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [email: :string, tier: :string, expires: :string, key: :string]
      )

    email = Keyword.fetch!(opts, :email)
    tier = Keyword.get(opts, :tier, "standard")
    expires = Keyword.fetch!(opts, :expires)
    key_path = Keyword.fetch!(opts, :key)

    # Validate expiry
    case Date.from_iso8601(expires) do
      {:ok, _} -> :ok
      {:error, _} -> Mix.raise("Invalid date format: #{expires}. Use YYYY-MM-DD.")
    end

    # Read private key
    priv_b64 = File.read!(key_path) |> String.trim()

    priv_bytes =
      case Base.url_decode64(priv_b64, padding: false) do
        {:ok, bytes} -> bytes
        :error -> Base.decode64!(priv_b64)
      end

    # Build and sign
    license = %License{email: email, expires: Date.from_iso8601!(expires), tier: tier}
    payload = License.to_payload(license)
    key_string = Key.sign(payload, priv_bytes)

    Mix.shell().info("""
    License key generated:

    #{key_string}

    For:     #{email}
    Tier:    #{tier}
    Expires: #{expires}
    """)
  end
end
