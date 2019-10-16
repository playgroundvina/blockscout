defmodule Explorer.Chain.Import.Runner.CeloAccounts do
  @moduledoc """
  Bulk imports Celo accounts to the DB table.
  """

  require Ecto.Query

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.{Import, CeloAccount}

  import Ecto.Query, only: [from: 2]

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [CeloAccount.t()]

  @impl Import.Runner
  def ecto_schema_module, do: CeloAccount

  @impl Import.Runner
  def option_key, do: :celo_accounts

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[#{ecto_schema_module()}.t()]",
      value_description: "List of `t:#{ecto_schema_module()}.t/0`s"
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    # Enforce ShareLocks tables order (see docs: sharelocks.md)
    multi
    |> Multi.run(:acquire_all_celo_accounts, fn repo, _ ->
      acquire_all_celo_accounts(repo)
    end)
    |> Multi.run(:mark_as_deleted, fn repo, _ ->
      mark_as_deleted(repo, changes_list, insert_options)
    end)
    |> Multi.run(:insert_celo_accounts, fn repo, _ ->
      insert(repo, changes_list, insert_options)
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  defp acquire_all_celo_accounts(repo) do
    query =
      from(
        account in CeloAccount,
        # Enforce ShareLocks order (see docs: sharelocks.md)
        order_by: account.address,
        lock: "FOR UPDATE"
      )

    accounts = repo.all(query)

    {:ok, accounts}
  end

  defp mark_as_deleted(repo, changes_list, %{timeout: timeout}) when is_list(changes_list) do
    addresses = Enum.map(changes_list, & &1.address)

    query =
      from(
        account in CeloAccount,
        where: account.address not in ^addresses,
        # ShareLocks order already enforced by `acquire_all_staking_pools` (see docs: sharelocks.md)
        update: [set: [is_deleted: true, is_active: false]]
      )

    try do
      {_, result} = repo.update_all(query, [], timeout: timeout)

      {:ok, result}
    rescue
      postgrex_error in Postgrex.Error ->
        {:error, %{exception: postgrex_error}}
    end
  end

  @spec insert(Repo.t(), [map()], %{
          optional(:on_conflict) => Import.Runner.on_conflict(),
          required(:timeout) => timeout,
          required(:timestamps) => Import.timestamps()
        }) ::
          {:ok, [CeloAccount.t()]}
          | {:error, [Changeset.t()]}
  defp insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    # Enforce StackingPool ShareLocks order (see docs: sharelocks.md)
    ordered_changes_list = Enum.sort_by(changes_list, & &1.address)

    {:ok, _} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        conflict_target: :address,
        on_conflict: on_conflict,
        for: CeloAccount,
        returning: [:address],
        timeout: timeout,
        timestamps: timestamps
      )
  end

  defp default_on_conflict do
    from(
      pool in CeloAccount,
      update: [
        set: [
          account_type: fragment("EXCLUDED.account_type"),
          gold: fragment("EXCLUDED.gold"),
          usd: fragment("EXCLUDED.usd"),
          locked_gold: fragment("EXCLUDED.locked_gold"),
          notice_period: fragment("EXCLUDED.notice_period"),
          rewards: fragment("EXCLUDED.rewards"),
        ]
      ]
    )
  end

end
