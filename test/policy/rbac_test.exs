defmodule Ash.Test.Policy.RbacTest do
  @doc false
  use ExUnit.Case

  require Ash.Query

  alias Ash.Test.Support.PolicyRbac.{Api, File, Membership, Organization, User}

  setup do
    [
      user: Api.create!(Ash.Changeset.new(User)),
      org: Api.create!(Ash.Changeset.new(Organization))
    ]
  end

  test "if the actor has no permissions, they can't see anything", %{
    user: user,
    org: org
  } do
    create_file(org, "foo")
    create_file(org, "bar")
    create_file(org, "baz")

    assert Api.read!(File, actor: user) == []
  end

  test "if the actor has permission to read a file, they can only read that file", %{
    user: user,
    org: org
  } do
    file_with_access = create_file(org, "foo")
    give_role(user, org, :viewer, :file, file_with_access.id)
    create_file(org, "bar")
    create_file(org, "baz")

    assert [%{name: "foo"}] = Api.read!(File, actor: user)
  end

  test "query params on relation are passed correctly to the policy", %{
    user: user,
    org: org
  } do
    user = Map.put(user, :rel_check, true)

    file_with_access = create_file(org, "foo")
    give_role(user, org, :viewer, :file, file_with_access.id)
    create_file(org, "bar")
    create_file(org, "baz")

    # select a forbidden field
    query =
      Organization
      |> Ash.Query.filter(id == ^org.id)
      |> Ash.Query.load(files: File |> Ash.Query.select([:forbidden]))

    assert_raise Ash.Error.Forbidden, fn ->
      Api.read!(query, actor: user) == []
    end

    # specify no select (everything is selected)
    query =
      Organization
      |> Ash.Query.filter(id == ^org.id)
      |> Ash.Query.load([:files])

    assert_raise Ash.Error.Forbidden, fn ->
      Api.read!(query, actor: user) == []
    end

    # select only an allowed field
    query =
      Organization
      |> Ash.Query.filter(id == ^org.id)
      |> Ash.Query.load(files: File |> Ash.Query.select([:id]))

    assert [%Organization{files: [%File{id: id}]}] = Api.read!(query, actor: user)
    assert id == file_with_access.id
  end

  test "unauthorized if no policy is defined", %{user: user} do
    assert_raise Ash.Error.Forbidden, fn ->
      Api.read!(User, actor: user) == []
    end
  end

  test "if the action can be performed, the can utility should return true", %{
    user: user,
    org: org
  } do
    file_with_access = create_file(org, "foo")
    give_role(user, org, :viewer, :file, file_with_access.id)
    create_file(org, "bar")
    create_file(org, "baz")

    assert Ash.Policy.Info.can(File, :read, user, api: Api)
  end

  test "if the query can be performed, the can utility should return true", %{
    user: user,
    org: org
  } do
    file_with_access = create_file(org, "foo")
    give_role(user, org, :viewer, :file, file_with_access.id)
    create_file(org, "bar")
    create_file(org, "baz")

    query = Ash.Query.for_read(File, :read)

    assert Ash.Policy.Info.can(File, query, user, api: Api)
  end

  test "if the changeset can be performed, the can utility should return true", %{
    user: user,
    org: org
  } do
    file_with_access = create_file(org, "foo")
    give_role(user, org, :viewer, :file, file_with_access.id)

    changeset =
      File
      |> Ash.Changeset.new(%{name: "bar"})
      |> Ash.Changeset.for_create(:create)
      |> Ash.Changeset.manage_relationship(:organization, org, type: :append_and_remove)

    assert Ash.Policy.Info.can(File, changeset, user, api: Api)
  end

  defp give_role(user, org, role, resource, resource_id) do
    Membership
    |> Ash.Changeset.new(%{role: role, resource: resource, resource_id: resource_id})
    |> Ash.Changeset.manage_relationship(:user, user, type: :append_and_remove)
    |> Ash.Changeset.manage_relationship(:organization, org, type: :append_and_remove)
    |> Api.create!()
  end

  defp create_file(org, name) do
    File
    |> Ash.Changeset.new(%{name: name})
    |> Ash.Changeset.manage_relationship(:organization, org, type: :append_and_remove)
    |> Api.create!()
  end
end
