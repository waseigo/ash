defmodule Ash.DataLayer.Sort do
  def process(resource, empty) when empty in [nil, []], do: {:ok, []}

  def process(resource, sort) when is_list(sort) do
    sort
    |> Enum.reduce({[], []}, fn
      {order, field}, {sorts, errors} when order in [:asc, :desc] ->
        if Ash.attribute(resource, field) do
          {sorts ++ [{order, field}], errors}
        else
          {sorts, ["invalid sort attribute: #{field}" | errors]}
        end

      sort, {sorts, errors} ->
        {sorts, ["invalid sort: #{inspect(sort)}" | errors]}
    end)
    |> case do
      {sorts, []} -> {:ok, sorts}
      {_, errors} -> {:error, errors}
    end
  end

  def process(resource, _), do: {:error, "invalid sort"}
end
