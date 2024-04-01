defmodule Script do
  def main do
    case File.read(Path.relative("text.txt")) do
      {:ok, _data} ->
        loop(10)

      {:error, reason} ->
        IO.puts("File read error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp loop(0) do
    IO.puts("Done!")
    :ok
  end

  defp loop(n) do
    IO.puts("Hello, world! #{n}")
    Process.sleep(500)
    loop(n - 1)
  end
end

Script.main()
