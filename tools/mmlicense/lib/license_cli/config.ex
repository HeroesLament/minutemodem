defmodule LicenseCLI.Config do
  @moduledoc """
  Manages the CLI configuration file at ~/.config/mmlicense/config.json

  Stores the API URL and bearer token.
  """

  @config_dir ".config/mmlicense"
  @config_file "config.json"

  defstruct [:api_url, :token]

  def load do
    path = config_path()

    case File.read(path) do
      {:ok, contents} ->
        data = Jason.decode!(contents)

        %__MODULE__{
          api_url: data["api_url"],
          token: data["token"]
        }

      {:error, _} ->
        nil
    end
  end

  def load! do
    case load() do
      nil ->
        Owl.IO.puts([Owl.Data.tag("✗ Not configured. Run: mmlicense config --api-url URL --token TOKEN", :red)])
        System.halt(1)

      %__MODULE__{api_url: nil} ->
        Owl.IO.puts([Owl.Data.tag("✗ Missing api_url in config.", :red)])
        System.halt(1)

      %__MODULE__{token: nil} ->
        Owl.IO.puts([Owl.Data.tag("✗ Missing token in config.", :red)])
        System.halt(1)

      config ->
        config
    end
  end

  def save(api_url, token) do
    path = config_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    data = Jason.encode!(%{"api_url" => api_url, "token" => token}, pretty: true)
    File.write!(path, data)
    File.chmod!(path, 0o600)

    Owl.IO.puts([Owl.Data.tag("✓ Config saved to #{path}", :green)])
  end

  defp config_path do
    home = System.get_env("HOME", "/tmp")
    Path.join([home, @config_dir, @config_file])
  end
end
