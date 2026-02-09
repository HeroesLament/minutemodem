defmodule LicenseAPI.KeyStore do
  @moduledoc """
  Holds the Ed25519 private key in memory.

  Reads the private key from a file on disk at startup.
  The key never leaves this process — signing operations
  go through this module.
  """
  use GenServer

  require Logger

  # ---------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sign a license payload. Returns the full key string (MM-...).
  """
  def sign(payload) when is_binary(payload) do
    GenServer.call(__MODULE__, {:sign, payload})
  end

  @doc """
  Returns the public key as a base64url-encoded string.
  Used during provisioning to give you the value to bake into client builds.
  """
  def public_key_b64 do
    GenServer.call(__MODULE__, :public_key_b64)
  end

  @doc """
  Returns true if the key store has been provisioned with a keypair.
  """
  def provisioned? do
    GenServer.call(__MODULE__, :provisioned?)
  end

  # ---------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    case load_private_key() do
      {:ok, priv, pub} ->
        Logger.info("KeyStore: private key loaded successfully")
        {:ok, %{private_key: priv, public_key: pub}}

      :not_configured ->
        Logger.warning("KeyStore: no private key configured — run LicenseAPI.Admin.provision_keypair/1")
        {:ok, %{private_key: nil, public_key: nil}}

      {:error, reason} ->
        Logger.error("KeyStore: failed to load private key: #{inspect(reason)}")
        {:ok, %{private_key: nil, public_key: nil}}
    end
  end

  @impl true
  def handle_call({:sign, _payload}, _from, %{private_key: nil} = state) do
    {:reply, {:error, :not_provisioned}, state}
  end

  def handle_call({:sign, payload}, _from, %{private_key: priv} = state) do
    key_string = LicenseCore.Key.sign(payload, priv)
    {:reply, {:ok, key_string}, state}
  end

  def handle_call(:public_key_b64, _from, %{public_key: nil} = state) do
    {:reply, {:error, :not_provisioned}, state}
  end

  def handle_call(:public_key_b64, _from, %{public_key: pub} = state) do
    {:reply, {:ok, Base.url_encode64(pub, padding: false)}, state}
  end

  def handle_call(:provisioned?, _from, state) do
    {:reply, state.private_key != nil, state}
  end

  @doc false
  def handle_call({:reload, priv, pub}, _from, _state) do
    {:reply, :ok, %{private_key: priv, public_key: pub}}
  end

  # ---------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------

  defp load_private_key do
    path = private_key_path()

    cond do
      is_nil(path) ->
        :not_configured

      not File.exists?(path) ->
        {:error, {:file_not_found, path}}

      true ->
        case File.read(path) do
          {:ok, contents} ->
            priv_b64 = String.trim(contents)

            with {:ok, priv_bytes} <- decode_key(priv_b64) do
              # Derive public key from private key
              # Ed25519 private keys are 32 bytes; the public key can be derived
              {pub, ^priv_bytes} = :crypto.generate_key(:eddsa, :ed25519, priv_bytes)
              {:ok, priv_bytes, pub}
            end

          {:error, reason} ->
            {:error, {:read_failed, reason}}
        end
    end
  end

  defp decode_key(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, _} = ok -> ok
      :error ->
        case Base.decode64(b64) do
          {:ok, _} = ok -> ok
          :error -> {:error, :invalid_key_encoding}
        end
    end
  end

  defp private_key_path do
    Application.get_env(:license_api, :private_key_path)
  end
end
