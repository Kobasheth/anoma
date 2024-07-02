defmodule Anoma.Node.Executor.Worker do
  @moduledoc """
  I am a Nock worker, supporting scry.
  """
  alias Anoma.Node.Storage
  alias Anoma.Node.Ordering
  alias Anoma.Node.Logger
  alias Anoma.Node.Router

  use Router.Engine, restart: :transient
  use TypedStruct

  import Nock

  typedstruct do
    field(:order, Noun.t())
    field(:tx, {:kv | :rm, Noun.t()})
    field(:env, Nock.t())
    field(:completion_topic, Router.Addr.t())
  end

  def init({order, tx, env, completion_topic}) do
    send(self(), :run)

    {:ok,
     %__MODULE__{
       order: order,
       tx: tx,
       env: env,
       completion_topic: completion_topic
     }}
  end

  def handle_info(:run, s) do
    result = run(s)

    Router.cast(
      s.completion_topic,
      {:worker_done, Router.self_addr(), result}
    )

    {:stop, :normal, s}
  end

  @spec run(t()) :: :ok | :error
  def run(s = %__MODULE__{order: order, tx: {:kv, proto_tx}, env: env}) do
    logger = env.logger

    log_info({:dispatch, order, logger})
    storage = Router.Engine.get_state(env.ordering).storage

    with {:ok, stage_2_tx} <- nock(proto_tx, [9, 2, 0 | 1], env),
         {:ok, ordered_tx} <-
           nock(stage_2_tx, [10, [6, 1 | order], 0 | 1], env),
         {:ok, [key | value]} <- nock(ordered_tx, [9, 2, 0 | 1], env) do
      true_order = wait_for_ready(s)

      log_info({:writing, true_order, logger})
      Storage.put(storage, key, value)
      log_info({:put, key, logger})
      snapshot(storage, env)
      log_info({:success_run, logger})
      :ok
    else
      e ->
        log_info({:fail, e, logger})
        wait_for_ready(s)
        snapshot(storage, env)
        :error
    end
  end

  def run(s = %__MODULE__{order: order, tx: {:rm, gate}, env: env}) do
    logger = env.logger

    log_info({:dispatch, order, logger})
    storage = Router.Engine.get_state(env.ordering).storage

    with {:ok, ordered_tx} <- nock(gate, [10, [6, 1 | order], 0 | 1], env),
         {:ok, resource_tx} <- nock(ordered_tx, [9, 2, 0 | 1], env),
         vm_resource_tx <- Anoma.Resource.Transaction.from_noun(resource_tx),
         true_order = wait_for_ready(s),
         true <- Anoma.Resource.Transaction.verify(vm_resource_tx),
         true <- rm_nullifier_check(storage, vm_resource_tx.nullifiers) do
      log_info({:writing, true_order, logger})
      # this is not quite correct, but storage has to be revisited as a whole
      # for it to be made correct.
      # in particular, the get/put api must be deleted, since it cannot be correct,
      # but an append api should also be added.
      # the latter requires the merkle tree to be complete
      cm_tree =
        CommitmentTree.new(
          Storage.cm_tree_spec(),
          Anoma.Node.Router.Engine.get_state(storage).rm_commitments
        )

      new_tree =
        for commitment <- vm_resource_tx.commitments, reduce: cm_tree do
          tree ->
            cm_key = ["rm", "commitments", commitment]
            Storage.put(storage, cm_key, true)
            # yeah, this is not using the api right
            CommitmentTree.add(tree, [commitment])
            log_info({:put, cm_key, logger})
            tree
        end

      Storage.put(storage, ["rm", "commitment_root"], new_tree.root)

      for nullifier <- vm_resource_tx.nullifiers do
        nf_key = ["rm", "nullifiers", nullifier]
        Storage.put(storage, nf_key, true)
        log_info({:put, nf_key, logger})
      end

      snapshot(storage, env)
      log_info({:success_run, logger})
      :ok
    else
      # The failure had to be on the true match above, which is after
      # the wait for ready
      false ->
        log_info({:fail, false, logger})
        snapshot(storage, env)
        :error

      # This failed before the waiting for read as it's likely :error
      e ->
        log_info({:fail, e, logger})
        wait_for_ready(s)
        snapshot(storage, env)
        :error
    end
  end

  @spec rm_nullifier_check(Router.addr(), list(binary())) :: bool()
  def rm_nullifier_check(storage, nullifiers) do
    for nullifier <- nullifiers, reduce: true do
      acc ->
        nf_key = ["rm", "nullifiers", nullifier]
        acc && Storage.get(storage, nf_key) == :absent
    end
  end

  @spec wait_for_ready(t()) :: any()
  def wait_for_ready(%__MODULE__{env: env, order: order}) do
    logger = env.logger

    log_info({:ensure_read, logger})

    Ordering.caller_blocking_read_id(
      env.ordering,
      [order | env.snapshot_path]
    )

    log_info({:waiting_write_ready, logger})

    receive do
      {:write_ready, order} ->
        log_info({:write_ready, logger})
        order
    end
  end

  @spec snapshot(Router.addr(), Nock.t()) ::
          :ok | nil
  def snapshot(storage, env) do
    snapshot = hd(env.snapshot_path)
    log_info({:snap, {storage, snapshot}, env.logger})
    Storage.put_snapshot(storage, snapshot)
  end

  ############################################################
  #                     Logging Info                         #
  ############################################################

  defp log_info({:dispatch, order, logger}) do
    Logger.add(logger, :info, "Worker dispatched.
    Order id: #{inspect(order)}")
  end

  defp log_info({:writing, order, logger}) do
    Logger.add(logger, :info, "Worker writing.
    True order: #{inspect(order)}")
  end

  defp log_info({:fail, error, logger}) do
    Logger.add(logger, :error, "Worker failed! #{inspect(error)}")
  end

  defp log_info({:put, key, logger}) do
    Logger.add(logger, :info, "Putting #{inspect(key)}")
  end

  defp log_info({:success_run, logger}) do
    Logger.add(logger, :info, "Run succesfull!")
  end

  defp log_info({:ensure_read, logger}) do
    Logger.add(
      logger,
      :info,
      "#{inspect(self())}: making sure the snapshot is ready"
    )
  end

  defp log_info({:waiting_write_ready, logger}) do
    Logger.add(
      logger,
      :info,
      "#{inspect(self())}: waiting for a write ready"
    )
  end

  defp log_info({:write_ready, logger}) do
    Logger.add(
      logger,
      :info,
      "#{inspect(self())}: write ready"
    )
  end

  defp log_info({:snap, {s, ss}, logger}) do
    Logger.add(
      logger,
      :info,
      "Taking snapshot key #{inspect(ss)} in storage #{inspect(s)}"
    )
  end
end
