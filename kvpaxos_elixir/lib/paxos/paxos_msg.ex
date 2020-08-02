defmodule Message do

  defmodule Prepare do
    defstruct [:index, :pn]
  end

  defmodule Promise do
    defstruct [:max_proposal, :accepted_proposal,
               :accepted_value]
  end

  defmodule Accept do
    defstruct [:index, :pn, :value, :done_index, :sender]
  end

  defmodule Accepted do
    defstruct [:done_index, :max_proposal]
  end

  defmodule Learn do
    defstruct [:index, :chosen_value]
  end

end
