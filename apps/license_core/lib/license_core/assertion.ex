defmodule LicenseCore.Assertion do
  @moduledoc """
  A signed activation assertion proving a license is authorized
  on a specific machine (or any machine for offline installs).

  Assertion payload format:

      key_hash|machine_id|issued_at_iso8601|expires_at_iso8601

  Where machine_id is "*" for offline/wildcard assertions.

  The assertion is signed with the same Ed25519 key as licenses,
  so the client can verify it offline with the baked-in public key.

  ## Format

      MMA-<base64url payload>.<base64url signature>

  (MMA- prefix to distinguish from MM- license keys)
  """

  @enforce_keys [:key_hash, :machine_id, :issued_at, :expires_at]
  defstruct [:key_hash, :machine_id, :issued_at, :expires_at]

  @type t :: %__MODULE__{
          key_hash: String.t(),
          machine_id: String.t(),
          issued_at: Date.t(),
          expires_at: Date.t()
        }

  @prefix "MMA-"

  @doc """
  Parse an assertion payload string into an Assertion struct.
  """
  def from_payload(payload) when is_binary(payload) do
    case String.split(payload, "|") do
      [key_hash, machine_id, issued_str, expires_str] ->
        with {:ok, issued} <- Date.from_iso8601(issued_str),
             {:ok, expires} <- Date.from_iso8601(expires_str) do
          {:ok,
           %__MODULE__{
             key_hash: key_hash,
             machine_id: machine_id,
             issued_at: issued,
             expires_at: expires
           }}
        else
          _ -> {:error, :invalid_assertion_dates}
        end

      _ ->
        {:error, :invalid_assertion_payload}
    end
  end

  @doc """
  Encode an Assertion struct into a payload string.
  """
  def to_payload(%__MODULE__{} = a) do
    "#{a.key_hash}|#{a.machine_id}|#{Date.to_iso8601(a.issued_at)}|#{Date.to_iso8601(a.expires_at)}"
  end

  @doc """
  Verify a signed assertion string. Returns {:ok, Assertion.t()} or {:error, reason}.
  Uses the same public key as license verification.
  """
  def verify(assertion_string) when is_binary(assertion_string) do
    with {:ok, payload_bytes, signature} <- parse(assertion_string),
         :ok <- verify_signature(payload_bytes, signature),
         {:ok, assertion} <- from_payload(payload_bytes) do
      {:ok, assertion}
    end
  end

  @doc """
  Sign an assertion payload with a private key. Returns the full assertion string.
  """
  def sign(payload, private_key_bytes) when is_binary(payload) and is_binary(private_key_bytes) do
    signature = :crypto.sign(:eddsa, :none, payload, [private_key_bytes, :ed25519])

    payload_b64 = Base.url_encode64(payload, padding: false)
    signature_b64 = Base.url_encode64(signature, padding: false)

    @prefix <> payload_b64 <> "." <> signature_b64
  end

  @doc """
  Check if the assertion has expired.
  """
  def expired?(%__MODULE__{expires_at: expires}) do
    Date.compare(Date.utc_today(), expires) == :gt
  end

  @doc """
  Check if the assertion matches a given machine.
  Wildcard assertions ("*") match any machine.
  """
  def matches_machine?(%__MODULE__{machine_id: "*"}, _machine_id), do: true

  def matches_machine?(%__MODULE__{machine_id: assertion_machine}, machine_id) do
    assertion_machine == machine_id
  end

  @doc """
  Check if the assertion matches a given license key (by hash).
  """
  def matches_key?(%__MODULE__{key_hash: assertion_hash}, key_string) do
    computed = :crypto.hash(:sha256, key_string) |> Base.encode16(case: :lower)
    assertion_hash == computed
  end

  @doc """
  Compute the hash of a license key string (for matching against assertions).
  """
  def key_hash(key_string) do
    :crypto.hash(:sha256, key_string) |> Base.encode16(case: :lower)
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
          _ -> {:error, :invalid_assertion_encoding}
        end

      _ ->
        {:error, :invalid_assertion_format}
    end
  end

  defp parse(_), do: {:error, :invalid_assertion_format}

  @public_key_b64 Application.compile_env(
                    :license_core,
                    :public_key,
                    "REPLACE_ME_WITH_REAL_PUBLIC_KEY"
                  )

  defp verify_signature(payload, signature) do
    public_key =
      case Base.url_decode64(@public_key_b64, padding: false) do
        {:ok, key} -> key
        :error -> Base.decode64!(@public_key_b64)
      end

    case :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_assertion_signature}
    end
  rescue
    _ -> {:error, :assertion_verification_failed}
  end
end
