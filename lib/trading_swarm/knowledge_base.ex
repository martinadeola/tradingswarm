defmodule TradingSwarm.KnowledgeBase do
  @moduledoc """
  Replaces the Premise Tuple Space (Inference Engine).
  Uses ETS for fact storage and Registry for pub/sub (Stigmergic Coordination).

  Critical state is persisted to DETS for crash recovery:
  - :portfolio_state — cash balances per strategy
  - :position — open positions per strategy
  - :meta_strategy — current leader selection

  Ephemeral facts (market_data, pending_order, indicators, etc.) remain ETS-only.
  """
  use GenServer
  @table_name :knowledge_base
  @dets_name :knowledge_base_durable
  @pubsub_registry TradingSwarm.PubSub

  # Fact types that survive restarts
  @persisted_types [:portfolio_state, :position, :meta_strategy]

  # --- Client API ---

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def subscribe(topic) do
    Registry.register(@pubsub_registry, topic, [])
  end

  def assert(fact_type, properties) when is_map(properties) do
    GenServer.call(__MODULE__, {:assert, fact_type, properties})
  end

  def retract(fact_type, properties) when is_map(properties) do
    GenServer.call(__MODULE__, {:retract, fact_type, properties})
  end

  def get_all(fact_type) do
    :ets.match_object(@table_name, {fact_type, :_})
    |> Enum.map(fn {^fact_type, properties} -> properties end)
  end

  def get_by(fact_type, conditions \\ %{}) do
    get_all(fact_type)
    |> Enum.filter(fn properties ->
      Enum.all?(conditions, fn {k, v} -> Map.get(properties, k) == v end)
    end)
  end

  def update(fact_type, match_conditions, updates) do
     GenServer.call(__MODULE__, {:update, fact_type, match_conditions, updates})
  end

  @doc "Check if any facts of the given type exist in the KB."
  def has_facts?(fact_type) do
    get_all(fact_type) != []
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    :ets.new(@table_name, [:bag, :public, :named_table, read_concurrency: true])

    # Open DETS file for persistent storage
    dets_path = dets_file_path()
    File.mkdir_p!(Path.dirname(dets_path))

    # In backtest mode, wipe DETS for a clean run
    if System.get_env("MODE") == "backtest" and File.exists?(dets_path) do
      File.rm!(dets_path)
    end

    {:ok, @dets_name} = :dets.open_file(@dets_name, [
      file: String.to_charlist(dets_path),
      type: :bag
    ])

    # Restore persisted facts from DETS into ETS
    restored = restore_from_dets()
    if restored > 0 do
      require Logger
      Logger.info("[KnowledgeBase] Restored #{restored} persisted facts from DETS")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:assert, fact_type, properties}, _from, state) do
    # Do not store market_data in ETS to prevent O(N^2) bag insertion slowdown
    if fact_type != :market_data do
      :ets.insert(@table_name, {fact_type, properties})
    end

    # Persist critical state to DETS
    if fact_type in @persisted_types do
      :dets.insert(@dets_name, {fact_type, properties})
    end

    # Broadcast to all agents listening to this fact type
    Registry.dispatch(@pubsub_registry, fact_type, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:fact_asserted, fact_type, properties})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:retract, fact_type, properties}, _from, state) do
    :ets.delete_object(@table_name, {fact_type, properties})

    if fact_type in @persisted_types do
      :dets.delete_object(@dets_name, {fact_type, properties})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, fact_type, match_conditions, updates}, _from, state) do
    objects = get_by(fact_type, match_conditions)
    Enum.each(objects, fn obj ->
      :ets.delete_object(@table_name, {fact_type, obj})
      new_obj = Map.merge(obj, updates)
      :ets.insert(@table_name, {fact_type, new_obj})

      # Persist if critical type
      if fact_type in @persisted_types do
        :dets.delete_object(@dets_name, {fact_type, obj})
        :dets.insert(@dets_name, {fact_type, new_obj})
      end

      Registry.dispatch(@pubsub_registry, fact_type, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:fact_updated, fact_type, new_obj})
      end)
    end)

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@dets_name)
    :ok
  end

  # --- Private ---

  defp restore_from_dets do
    :dets.foldl(fn {fact_type, properties}, count ->
      :ets.insert(@table_name, {fact_type, properties})
      count + 1
    end, 0, @dets_name)
  end

  defp dets_file_path do
    Application.get_env(:trading_swarm, :dets_path, "data/kb.dets")
  end
end
