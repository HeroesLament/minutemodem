defmodule Mix.Tasks.License.Keygen do
  @shortdoc "Generate a new Ed25519 keypair for license signing"
  @moduledoc """
  Generates a new Ed25519 keypair and writes it to files.

      mix license.keygen [--out DIR]

  This creates two files:
    - `license_private.key` — keep this SECRET. Used to sign licenses.
    - `license_public.key`  — bake this into your builds.

  After generating, set the public key in your config:

      config :license_core, :public_key, "the_base64_string_from_license_public.key"

  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [out: :string])
    dir = Keyword.get(opts, :out, ".")

    {pub, priv} = LicenseCore.Key.generate_keypair()

    pub_b64 = Base.url_encode64(pub, padding: false)
    priv_b64 = Base.url_encode64(priv, padding: false)

    pub_path = Path.join(dir, "license_public.key")
    priv_path = Path.join(dir, "license_private.key")

    File.mkdir_p!(dir)
    File.write!(pub_path, pub_b64)
    File.write!(priv_path, priv_b64)

    Mix.shell().info("""
    Ed25519 keypair generated!

    Public key:  #{pub_path}
    Private key: #{priv_path}

    Public key (for config):
      config :license_core, :public_key, "#{pub_b64}"

    ⚠  Keep license_private.key SECRET — do NOT commit it to source control.
       Add it to .gitignore now.
    """)
  end
end
