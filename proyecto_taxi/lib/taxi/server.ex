defmodule Taxi.Server do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{sessions: %{}, trips: MapSet.new()}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def connect(caller, username, role_str, password) do
    role = if role_str, do: parse_role(role_str), else: nil
    GenServer.call(__MODULE__, {:connect, caller, username, role, password})
  end

  def disconnect(caller) do
    GenServer.call(__MODULE__, {:disconnect, caller})
  end

  def request_trip(caller, username, origin, destination) do
    GenServer.call(__MODULE__, {:request_trip, caller, username, origin, destination})
  end

  def cancel_trip(trip_id, username) do
    GenServer.call(__MODULE__, {:cancel_trip, trip_id, username})
  end

  def list_trips() do
    Registry.select(Taxi.TripRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(&Taxi.Trip.list_info/1)
    |> Enum.filter(fn m -> m["state"] == :waiting end)
  end

  def accept_trip(_caller, trip_id, driver) do
    if user_has_active_trip?(driver) do
      {:error, :user_has_active_trip}
    else
      case Taxi.Trip.accept(trip_id, driver) do
        {:ok, _} ->
          {:ok, trip_id}

        {:error, _} = e ->
          e
      end
    end
  end

  def my_trips(username) do
    GenServer.call(__MODULE__, {:my_trips, username})
  end

  def my_score(username) do
    Taxi.UserManager.get_score(username)
  end

  def ranking() do
    Taxi.UserManager.ranking(20)
  end

  def ranking_by_role(role) do
    Taxi.UserManager.ranking_by_role(role, 20)
  end

  def handle_call({:connect, caller, username, role, password}, _from, state) do
    all_users = Taxi.UserManager.get_all_users()
    existing_user = Map.get(all_users, username)

    case {role, existing_user} do
      {nil, user} when not is_nil(user) ->
        case Taxi.UserManager.login(username, password) do
          {:ok, _} ->
            sessions = Map.put(state.sessions, caller, username)
            {:reply, {:ok, username}, %{state | sessions: sessions}}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {nil, nil} ->
        {:reply, {:error, :user_not_found}, state}

      {role, nil} when not is_nil(role) ->
        case Taxi.UserManager.register(username, role, password) do
          {:ok, _} ->
            sessions = Map.put(state.sessions, caller, username)
            {:reply, {:ok, username}, %{state | sessions: sessions}}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {_role, _user} ->
        {:reply, {:error, :user_already_exists}, state}
    end
  end

  def handle_call({:disconnect, caller}, _from, state) do
    sessions = Map.delete(state.sessions, caller)
    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:request_trip, _caller, username, origin, destination}, _from, state) do
    norm_origin = Taxi.Location.normalize_location(origin)
    norm_destination = Taxi.Location.normalize_location(destination)

    cond do
      not Taxi.Location.valid_location?(origin) ->
        {:reply, {:error, :invalid_origin}, state}

      not Taxi.Location.valid_location?(destination) ->
        {:reply, {:error, :invalid_destination}, state}

      String.downcase(norm_origin) == String.downcase(norm_destination) ->
        {:reply, {:error, :same_origin_destination}, state}

      user_has_active_trip?(username) ->
        {:reply, {:error, :user_has_active_trip}, state}

      trip_exists?(username, norm_origin, norm_destination) ->
        {:reply, {:error, :trip_already_exists}, state}

      true ->
        id = :erlang.unique_integer([:positive]) |> Integer.to_string()
        args = %{id: id, client: username, origin: norm_origin, destination: norm_destination}
        spec = {Taxi.Trip, args}

        case DynamicSupervisor.start_child(Taxi.TripSupervisor, spec) do
          {:ok, _pid} ->
            {:reply, {:ok, id}, %{state | trips: MapSet.put(state.trips, id)}}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:cancel_trip, trip_id, username}, _from, state) do
    case Taxi.Trip.cancel(trip_id, username) do
      {:ok, :cancelled} ->
        {:reply, {:ok, trip_id}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:my_trips, username}, _from, state) do
    trips = Registry.select(Taxi.TripRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn id ->
      try do
        Taxi.Trip.list_info(id)
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn t ->
      t["client"] == username or t["driver"] == username
    end)
    {:reply, trips, state}
  end

  defp user_has_active_trip?(username) do
    Registry.select(Taxi.TripRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.any?(fn id ->
      try do
        case Taxi.Trip.list_info(id) do
          %{"client" => ^username, "state" => state} when state in [:waiting, :in_progress] -> true
          %{"driver" => ^username, "state" => :in_progress} -> true
          _ -> false
        end
      rescue
        _ -> false
      end
    end)
  end

  defp trip_exists?(username, origin, destination) do
    Registry.select(Taxi.TripRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.any?(fn id ->
      try do
        case Taxi.Trip.list_info(id) do
          %{"client" => ^username, "origin" => ^origin,
            "destination" => ^destination, "state" => :waiting} -> true
          _ -> false
        end
      rescue
        _ -> false
      end
    end)
  end

  defp parse_role("client"), do: :client
  defp parse_role("cliente"), do: :client
  defp parse_role("driver"), do: :driver
  defp parse_role("conductor"), do: :driver
  defp parse_role(_), do: :client
end
