defmodule LicenseCore.Key do
  @moduledoc """
  Ed25519 key operations for license signing and verification.

  The public key is baked into the application at compile time.
  The private key is never shipped — it lives offline with the developer
  and is used only by the `mix license.gen` task to create keys.

  ## Key Format

      MM-<base64url payload>.<base64url signature>

  """

  alias LicenseCore.License

  # ---------------------------------------------------------------
  # Public key (baked in at compile time)
  # Replace this with your actual public key after running:
  #   mix license.keygen
  # ---------------------------------------------------------------
  @public_key_b64 Application.compile_env(
                    :license_core,
                    :public_key,
                    "REPLACE_ME_WITH_REAL_PUBLIC_KEY"
                  )

  @prefix "MM-"

  @doc """
  Verify a license key string. Returns {:ok, License.t()} or {:error, reason}.
  """
  def verify(key_string) when is_binary(key_string) do
    with {:ok, payload_bytes, signature} <- parse(key_string),
         :ok <- verify_signature(payload_bytes, signature),
         {:ok, license} <- License.from_payload(payload_bytes) do
      {:ok, license}
    end
  end

  @doc """
  Sign a payload string with a private key. Returns a full key string.
  Used offline by the key generation mix task — never called in production.
  """
  def sign(payload, private_key_bytes) when is_binary(payload) and is_binary(private_key_bytes) do
    signature = :crypto.sign(:eddsa, :none, payload, [private_key_bytes, :ed25519])

    payload_b64 = Base.url_encode64(payload, padding: false)
    signature_b64 = Base.url_encode64(signature, padding: false)

    @prefix <> payload_b64 <> "." <> signature_b64
  end

  @doc """
  Generate a new Ed25519 keypair. Returns {public_key, private_key} as raw bytes.
  """
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  # ---------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------

  defp parse(@prefix <> rest) do
    case String.split(rest, ".", parts: 2) do
      [payload_b64, signature_b64] ->
        with {:ok, payload} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, signature} <- Base.url_decode64(signature_b64, padding: false) do
          {:ok, payload, signature}
        else
          _ -> {:error, :invalid_encoding}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp parse(_), do: {:error, :invalid_format}

  defp verify_signature(payload, signature) do
    public_key =
      case Base.url_decode64(@public_key_b64, padding: false) do
        {:ok, key} -> key
        :error -> Base.decode64!(@public_key_b64)
      end

    case :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :verification_failed}
  end
end
