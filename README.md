# Minutemodem

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `minutemodem` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:minutemodem, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/minutemodem>.


rig1_id = "2239f04a-d0a7-48af-bab0-78b8f3c64300"
rig2_id = "d938cc0c-ea01-424f-82e4-45f106884d3e"
alias MinuteModemCore.ALE.Link
Link.scan(rig2_id)
Process.sleep(500)
Link.call(rig1_id, 0x1234)
Process.sleep(500)
Link.stop(rig2_id)
Link.scan(rig2_id)
Link.call(rig1_id, 0x1234)
Process.sleep(500)
Link.stop(rig2_id)
Link.scan(rig2_id)
Link.call(rig1_id, 0x1234)


# Setup
rig1_id = "2239f04a-d0a7-48af-bab0-78b8f3c64300"
rig2_id = "d938cc0c-ea01-424f-82e4-45f106884d3e"
alias MinuteModemCore.ALE.Link

# Start scanning
Link.scan(rig2_id)
Process.sleep(500)

# Initiate call - Deep WALE takes ~3 seconds + response time
Link.call(rig1_id, 0x1234)
Process.sleep(5000)  # Wait for full handshake

# Now linked - terminate cleanly
Link.stop(rig2_id)
Process.sleep(1000)  # Wait for LsuTerm to propagate

# Second cycle
Link.scan(rig2_id)
Process.sleep(500)

Link.call(rig1_id, 0x1234)
Process.sleep(5000)

Link.stop(rig2_id)
Process.sleep(1000)

# Now linked - terminate cleanly
Link.stop(rig2_id)
Process.sleep(1000)  # Wait for LsuTerm to propagate

# Second cycle
Link.scan(rig2_id)
Process.sleep(500)

Link.call(rig1_id, 0x1234)
Process.sleep(5000)

Link.stop(rig2_id)
Process.sleep(1000)

# Now linked - terminate cleanly
Link.stop(rig2_id)
Process.sleep(1000)  # Wait for LsuTerm to propagate

Logger.configure(level: :debug)