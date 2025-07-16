defmodule Ash.Test.Actions.ContextTest do
  @moduledoc false
  require Ash.Flags
  use ExUnit.Case, async: true

  import Ash.Test
  import Ash.Expr, only: [expr: 1]

  defmodule Scope do
    defstruct [:current_user, :org_id, :product_id]

    defimpl Ash.Scope.ToOpts do
      def get_actor(%{current_user: current_user}), do: {:ok, current_user}
      def get_tenant(_), do: {:ok, nil}

      def get_context(%{org_id: org_id, product_id: product_id}),
        do: {:ok, %{shared: %{org_id: org_id, product_id: product_id}}}

      def get_tracer(_), do: :error

      def get_authorize?(_), do: :error
    end
  end

  defmodule LogEvent do
    @moduledoc false
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets,
      domain: Ash.Test.Domain

    ets do
      private?(true)
    end

    code_interface do
      define :create, args: [:event]
    end

    attributes do
      uuid_primary_key :id
      attribute(:user_id, :uuid, public?: true)
      attribute(:org_id, :uuid, public?: true)
      attribute(:product_id, :integer, public?: true)
      attribute(:event, :string, public?: true)
    end

    actions do
      defaults [:read]

      create :create do
        accept [:event]
        change set_attribute(:user_id, actor(:id))
        change set_attribute(:org_id, context(:org_id))
        change set_attribute(:product_id, context(:product_id))
      end
    end
  end

  defmodule User do
    @moduledoc false
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets,
      domain: Ash.Test.Domain

    ets do
      private?(true)
    end

    code_interface do
      define :enable_product, args: [:product_id]
    end

    actions do
      create :create do
        primary? true
        accept [:last_used_product_id]
      end

      update :enable_product do
        require_atomic? false

        argument :product_id, :integer

        change set_attribute(:last_used_product_id, arg(:product_id))

        change after_action(fn changeset, user, context ->
                 LogEvent.create!("product enabled",
                   scope: context,
                   context: %{product_id: Ash.Changeset.get_argument(changeset, :product_id)}
                 )

                 {:ok, user}
               end)
      end
    end

    attributes do
      uuid_primary_key :id
      attribute(:last_used_product_id, :integer, public?: true)
    end
  end

  test "scope and context are merged correctly" do
    org_id = "8eaafd6e-ed0f-44cc-9429-c30c77d606dd"

    user = Ash.create!(User, %{last_used_product_id: 0})
    assert user.last_used_product_id == 0

    scope = %Scope{current_user: user, org_id: org_id, product_id: nil}

    user = User.enable_product!(user, 123, scope: scope)
    assert user.last_used_product_id == 123
    log_event = Ash.read_one!(LogEvent)
    user_id = user.id

    assert %Ash.Test.Actions.ContextTest.LogEvent{
             user_id: ^user_id,
             org_id: ^org_id,
             product_id: 123,
             event: "product enabled"
           } = log_event
  end
end
