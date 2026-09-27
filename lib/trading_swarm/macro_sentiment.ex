defmodule TradingSwarm.MacroSentiment do
  @moduledoc """
  Simulates fetching real market sentiment.
  
  Score mapping:
  - 0-25:  "Bearish"  (Extreme Fear / Fear)
  - 25-45: "Cautious" (Fear)
  - 45-55: "Neutral"  (Neutral)
  - 55-75: "Bullish"  (Greed)
  - 75-100: "Euphoric" (Extreme Greed)

  For this portfolio version, it simply generates random realistic sentiment
  shifts to demonstrate how the Meta Agent reacts to changing macro environments.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  @poll_interval 15 * 60 * 1000  # 15 minutes

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :fetch_sentiment, 2000)
    {:ok, %{last_score: nil, last_label: "Neutral"}}
  end

  @impl true
  def handle_info(:fetch_sentiment, state) do
    # Generate mock sentiment
    score = Enum.random(20..80)
    label = score_to_label(score)

    # Retract old macro events and assert new one
    old_macros = KnowledgeBase.get_by(:macro_event)
    Enum.each(old_macros, fn m -> KnowledgeBase.retract(:macro_event, m) end)

    KnowledgeBase.assert(:macro_event, %{
      sentiment: label,
      score: score,
      source: "mock_sentiment",
      impact: "High"
    })

    if score != state.last_score do
      Logger.info("[MacroSentiment] Macro vibe shifted to #{label} (Score: #{score})")
    end

    Process.send_after(self(), :fetch_sentiment, @poll_interval)
    {:noreply, %{state | last_score: score, last_label: label}}
  end

  defp score_to_label(score) when score < 25, do: "Bearish"
  defp score_to_label(score) when score < 45, do: "Cautious"
  defp score_to_label(score) when score < 55, do: "Neutral"
  defp score_to_label(score) when score < 75, do: "Bullish"
  defp score_to_label(_score), do: "Euphoric"
end
