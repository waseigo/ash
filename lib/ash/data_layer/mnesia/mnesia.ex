defmodule Ash.DataLayer.Mnesia do
  @behaviour Ash.DataLayer

  @mnesia %Spark.Dsl.Section{
    name: :mnesia,
    describe: """
    A section for configuring the mnesia data layer
    """,
    examples: [
      """
      mnesia do
        table :custom_table
      end
      """
    ],
    schema: [
      table: [
        type: :atom,
        doc: "The table name to use, defaults to the name of the resource"
      ]
    ]
  }

  @moduledoc """
  An Mnesia backed Ash Datalayer.

  In your application initialization, you will need to call `Mnesia.create_schema([node()])`.

  Additionally, you will want to create your mnesia tables there.

  This data layer is *unoptimized*, fetching all records from a table and filtering them
  in memory. For that reason, it is not recommended to use it with large amounts of data. It can be
  great for prototyping or light usage, though.

    <!--- ash-hq-hide-start--> <!--- -->

  ## DSL Documentation

  ### Index

  #{Spark.Dsl.Extension.doc_index([@mnesia])}

  ### Docs

  #{Spark.Dsl.Extension.doc([@mnesia])}
  <!--- ash-hq-hide-stop--> <!--- -->
  """

  use Spark.Dsl.Extension,
    sections: [@mnesia],
    transformers: [Ash.DataLayer.Transformers.RequirePreCheckWith]

  alias Ash.Actions.Sort
  alias :mnesia, as: Mnesia

  @doc """
  Creates the table for each mnesia resource in an api
  """
  def start(api, resources \\ []) do
    Mnesia.create_schema([node()])
    Mnesia.start()

    Code.ensure_compiled(api)

    api
    |> Ash.Api.Info.resources()
    |> Enum.concat(resources)
    |> Enum.filter(&(__MODULE__ in Spark.extensions(&1)))
    |> Enum.flat_map(fn resource ->
      resource
      |> Ash.DataLayer.Mnesia.Info.table()
      |> List.wrap()
    end)
    |> Enum.each(&Mnesia.create_table(&1, attributes: [:_pkey, :val]))
  end

  defmodule Query do
    @moduledoc false
    defstruct [:api, :resource, :filter, :limit, :sort, relationships: %{}, offset: 0]
  end

  @deprecated "use Ash.DataLayer.Mnesia.Info.table/1 instead"
  defdelegate table(resource), to: Ash.DataLayer.Mnesia.Info

  @doc false
  @impl true
  def can?(_, :async_engine), do: true
  def can?(_, :multitenancy), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :upsert), do: true
  def can?(_, :create), do: true
  def can?(_, :read), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :sort), do: true
  def can?(_, :filter), do: true
  def can?(_, {:filter_relationship, _}), do: true
  def can?(_, {:query_aggregate, :count}), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :transact), do: true

  def can?(_, {:join, resource}) do
    # This is to ensure that these can't join, which is necessary for testing
    # if someone needs to use these both and *actually* needs real joins for private
    # ets resources then we can talk about making this only happen in ash tests
    not (Ash.DataLayer.data_layer(resource) == Ash.DataLayer.Ets &&
           Ash.DataLayer.Ets.Info.private?(resource))
  end

  def can?(_, {:filter_expr, _}), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, {:sort, _}), do: true

  def can?(_, _), do: false

  @doc false
  @impl true
  def resource_to_query(resource, api) do
    %Query{
      resource: resource,
      api: api
    }
  end

  @doc false
  @impl true
  def in_transaction?(_), do: Mnesia.is_transaction()

  @doc false
  @impl true
  def limit(query, offset, _), do: {:ok, %{query | limit: offset}}

  @doc false
  @impl true
  def offset(query, offset, _), do: {:ok, %{query | offset: offset}}

  @doc false
  @impl true
  def filter(query, filter, _resource) do
    if query.filter do
      {:ok, %{query | filter: Ash.Filter.add_to_filter!(query.filter, filter)}}
    else
      {:ok, %{query | filter: filter}}
    end
  end

  @doc false
  @impl true
  def sort(query, sort, _resource) do
    {:ok, %{query | sort: sort}}
  end

  @doc false
  @impl true
  def run_aggregate_query(%{api: api} = query, aggregates, resource) do
    case run_query(query, resource) do
      {:ok, results} ->
        Enum.reduce_while(aggregates, {:ok, %{}}, fn
          %{kind: :count, name: name, query: query}, {:ok, acc} ->
            api
            |> Ash.Filter.Runtime.filter_matches(results, Map.get(query || %{}, :filter))
            |> case do
              {:ok, matches} ->
                {:cont, {:ok, Map.put(acc, name, Enum.count(matches))}}

              {:error, error} ->
                {:halt, {:error, error}}
            end

          _, _ ->
            {:halt, {:error, "unsupported aggregate"}}
        end)

      {:error, error} ->
        {:error, error}
    end
    |> case do
      {:error, error} ->
        {:error, Ash.Error.to_ash_error(error)}

      other ->
        other
    end
  end

  @doc false
  @impl true
  def run_query(
        %Query{
          api: api,
          resource: resource,
          filter: filter,
          offset: offset,
          limit: limit,
          sort: sort
        },
        _resource
      ) do
    records =
      Mnesia.transaction(fn ->
        Mnesia.select(table(resource), [{:_, [], [:"$_"]}])
      end)

    case records do
      {:aborted, reason} ->
        {:error, reason}

      {:atomic, records} ->
        records
        |> Enum.map(&elem(&1, 2))
        |> Ash.DataLayer.Ets.cast_records(resource)
        |> case do
          {:ok, records} ->
            api
            |> Ash.Filter.Runtime.filter_matches(records, filter)
            |> case do
              {:ok, filtered} ->
                offset_records =
                  filtered
                  |> Sort.runtime_sort(sort)
                  |> Enum.drop(offset || 0)

                limited_records =
                  if limit do
                    Enum.take(offset_records, limit)
                  else
                    offset_records
                  end

                {:ok, limited_records}

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  @doc false
  @impl true
  def create(resource, changeset) do
    {:ok, record} = Ash.Changeset.apply_attributes(changeset)

    pkey =
      resource
      |> Ash.Resource.Info.primary_key()
      |> Enum.map(fn attr ->
        Map.get(record, attr)
      end)

    resource
    |> Ash.Resource.Info.attributes()
    |> Map.new(&{&1.name, Map.get(record, &1.name)})
    |> Ash.DataLayer.Ets.dump_to_native(Ash.Resource.Info.attributes(resource))
    |> case do
      {:ok, values} ->
        case Mnesia.transaction(fn ->
               Mnesia.write({table(resource), pkey, values})
             end) do
          {:atomic, _} ->
            {:ok, %{record | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}}}

          {:aborted, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  @impl true
  def destroy(resource, %{data: record}) do
    pkey =
      resource
      |> Ash.Resource.Info.primary_key()
      |> Enum.map(&Map.get(record, &1))

    result =
      Mnesia.transaction(fn ->
        Mnesia.delete({table(resource), pkey})
      end)

    case result do
      {:atomic, _} -> :ok
      {:aborted, error} -> {:error, error}
    end
  end

  @doc false
  @impl true
  def update(resource, changeset) do
    pkey = pkey_list(resource, changeset.data)

    result =
      Mnesia.transaction(fn ->
        with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
             {:ok, record} <- do_update(table(resource), {pkey, record}, resource),
             {:ok, record} <- Ash.DataLayer.Ets.cast_record(record, resource) do
          new_pkey = pkey_list(resource, record)

          if new_pkey != pkey do
            case destroy(resource, changeset) do
              :ok ->
                {:ok,
                 %{record | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}}}

              {:error, error} ->
                {:error, error}
            end
          else
            {:ok, %{record | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}}}
          end
        else
          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:atomic, {:error, error}} ->
        {:error, error}

      {:atomic, {:ok, result}} ->
        {:ok, result}

      {:aborted, {reason, stacktrace}} when is_exception(reason) ->
        {:error, Ash.Error.to_ash_error(reason, stacktrace)}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp pkey_list(resource, data) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(&Map.get(data, &1))
  end

  defp do_update(table, {pkey, record}, resource) do
    attributes = Ash.Resource.Info.attributes(resource)

    case Ash.DataLayer.Ets.dump_to_native(record, attributes) do
      {:ok, casted} ->
        case Mnesia.read({table(resource), pkey}) do
          [] ->
            {:error, "Record not found matching: #{inspect(pkey)}"}

          [{_, _, record}] ->
            Mnesia.write({table, pkey, Map.merge(record, casted)})
            [{_, _, record}] = Mnesia.read({table, pkey})
            {:ok, record}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  @impl true
  def upsert(resource, changeset, keys) do
    keys = keys || Ash.Resource.Info.primary_key(resource)

    if Enum.any?(keys, &is_nil(Ash.Changeset.get_attribute(changeset, &1))) do
      create(resource, changeset)
    else
      key_filters =
        Enum.map(keys, fn key ->
          {key, Ash.Changeset.get_attribute(changeset, key)}
        end)

      query = Ash.Query.do_filter(resource, and: [key_filters])

      resource
      |> resource_to_query(changeset.api)
      |> Map.put(:filter, query.filter)
      |> Map.put(:tenant, changeset.tenant)
      |> run_query(resource)
      |> case do
        {:ok, []} ->
          create(resource, changeset)

        {:ok, [result]} ->
          to_set = Ash.Changeset.set_on_upsert(changeset, keys)

          changeset =
            changeset
            |> Map.put(:attributes, %{})
            |> Map.put(:data, result)
            |> Ash.Changeset.force_change_attributes(to_set)

          update(resource, changeset)

        {:ok, _} ->
          {:error, "Multiple records matching keys"}
      end
    end
  end

  @doc false
  @impl true
  def transaction(_, func, _timeout, _reason) do
    case Mnesia.transaction(func) do
      {:atomic, result} ->
        {:ok, result}

      {:aborted, {reason, stacktrace}} when is_exception(reason) ->
        {:error, Ash.Error.to_ash_error(reason, stacktrace)}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @impl true
  @spec rollback(term, term) :: no_return
  def rollback(_, value) do
    Mnesia.abort(value)
  end
end
