defmodule LicenseCore.License do
  @moduledoc """
  Represents a decoded, verified license.
  """

  @enforce_keys [:email, :expires, :tier]
  defstruct [:email, :expires, :tier]

  @type t :: %__MODULE__{
          email: String.t(),
          expires: Date.t(),
          tier: String.t()
        }

  @doc """
  Parse a payload string into a License struct.
  Payload format: "email|YYYY-MM-DD|tier"
  """
  def from_payload(payload) when is_binary(payload) do
    case String.split(payload, "|") do
      [email, expiry_str, tier] ->
        case Date.from_iso8601(expiry_str) do
          {:ok, date} ->
            {:ok, %__MODULE__{email: email, expires: date, tier: tier}}

          {:error, _} ->
            {:error, :invalid_expiry}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  @doc """
  Encode a License struct into a payload string.
  """
  def to_payload(%__MODULE__{email: email, expires: expires, tier: tier}) do
    "#{email}|#{Date.to_iso8601(expires)}|#{tier}"
  end

  @doc """
  Check if the license has expired.
  """
  def expired?(%__MODULE__{expires: expires}) do
    Date.compare(Date.utc_today(), expires) == :gt
  end
end
