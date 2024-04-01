defmodule MinutemodemSimnet.Epoch.Contract do
  @moduledoc """
  Negotiated contract for an epoch.

  Fixed for the duration of the epoch. All rigs and channels
  must agree on these parameters.
  """

  @type representation :: :audio_f32 | :iq_f32

  @type t :: %__MODULE__{
          sample_rate: pos_integer(),
          block_ms: pos_integer(),
          samples_per_block: pos_integer(),
          representation: representation()
        }

  defstruct [
    :sample_rate,
    :block_ms,
    :samples_per_block,
    :representation
  ]

  @doc """
  Creates a new contract with validated parameters.
  """
  def new(opts) do
    sample_rate = Keyword.fetch!(opts, :sample_rate)
    block_ms = Keyword.fetch!(opts, :block_ms)
    representation = Keyword.get(opts, :representation, :audio_f32)

    samples_per_block = div(sample_rate * block_ms, 1000)

    contract = %__MODULE__{
      sample_rate: sample_rate,
      block_ms: block_ms,
      samples_per_block: samples_per_block,
      representation: representation
    }

    case validate(contract) do
      :ok -> {:ok, contract}
      error -> error
    end
  end

  @doc """
  Validates a contract against Appendix E requirements.
  """
  def validate(%__MODULE__{} = contract) do
    cond do
      contract.sample_rate not in [9600, 76800] ->
        {:error, :invalid_sample_rate}

      contract.block_ms < 1 or contract.block_ms > 5 ->
        {:error, :invalid_block_ms}

      contract.representation not in [:audio_f32, :iq_f32] ->
        {:error, :invalid_representation}

      true ->
        :ok
    end
  end

  @doc """
  Returns the expected binary size for one block of samples.
  """
  def block_byte_size(%__MODULE__{} = contract) do
    bytes_per_sample =
      case contract.representation do
        :audio_f32 -> 4
        :iq_f32 -> 8
      end

    contract.samples_per_block * bytes_per_sample
  end
end
