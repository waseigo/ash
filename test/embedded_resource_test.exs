defmodule Ash.Test.Changeset.EmbeddedResourceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Ash.Changeset

  require Ash.Query

  defmodule Increasing do
    def init(opts), do: {:ok, opts}

    def validate(changeset, opts) do
      field = Keyword.get(opts, :field)

      if Changeset.changing_attribute?(changeset, field) do
        if Map.get(changeset.data, field) >=
             Changeset.get_attribute(changeset, field) do
          {:error, message: "must be increasing", field: field}
        else
          :ok
        end
      else
        :ok
      end
    end
  end

  defmodule DestroyMe do
    def init(opts), do: {:ok, opts}

    def validate(changeset, _opts) do
      if Changeset.get_attribute(changeset, :first_name) == "destroy" &&
           Changeset.get_attribute(changeset, :last_name) == "me" do
        :ok
      else
        {:error, "must be named \"destroy me\" to remove a profile"}
      end
    end
  end

  defmodule ProfileWithId do
    use Ash.Resource, data_layer: :embedded

    attributes do
      uuid_primary_key :id
      attribute :first_name, :string
      attribute :last_name, :string
      attribute :counter, :integer, default: 0, allow_nil?: false
    end

    validations do
      validate present([:first_name, :last_name])
      validate {Increasing, field: :counter}, on: :update
      validate {DestroyMe, []}, on: :destroy
    end

    calculations do
      calculate :full_name, :string, concat([:first_name, :last_name], " ")
    end
  end

  defmodule Profile do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :first_name, :string
      attribute :last_name, :string
      attribute :counter, :integer, default: 0, allow_nil?: false
    end

    validations do
      validate present([:first_name, :last_name])
      validate {Increasing, field: :counter}, on: :update
      validate {DestroyMe, []}, on: :destroy
    end

    calculations do
      calculate :full_name, :string, concat([:first_name, :last_name], " ")
    end
  end

  defmodule Tag do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :name, :string
      attribute :score, :integer
    end

    validations do
      # You can't remove a tag unless you first set its score to 0
      validate absent(:score), on: :destroy
      validate {Increasing, field: :score}, on: :update
      validate present(:score), on: :create
    end
  end

  defmodule TagWithId do
    use Ash.Resource, data_layer: :embedded

    attributes do
      uuid_primary_key :id
      attribute :name, :string
      attribute :score, :integer
    end

    validations do
      # You can't remove a tag unless you first set its score to 0
      validate absent(:score), on: :destroy
      validate {Increasing, field: :score}, on: :update
      validate present(:score), on: :create
    end
  end

  defmodule Author do
    use Ash.Resource, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      create :create
      update :update
    end

    attributes do
      uuid_primary_key :id

      attribute :profile, Profile,
        constraints: [
          load: [:full_name]
        ]

      attribute :profile_with_id, ProfileWithId,
        constraints: [
          load: [:full_name]
        ]

      attribute :tags, {:array, Tag}

      attribute :tags_max_length, {:array, Tag} do
        constraints max_length: 2, min_length: 1
      end

      attribute :tags_with_id, {:array, TagWithId}
    end
  end

  defmodule Registry do
    @moduledoc false
    use Ash.Registry

    entries do
      entry(Author)
    end
  end

  defmodule Api do
    @moduledoc false
    use Ash.Api

    resources do
      registry Registry
    end
  end

  test "embedded resources can be created" do
    assert %{profile: %Profile{}, tags: [%Tag{}, %Tag{}]} =
             Changeset.for_create(
               Author,
               :create,
               %{
                 profile: %{
                   first_name: "ash",
                   last_name: "ketchum"
                 },
                 tags: [
                   %{name: "trainer", score: 10},
                   %{name: "human", score: 100}
                 ]
               }
             )
             |> Api.create!()
  end

  test "embedded resources can be constrained with min/max length" do
    assert_raise Ash.Error.Invalid, ~r/must have 2 or fewer items/, fn ->
      Changeset.for_create(
        Author,
        :create,
        %{
          profile: %{
            first_name: "ash",
            last_name: "ketchum"
          },
          tags_max_length: [
            %{name: "trainer", score: 10},
            %{name: "human", score: 100},
            %{name: "gym_leader", score: 150}
          ]
        }
      )
      |> Api.create!()
    end

    assert_raise Ash.Error.Invalid, ~r/must have 1 or more items/, fn ->
      Changeset.for_create(
        Author,
        :create,
        %{
          profile: %{
            first_name: "ash",
            last_name: "ketchum"
          },
          tags_max_length: []
        }
      )
      |> Api.create!()
    end
  end

  test "embedded resources support calculations" do
    assert %{profile: %Profile{full_name: "ash ketchum"}} =
             Changeset.for_create(
               Author,
               :create,
               %{
                 profile: %{
                   first_name: "ash",
                   last_name: "ketchum"
                 }
               }
             )
             |> Api.create!()
  end

  test "embedded resources run validations on create" do
    msg =
      ~r/Invalid value provided for profile: at field last_name exactly 2 of first_name,last_name must be present/

    assert_raise Ash.Error.Invalid,
                 msg,
                 fn ->
                   Author
                   |> Changeset.for_create(
                     :create,
                     %{
                       profile: %{
                         first_name: "ash"
                       }
                     }
                   )
                   |> Api.create!()
                 end
  end

  test "embedded resources run validations on update" do
    assert author =
             Changeset.for_create(
               Author,
               :create,
               %{
                 profile: %{
                   first_name: "ash",
                   last_name: "ketchum"
                 }
               }
             )
             |> Api.create!()

    input = %{counter: author.profile.counter - 1}

    assert_raise Ash.Error.Invalid,
                 ~r/Invalid value provided for profile: at field counter must be increasing/,
                 fn ->
                   Changeset.for_update(
                     author,
                     :update,
                     %{
                       profile: input
                     }
                   )
                   |> Api.update!()
                 end
  end

  test "embedded resources run validations on destroy" do
    assert author =
             Changeset.for_create(
               Author,
               :create,
               %{
                 profile: %{
                   first_name: "ash",
                   last_name: "ketchum"
                 }
               }
             )
             |> Api.create!()

    assert_raise Ash.Error.Invalid, ~r/must be named "destroy me" to remove a profile/, fn ->
      Changeset.for_update(
        author,
        :update,
        %{profile: nil}
      )
      |> Api.update!()
    end

    author =
      Changeset.for_update(
        author,
        :update,
        %{profile: %{first_name: "destroy", last_name: "me"}}
      )
      |> Api.update!()

    Changeset.for_update(
      author,
      :update,
      %{profile: nil}
    )
    |> Api.update!()
  end

  test "when a non-array embedded resource has a public primary key, changes are considered a destroy + create, not an update" do
    assert author =
             Changeset.for_create(
               Author,
               :create,
               %{
                 profile_with_id: %{
                   first_name: "ash",
                   last_name: "ketchum"
                 }
               }
             )
             |> Api.create!()

    assert_raise Ash.Error.Invalid, ~r/must be named "destroy me" to remove a profile/, fn ->
      Changeset.for_update(
        author,
        :update,
        %{profile_with_id: %{first_name: "foo", last_name: "bar"}}
      )
      |> Api.update!()
    end

    author =
      Changeset.for_update(
        author,
        :update,
        %{
          profile_with_id: %{
            id: author.profile_with_id.id,
            first_name: "destroy",
            last_name: "me"
          }
        }
      )
      |> Api.update!()

    Changeset.for_update(
      author,
      :update,
      %{profile_with_id: %{first_name: "foo", last_name: "bar"}}
    )
    |> Api.update!()
  end

  test "a list of embeds without an id are destroyed and created each time" do
    assert author =
             Changeset.for_create(
               Author,
               :create,
               %{
                 tags: [
                   %{name: "trainer", score: 10},
                   %{name: "human", score: 100}
                 ]
               }
             )
             |> Api.create!()

    assert_raise Ash.Error.Invalid,
                 ~r/Invalid value provided for tags: at index 0 at field score must be present/,
                 fn ->
                   Changeset.for_update(
                     author,
                     :update,
                     %{
                       tags: [
                         %{name: "pokemon"}
                       ]
                     }
                   )
                   |> Api.update!()
                 end

    assert_raise Ash.Error.Invalid,
                 ~r/Invalid value provided for tags: at index 0 at field score must be absent/,
                 fn ->
                   Changeset.for_update(
                     author,
                     :update,
                     %{
                       tags: [
                         %{name: "pokemon", score: 1}
                       ]
                     }
                   )
                   |> Api.update!()
                 end
  end

  test "a list of embeds are updated where appropriate" do
    assert %{tags_with_id: [tag]} =
             author =
             Changeset.for_create(
               Author,
               :create,
               %{
                 tags_with_id: [
                   %{name: "trainer", score: 10}
                 ]
               }
             )
             |> Api.create!()

    assert_raise Ash.Error.Invalid,
                 ~r/Invalid value provided for tags_with_id: at index 0 at field score must be increasing/,
                 fn ->
                   Changeset.for_update(
                     author,
                     :update,
                     %{
                       tags_with_id: [
                         %{id: tag.id, score: 1}
                       ]
                     }
                   )
                   |> Api.update!()
                 end

    Changeset.for_update(
      author,
      :update,
      %{
        tags_with_id: [
          %{id: tag.id, score: 100}
        ]
      }
    )
    |> Api.update!()
  end
end
