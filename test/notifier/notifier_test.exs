defmodule Ash.Test.NotifierTest do
  @moduledoc false
  use ExUnit.Case, async: false

  defmodule Notifier do
    use Ash.Notifier

    def notify(notification) do
      send(Application.get_env(__MODULE__, :notifier_test_pid), {:notification, notification})
    end
  end

  defmodule PostLink do
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [
        Notifier
      ]

    ets do
      private? true
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end

    relationships do
      belongs_to :source_post, Ash.Test.NotifierTest.Post,
        primary_key?: true,
        allow_nil?: false

      belongs_to :destination_post, Ash.Test.NotifierTest.Post,
        primary_key?: true,
        allow_nil?: false
    end
  end

  defmodule Comment do
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [
        Notifier
      ]

    ets do
      private?(true)
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end

    attributes do
      uuid_primary_key :id

      attribute :name, :string
    end

    relationships do
      belongs_to :post, Ash.Test.NotifierTest.Post
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [
        Notifier
      ]

    ets do
      private?(true)
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end

    attributes do
      uuid_primary_key :id

      attribute :name, :string
    end

    relationships do
      many_to_many :related_posts, __MODULE__,
        through: PostLink,
        source_attribute_on_join_resource: :source_post_id,
        destination_attribute_on_join_resource: :destination_post_id

      has_many :comments, Comment, destination_attribute: :post_id
    end
  end

  defmodule Registry do
    @moduledoc false
    use Ash.Registry

    entries do
      entry Post
      entry PostLink
      entry Comment
    end
  end

  defmodule Api do
    use Ash.Api

    resources do
      registry Registry
    end
  end

  setup do
    Application.put_env(Notifier, :notifier_test_pid, self())

    :ok
  end

  describe "simple creates and updates" do
    test "a create notification occurs" do
      Post
      |> Ash.Changeset.new(%{name: "foo"})
      |> Api.create!()

      assert_receive {:notification, %{action: %{type: :create}}}
    end

    test "an update notification occurs" do
      Post
      |> Ash.Changeset.new(%{name: "foo"})
      |> Api.create!()
      |> Ash.Changeset.new(%{name: "bar"})
      |> Api.update!()

      assert_receive {:notification, %{action: %{type: :update}}}
    end

    test "a destroy notification occurs" do
      Post
      |> Ash.Changeset.new(%{name: "foo"})
      |> Api.create!()
      |> Api.destroy!()

      assert_receive {:notification, %{action: %{type: :destroy}}}
    end
  end

  describe "custom notifications" do
    test "a custom notification can be returned in a before or after action hook" do
      Comment
      |> Ash.Changeset.new(%{})
      |> Ash.Changeset.before_action(fn changeset ->
        {changeset,
         %{
           notifications: [
             %Ash.Notifier.Notification{
               resource: changeset.resource,
               metadata: %{custom?: true}
             }
           ]
         }}
      end)
      |> Api.create!()

      assert_receive {:notification, %Ash.Notifier.Notification{metadata: %{custom?: true}}}
    end
  end

  test "notifications use the data before its limited by a select statement" do
    Comment
    |> Ash.Changeset.new(%{name: "foobar"})
    |> Ash.Changeset.select([:id])
    |> Api.create!()

    assert_receive {:notification, %Ash.Notifier.Notification{data: %{name: "foobar"}}}
  end

  test "notifications use the changeset after before_action callbacks" do
    Comment
    |> Ash.Changeset.new(%{name: "foobar"})
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.set_context(changeset, %{foobar: :baz})
    end)
    |> Ash.Changeset.select([:id])
    |> Api.create!()

    assert_receive {:notification,
                    %Ash.Notifier.Notification{changeset: %{context: %{foobar: :baz}}}}
  end

  describe "related notifications" do
    test "an update notification occurs when relating many to many" do
      comment =
        Comment
        |> Ash.Changeset.new(%{})
        |> Api.create!()

      Post
      |> Ash.Changeset.new(%{name: "foo"})
      |> Ash.Changeset.manage_relationship(:comments, comment, type: :append_and_remove)
      |> Api.create!()

      assert_receive {:notification, %{action: %{type: :update}, resource: Comment}}
    end

    test "a create notification occurs for the join through relationship" do
      post =
        Post
        |> Ash.Changeset.new(%{name: "foo"})
        |> Api.create!()

      Post
      |> Ash.Changeset.new(%{name: "foo"})
      |> Ash.Changeset.manage_relationship(:related_posts, [post], type: :append_and_remove)
      |> Api.create!()

      assert_receive {:notification, %{action: %{type: :create}, resource: PostLink}}
    end

    test "a destroy notification occurs for the join through relationship" do
      post =
        Post
        |> Ash.Changeset.new(%{name: "foo"})
        |> Api.create!()

      Post
      |> Ash.Changeset.new(%{name: "foo"})
      |> Ash.Changeset.manage_relationship(:related_posts, [post], type: :append_and_remove)
      |> Api.create!()
      |> Ash.Changeset.new(%{})
      |> Ash.Changeset.manage_relationship(:related_posts, [], type: :append_and_remove)
      |> Api.update!()

      assert_receive {:notification, %{action: %{type: :destroy}, resource: PostLink}}
    end
  end
end
