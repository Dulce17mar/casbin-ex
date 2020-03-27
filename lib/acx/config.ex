defmodule Acx.Config do
  @moduledoc """
  A configuration file is a text files divided into named sections
  (optional). Brackets enclose each section name.

  A valid section name must starts with a lowercase letter and must
  contain only alphanumeric characters and optionally an underscore `_`.

  Each section contains key/value pairs separated by an equal sing(=).

  If there is no section specified, all the key-value pairs will be
  put under the default section `:undefined_section`.

  An example of a valid configuration file:

    [section_1]
    key1 = value
    key2 = value

    [section_2]
    key1 = value
    key2 = value
  """

  @enforce_keys [:sections]
  defstruct sections: []

  alias __MODULE__

  @whitespace 32
  @new_line 10
  @eq 61
  @default_section :undefined_section

  @doc """
  Reads a config file and convert it into `%Config{}` struct.
  """
  def new(config_file) do
    # TODO: There are few things to keep in mind:
    #
    #   1. What if the file does not exist or something went wrong while
    #      trying to read the file content?
    #
    #   2. Reporting `syntax` error when something was wrong in the
    #      config file ins't enough. Wrong at what position?
    #
    #   3. It doesn't feel right to me to return ok tuple in a `new`
    #      function.
    config_file
    |> File.read!
    |> parse()
    |> convert()
    |> case do
         {:error, _reason} ->
           {:error, "syntax error in the config file #{config_file}"}

         {:ok, sections} ->
           {:ok, %Config{sections: sections}}
       end
  end

  #
  # Convert parsing result to config list.
  #
  # An example of valid parsing result:
  #
  # `[:section_name, :eq, 'v2', 'k2', :eq, 'v1', 'k1']`
  #
  # The resulting config would be:
  #
  # `[section_name: [k1: "v1", k2: "v2"]]`

  defp convert({:ok, tokens}), do: convert(tokens, [])

  defp convert({:error, reason, _pos}), do: {:error, reason}

  defp convert([sec | rest], ret) when is_atom(sec) and sec != :eq do
    next_section = {sec, []}
    convert(rest, [next_section | ret])
  end

  defp convert([:eq | rest], [{sec, data} | ret]) do
    {succeeds, rem} = get_key_val(rest)

    case succeeds do
      [key_str | tokens] ->
        key = :erlang.list_to_atom(key_str)

        value =
          tokens
          |> List.flatten()
          |> :erlang.list_to_binary()

        convert(rem, [{sec, [{key, value} | data]} | ret])

      _ ->
        {:error, :syntax_error}
    end
  end

  defp convert([], final), do: {:ok, final}

  #
  # Parsing
  #

  defp parse(str) do
    init_pos = %{line: 0, col: 0}
    parse(String.to_charlist(str), [], [], [], init_pos)
  end

  #
  # See '[ch': starts new section
  #

  # Sections stack is empty.
  defp parse([91, ch | rest], [], eq_stack, tokens, pos)
  when ?a <= ch and ch <= ?z do
    case parse_section(rest) do
      {:error, _} ->
        {:error, :invalid_section, pos}

      {:ok, succeeds, rem, count} ->
        new_section = :erlang.list_to_atom([ch | succeeds])
        next_pos = next_col(pos, count + 2)
        parse(rem, [new_section], eq_stack, tokens, next_pos)
    end
  end

  # Sections stack is not empty.
  defp parse([91, ch | rest], [prev_section], [:eq], tokens, pos)
  when ?a <= ch and ch <= ?z do
    case parse_section(rest) do
      {:error, _} ->
        {:error, :invalid_section, pos}

      {:ok, succeeds, rem, count} ->
        new_section = :erlang.list_to_atom([ch | succeeds])
        next_pos = next_col(pos, count + 2)
        parse(rem, [new_section], [], [prev_section, :eq | tokens],
          next_pos)
    end
  end

  # See one of thes ==, != , >=, <=

  defp parse([ch, ?= | rest], [], eq_stack, tokens, pos)
  when ch in '=!><' do
    next_token = [ch, ?=]
    next_pos = next_col(pos, 2)
    parse(rest, [@default_section], eq_stack, [next_token | tokens],
      next_pos)
  end

  defp parse([ch, ?= | rest], secs, eq_stack, tokens, pos)
  when ch in '=!><' do
    next_token = [ch, ?=]
    next_pos = next_col(pos, 2)
    parse(rest, secs, eq_stack, [next_token | tokens], next_pos)
  end

  # See =

  defp parse([?= | rest], [], [], tokens, pos) do
    next_pos = next_col(pos)
    parse(rest, [@default_section], [:eq], tokens, next_pos)
  end

  defp parse([?= | rest], [], [:eq], [head | tail], pos) do
    next_pos = next_col(pos)
    parse(rest, [@default_section], [:eq], [head, :eq | tail], next_pos)
  end

  defp parse([?= | rest], secs, [], tokens, pos) do
    next_pos = next_col(pos)
    parse(rest, secs, [:eq], tokens, next_pos)
  end

  defp parse([?= | rest], secs, [:eq], [head | tail], pos) do
    next_pos = next_col(pos)
    parse(rest, secs, [:eq], [head, :eq | tail], next_pos)
  end

  # See a whitespace or new line

  defp parse([@whitespace | rest], secs, eq_stack, tokens, pos) do
    next_pos = next_col(pos)
    parse(rest, secs, eq_stack, tokens, next_pos)
  end

  defp parse([@new_line | rest], secs, eq_stack, tokens, pos) do
    next_pos = next_line(pos)
    parse(rest, secs, eq_stack, tokens, next_pos)
  end

  # See `#`.
  defp parse([35 | rest], secs, eq_stack, tokens, pos) do
    {rem, count} = skip_comment(rest)
    next_pos = next_col(pos, count + 1)
    parse(rem, secs, eq_stack, tokens, next_pos)
  end

  # See any other character.

  defp parse([ch | rest], [], eq_stack, tokens, pos) do
    {succeeds, rem, count} = parse_token(rest)
    next_token = [ch | succeeds]
    next_pos = next_col(pos, count + 1)
    parse(rem, [@default_section], eq_stack, [next_token | tokens],
      next_pos)
  end

  defp parse([ch | rest], secs, eq_stack, tokens, pos) do
    {succeeds, rem, count} = parse_token(rest)
    next_token = [ch | succeeds]
    next_pos = next_col(pos, count + 1)
    parse(rem, secs, eq_stack, [next_token | tokens], next_pos)
  end

  # Exhausted the input list

  defp parse([], [], [], tokens, _) do
    {:ok, tokens}
  end

  defp parse([], [s], [:eq], tokens, _) do
    {:ok, [s, :eq | tokens]}
  end

  # None of the above
  defp parse(_, _, _, _, pos), do: {:error, :syntax_error, pos}


  #
  # Helpers.
  #

  # Consume token.

  defp parse_token(list), do: parse_token(list, 0)

  defp parse_token([], _) do
    {[], [], 0}
  end

  defp parse_token([ch, ?= | rest], count) when ch in '!<>=' do
    {succeeds, rem, c} = parse_token(rest, 0)
    {[ch, ?= | succeeds], rem, count + 2 + c}
  end

  defp parse_token([ch | rest], count) do
    case (ch == @new_line ) || (ch == @whitespace) || (ch == @eq) do
      true ->
        {[], [ch | rest], 0}

      false ->
        {succeeds, rem, c} = parse_token(rest, 0)
        {[ch | succeeds], rem, count + 1 + c}
    end
  end

  # Parse section.

  defp parse_section(list), do: parse_section(list, 0)

  # See ']'
  defp parse_section([93 | rest], count) do
    {:ok, [], rest, count + 1}
  end

  # See lowercase character or _
  defp parse_section([ch | rest], count)
  when (?a <= ch and ch <= ?z) or (?0 <= ch and ch <= ?9) or ch == ?_ do
    case parse_section(rest, count + 1) do
      {:error, reason} ->
        {:error, reason}

      {:ok, succeeds, rem, c} ->
        {:ok, [ch | succeeds], rem, c}
    end
  end

  # See any other characters or list is empty.
  defp parse_section(_rest, _count) do
    {:error, :invalid_section}
  end

  # Skip comment line.

  defp skip_comment(line), do: skip_comment(line, 0)

  defp skip_comment([], count), do: {[], count}

  defp skip_comment([@new_line | rest], count) do
    {[@new_line | rest], count}
  end

  defp skip_comment([_|rest], count) do
    skip_comment(rest, count + 1)
  end


  # Update position.

  # Update the current position by `n` number of lines.
  defp next_line(%{line: l, col: _c}, n \\ 1), do: %{line: l + n, col: 0}

  # Update the current position by `n` number of columns.
  defp next_col(%{line: l, col: c}, n \\ 1), do: %{line: l, col: c + n}

  # Get key-value pair.

  defp get_key_val(list), do: get_key_val(list, [])

  defp get_key_val([], succeeds), do: {succeeds, []}

  defp get_key_val([token | rest], succeeds) when is_atom(token) do
    {succeeds, [token | rest]}
  end

  defp get_key_val([token | rest], succeeds) do
    get_key_val(rest, [token | succeeds])
  end

end
