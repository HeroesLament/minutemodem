defmodule LicenseAPI.Admin do
  @moduledoc """
  Administrative operations for the licensing server.

  These functions are intended to be called from IEx on the server.

  ## First-time setup

      license_api remote

      iex> LicenseAPI.Admin.provision_keypair("/etc/minutemodem/license_private.key")
      iex> LicenseAPI.Admin.create_token("macbook-primary")

  ## License lifecycle

      iex> LicenseAPI.Admin.issue_license("user@example.com", "pro", ~D[2027-02-08])
      iex> LicenseAPI.Admin.renew_license("user@example.com", ~D[2028-02-08])
      iex> LicenseAPI.Admin.change_tier("user@example.com", "enterprise")
      iex> LicenseAPI.Admin.transfer_license("old@owner.com", "new@owner.com")
      iex> LicenseAPI.Admin.revoke_license("user@example.com")
      iex> LicenseAPI.Admin.refund_license("user@example.com")

  ## Inspection

      iex> LicenseAPI.Admin.list_licenses()
      iex> LicenseAPI.Admin.inspect_license("user@example.com")
      iex> LicenseAPI.Admin.activations("user@example.com")
      iex> LicenseAPI.Admin.expiring_within(30)
      iex> LicenseAPI.Admin.stats()
      iex> LicenseAPI.Admin.search("callsign")

  ## Token management

      iex> LicenseAPI.Admin.create_token("stripe-webhook", "webhook")
      iex> LicenseAPI.Admin.list_tokens()
      iex> LicenseAPI.Admin.revoke_token("macbook-primary")
  """

  alias LicenseAPI.{Repo, KeyStore}
  alias LicenseAPI.Schemas.{License, ApiToken, Activation}
  import Ecto.Query

  # =================================================================
  # Keypair Provisioning
  # =================================================================

  @doc """
  Generate an Ed25519 keypair and write the private key to the given path.
  Prints the public key for baking into client builds.
  """
  def provision_keypair(path, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if File.exists?(path) and not force do
      IO.puts("""
      ⚠  Private key already exists at: #{path}
         Pass `force: true` to overwrite.
      """)
      {:error, :already_exists}
    else
      {pub, priv} = LicenseCore.Key.generate_keypair()

      priv_b64 = Base.url_encode64(priv, padding: false)
      pub_b64 = Base.url_encode64(pub, padding: false)

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, priv_b64)
      File.chmod!(path, 0o600)

      GenServer.call(KeyStore, {:reload, priv, pub})

      IO.puts("""

      ✓ Ed25519 keypair provisioned!

      Private key: #{path} (mode 0600)

      Public key (bake into client builds):
        #{pub_b64}

      Config line:
        config :license_core, :public_key, "#{pub_b64}"

      ⚠  Back up the private key securely. If lost, all existing licenses
         become unverifiable and you must re-provision + re-issue everything.
      """)

      {:ok, %{public_key: pub_b64, private_key_path: path}}
    end
  end

  # =================================================================
  # Token Management
  # =================================================================

  def create_token(label, scope \\ "admin") when scope in ~w(admin webhook) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    plaintext = "mm_#{scope}_#{raw}"
    prefix = String.slice(plaintext, 0, 12)
    hash = Bcrypt.hash_pwd_salt(plaintext)

    case %ApiToken{}
         |> ApiToken.changeset(%{label: label, token_hash: hash, token_prefix: prefix, scope: scope})
         |> Repo.insert() do
      {:ok, _token} ->
        IO.puts("""

        ✓ API token created!
          Label:  #{label}
          Scope:  #{scope}
          Token:  #{plaintext}

        ⚠  Save this token now — it will NOT be shown again.
        """)
        {:ok, plaintext}

      {:error, changeset} ->
        IO.puts("✗ Failed: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  def list_tokens do
    tokens = Repo.all(from(t in ApiToken, order_by: [desc: t.inserted_at]))

    if tokens == [] do
      IO.puts("No API tokens.")
    else
      IO.puts("\n  Tokens:\n")
      for t <- tokens do
        status = if t.active, do: "✓", else: "✗"
        IO.puts("  #{status} #{t.token_prefix}...  #{t.label}  [#{t.scope}]  #{t.inserted_at}")
      end
      IO.puts("")
    end
    tokens
  end

  def revoke_token(label) do
    case Repo.get_by(ApiToken, label: label) do
      nil -> IO.puts("✗ Not found: #{label}"); {:error, :not_found}
      token ->
        Repo.update!(Ecto.Changeset.change(token, active: false))
        IO.puts("✓ Token '#{label}' revoked.")
        :ok
    end
  end

  # =================================================================
  # License Lifecycle
  # =================================================================

  def issue_license(email, tier \\ "standard", expires, notes \\ nil) do
    payload = LicenseCore.License.to_payload(%LicenseCore.License{
      email: email, tier: tier, expires: expires
    })

    case KeyStore.sign(payload) do
      {:ok, key_string} ->
        {:ok, license} =
          %License{}
          |> License.changeset(%{email: email, tier: tier, expires: expires, notes: notes})
          |> Ecto.Changeset.put_change(:key_string, key_string)
          |> Repo.insert()

        IO.puts("""

        ✓ License issued!
          ID:      #{license.id}
          Email:   #{email}
          Tier:    #{tier}
          Expires: #{Date.to_iso8601(expires)}

          Key:
          #{key_string}
        """)
        {:ok, key_string}

      {:error, :not_provisioned} ->
        IO.puts("✗ No signing key. Run provision_keypair/1 first.")
        {:error, :not_provisioned}
    end
  end

  def issue_trial(email, opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    expires = Date.add(Date.utc_today(), days)
    issue_license(email, "trial", expires, "Trial license — #{days} days")
  end

  def renew_license(email, new_expires) do
    case get_active_license(email) do
      nil -> IO.puts("✗ No active license for: #{email}"); {:error, :not_found}
      old ->
        payload = LicenseCore.License.to_payload(%LicenseCore.License{
          email: email, tier: old.tier, expires: new_expires
        })

        case KeyStore.sign(payload) do
          {:ok, key_string} ->
            Repo.update!(Ecto.Changeset.change(old, status: "superseded"))

            {:ok, license} =
              %License{}
              |> License.changeset(%{
                email: email, tier: old.tier, expires: new_expires,
                notes: "Renewed from #{old.id}"
              })
              |> Ecto.Changeset.put_change(:key_string, key_string)
              |> Repo.insert()

            IO.puts("""

            ✓ License renewed!
              ID:      #{license.id}
              Expires: #{Date.to_iso8601(new_expires)} (was: #{old.expires})

              Key:
              #{key_string}
            """)
            {:ok, key_string}

          {:error, :not_provisioned} ->
            IO.puts("✗ Not provisioned."); {:error, :not_provisioned}
        end
    end
  end

  def change_tier(email, new_tier) do
    case get_active_license(email) do
      nil -> IO.puts("✗ No active license for: #{email}"); {:error, :not_found}
      old ->
        payload = LicenseCore.License.to_payload(%LicenseCore.License{
          email: email, tier: new_tier, expires: old.expires
        })

        case KeyStore.sign(payload) do
          {:ok, key_string} ->
            Repo.update!(Ecto.Changeset.change(old, status: "superseded"))

            {:ok, _} =
              %License{}
              |> License.changeset(%{
                email: email, tier: new_tier, expires: old.expires,
                notes: "Tier change: #{old.tier} → #{new_tier}, prev: #{old.id}"
              })
              |> Ecto.Changeset.put_change(:key_string, key_string)
              |> Repo.insert()

            IO.puts("✓ Tier changed: #{old.tier} → #{new_tier}\n\n  Key:\n  #{key_string}")
            {:ok, key_string}

          {:error, :not_provisioned} ->
            IO.puts("✗ Not provisioned."); {:error, :not_provisioned}
        end
    end
  end

  def transfer_license(from_email, to_email) do
    case get_active_license(from_email) do
      nil -> IO.puts("✗ No active license for: #{from_email}"); {:error, :not_found}
      old ->
        payload = LicenseCore.License.to_payload(%LicenseCore.License{
          email: to_email, tier: old.tier, expires: old.expires
        })

        case KeyStore.sign(payload) do
          {:ok, key_string} ->
            Repo.update!(Ecto.Changeset.change(old, status: "transferred"))

            {:ok, _} =
              %License{}
              |> License.changeset(%{
                email: to_email, tier: old.tier, expires: old.expires,
                notes: "Transferred from #{from_email}, prev: #{old.id}"
              })
              |> Ecto.Changeset.put_change(:key_string, key_string)
              |> Repo.insert()

            IO.puts("✓ Transferred: #{from_email} → #{to_email}\n\n  Key:\n  #{key_string}")
            {:ok, key_string}

          {:error, :not_provisioned} ->
            IO.puts("✗ Not provisioned."); {:error, :not_provisioned}
        end
    end
  end

  def update_email(old_email, new_email) do
    transfer_license(old_email, new_email)
  end

  def revoke_license(email) do
    case get_active_license(email) do
      nil -> IO.puts("✗ No active license for: #{email}"); {:error, :not_found}
      license ->
        Repo.update!(Ecto.Changeset.change(license, status: "revoked"))
        IO.puts("✓ Revoked: #{email} (key valid offline until #{license.expires})")
        :ok
    end
  end

  def refund_license(email) do
    case get_active_license(email) do
      nil -> IO.puts("✗ No active license for: #{email}"); {:error, :not_found}
      license ->
        Repo.update!(Ecto.Changeset.change(license, status: "refunded"))
        IO.puts("✓ Refunded: #{email} (key valid offline until #{license.expires})")
        :ok
    end
  end

  def add_note(email, note) do
    case get_active_license(email) do
      nil -> IO.puts("✗ No active license for: #{email}"); {:error, :not_found}
      license ->
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        existing = license.notes || ""
        updated = if existing == "", do: "[#{timestamp}] #{note}", else: "#{existing}\n[#{timestamp}] #{note}"
        Repo.update!(Ecto.Changeset.change(license, notes: updated))
        IO.puts("✓ Note added to #{email}")
        :ok
    end
  end

  # =================================================================
  # Inspection & Reports
  # =================================================================

  def list_licenses(status \\ nil) do
    query = from(l in License, order_by: [desc: l.inserted_at])
    query = if status, do: where(query, status: ^status), else: query
    licenses = Repo.all(query)

    if licenses == [] do
      IO.puts("No licenses found.")
    else
      IO.puts("\n  Licenses:\n")
      for l <- licenses do
        IO.puts("  #{l.email}  [#{l.tier}]  exp: #{l.expires}  #{l.status}  #{l.id}")
      end
      IO.puts("\n  Total: #{length(licenses)}")
    end
    licenses
  end

  def inspect_license(email) do
    licenses =
      License
      |> where(email: ^email)
      |> order_by(desc: :inserted_at)
      |> Repo.all()

    if licenses == [] do
      IO.puts("No licenses for: #{email}")
    else
      for l <- licenses do
        activation_count =
          Repo.aggregate(from(a in Activation, where: a.license_id == ^l.id), :count)

        IO.puts("""
          License: #{l.id}
            Email:       #{l.email}
            Tier:        #{l.tier}
            Expires:     #{l.expires}
            Status:      #{l.status}
            Activations: #{activation_count}
            Notes:       #{l.notes || "(none)"}
            Issued:      #{l.inserted_at}
            Key prefix:  #{String.slice(l.key_string, 0, 30)}...
        """)
      end
    end
    licenses
  end

  def activations(email) do
    license_ids =
      License
      |> where(email: ^email)
      |> select([l], l.id)
      |> Repo.all()

    activations =
      Activation
      |> where([a], a.license_id in ^license_ids)
      |> order_by(desc: :updated_at)
      |> Repo.all()

    if activations == [] do
      IO.puts("No activations for: #{email}")
    else
      IO.puts("\n  Activations for #{email}:\n")
      for a <- activations do
        IO.puts("  #{a.machine_hostname || "unknown"}  #{a.machine_os}  #{a.machine_arch}  #{a.ip_address}  last: #{a.updated_at}")
      end
      IO.puts("\n  Total: #{length(activations)} machines")
    end
    activations
  end

  def expiring_within(days \\ 30) do
    cutoff = Date.add(Date.utc_today(), days)

    licenses =
      from(l in License,
        where: l.status == "active" and l.expires <= ^cutoff and l.expires >= ^Date.utc_today(),
        order_by: l.expires
      )
      |> Repo.all()

    if licenses == [] do
      IO.puts("No licenses expiring within #{days} days.")
    else
      IO.puts("\n  Expiring within #{days} days:\n")
      for l <- licenses do
        days_left = Date.diff(l.expires, Date.utc_today())
        IO.puts("  #{l.email}  [#{l.tier}]  #{l.expires}  (#{days_left} days left)")
      end
    end
    licenses
  end

  def search(query) do
    pattern = "%#{query}%"

    licenses =
      from(l in License,
        where: like(l.email, ^pattern) or like(l.notes, ^pattern),
        order_by: [desc: l.inserted_at]
      )
      |> Repo.all()

    if licenses == [] do
      IO.puts("No results for: #{query}")
    else
      IO.puts("\n  Search results for \"#{query}\":\n")
      for l <- licenses do
        IO.puts("  #{l.email}  [#{l.tier}]  #{l.status}  exp: #{l.expires}")
      end
    end
    licenses
  end

  def stats do
    by_status =
      from(l in License, group_by: l.status, select: {l.status, count(l.id)})
      |> Repo.all()

    by_tier =
      from(l in License, where: l.status == "active", group_by: l.tier, select: {l.tier, count(l.id)})
      |> Repo.all()

    total_activations = Repo.aggregate(Activation, :count)
    unique_machines = Repo.one(from(a in Activation, select: count(a.machine_id, :distinct)))

    IO.puts("""

    License Stats:
      By status: #{Enum.map_join(by_status, ", ", fn {s, c} -> "#{s}: #{c}" end)}
      By tier:   #{Enum.map_join(by_tier, ", ", fn {t, c} -> "#{t}: #{c}" end)}
      Activations: #{total_activations} total, #{unique_machines} unique machines
    """)

    %{by_status: Map.new(by_status), by_tier: Map.new(by_tier),
      activations: total_activations, unique_machines: unique_machines}
  end

  # =================================================================
  # Bulk
  # =================================================================

  def issue_bulk(entries) when is_list(entries) do
    IO.puts("\n  Issuing #{length(entries)} licenses...\n")

    results =
      Enum.map(entries, fn {email, tier, expires} ->
        case issue_license(email, tier, expires) do
          {:ok, key} -> {email, :ok, key}
          {:error, reason} -> {email, :error, reason}
        end
      end)

    ok = Enum.count(results, fn {_, s, _} -> s == :ok end)
    IO.puts("\n  Done: #{ok}/#{length(entries)} succeeded.")
    results
  end

  # =================================================================
  # Validate (check a key against the DB)
  # =================================================================

  def validate_key(key_string) do
    case LicenseCore.Key.verify(key_string) do
      {:ok, license} ->
        key_hash = :crypto.hash(:sha256, key_string) |> Base.encode16(case: :lower)

        db_match =
          Repo.all(from(l in License, select: {l.id, l.key_string, l.status}))
          |> Enum.find(fn {_id, ks, _status} ->
            :crypto.hash(:sha256, ks) |> Base.encode16(case: :lower) == key_hash
          end)

        case db_match do
          {id, _, status} ->
            IO.puts("""
            ✓ Key is cryptographically valid
              Email:   #{license.email}
              Tier:    #{license.tier}
              Expires: #{license.expires}
              Expired: #{LicenseCore.License.expired?(license)}
              DB ID:   #{id}
              Status:  #{status}
            """)
            {:ok, %{license: license, db_status: status, db_id: id}}

          nil ->
            IO.puts("""
            ⚠ Key is cryptographically valid but NOT found in database
              Email:   #{license.email}
              Tier:    #{license.tier}
              Expires: #{license.expires}
              This key may have been issued before the DB existed or is forged.
            """)
            {:ok, %{license: license, db_status: :unknown}}
        end

      {:error, reason} ->
        IO.puts("✗ Invalid key: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # =================================================================
  # Internal
  # =================================================================

  defp get_active_license(email) do
    Repo.one(
      from(l in License,
        where: l.email == ^email and l.status == "active",
        order_by: [desc: l.inserted_at],
        limit: 1
      )
    )
  end
end
