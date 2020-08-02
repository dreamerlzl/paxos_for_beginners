defmodule KVOperation do
  defstruct [:type, :key, :value, :id]
  @type t(tp, k, v, i) :: %KVOperation{type: tp, key: k, value: v, id: i}
  @type t :: %KVOperation{type: atom(), key: any(), value: any(), id: String}

  def gen_id() do
    min = String.to_integer("100000", 36)
    max = String.to_integer("ZZZZZZ", 36)

    max
    |> Kernel.-(min)
    |> :rand.uniform()
    |> Kernel.+(min)
    |> Integer.to_string(36)
  end
end
