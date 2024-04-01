defmodule MinuteModemCore.Settings.Schema do
  @enforce_keys [:version, :rigs]
  defstruct [
    :version,
    rigs: %{}
  ]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          rigs: map()
        }

  ## ------------------------------------------------------------------
  ## Defaults
  ## ------------------------------------------------------------------

  def default do
    %__MODULE__{
      version: 1,
      rigs: %{}
    }
  end

  ## ------------------------------------------------------------------
  ## Merge logic
  ## ------------------------------------------------------------------

  @spec merge(t(), map()) :: t()
  def merge(%__MODULE__{} = current, attrs) when is_map(attrs) do
    attrs
    |> sanitize_attrs()
    |> do_merge(current)
  end

  defp do_merge(attrs, current) do
    %__MODULE__{
      current
      | rigs: deep_merge(current.rigs, Map.get(attrs, :rigs, %{}))
    }
  end

  ## ------------------------------------------------------------------
  ## Validation
  ## ------------------------------------------------------------------

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{rigs: rigs}) when is_map(rigs) do
    :ok
  end

  def validate(_), do: {:error, :invalid_schema}

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  # Only allow known keys from callers
  defp sanitize_attrs(attrs) do
    attrs
    |> Map.drop([:version])
    |> Map.take([:rigs])
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _key, v1, v2 ->
      deep_merge(v1, v2)
    end)
  end

  defp deep_merge(_a, b), do: b
end
