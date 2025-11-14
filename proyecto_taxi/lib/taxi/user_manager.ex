defmodule Taxi.UserManager do
  use GenServer
  @users_file "data/users.json"

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    File.mkdir_p!("data")
    users = load_users()
    {:ok, users}
  end

  def authenticate_or_register(username, role, password) do
    GenServer.call(__MODULE__, {:auth_or_reg, username, role, password})
  end

  def login(username, password) do
    GenServer.call(__MODULE__, {:login, username, password})
  end

  def register(username, role, password) do
    GenServer.call(__MODULE__, {:register, username, role, password})
  end

  def add_score(username, delta) do
    GenServer.call(__MODULE__, {:add_score, username, delta})
  end

  def increment_streak(username) do
    GenServer.call(__MODULE__, {:increment_streak, username})
  end

  def reset_streak(username) do
    GenServer.call(__MODULE__, {:reset_streak, username})
  end

  def get_streak(username) do
    GenServer.call(__MODULE__, {:get_streak, username})
  end

  def get_score(username) do
    GenServer.call(__MODULE__, {:get_score, username})
  end

  def ranking(limit \\ 10) do
    GenServer.call(__MODULE__, {:ranking, limit})
  end

  def ranking_by_role(role, limit \\ 10) do
    GenServer.call(__MODULE__, {:ranking_by_role, role, limit})
  end

  def get_user_role(username) do
    GenServer.call(__MODULE__, {:get_role, username})
  end

  def get_user_role_safe(username) do
    case GenServer.call(__MODULE__, {:get_role, username}) do
      nil -> :client
      role -> role
    end
  end

  def get_all_users do
    GenServer.call(__MODULE__, :get_all_users)
  end

  def handle_call({:auth_or_reg, username, role, password}, _from, users) do
    case Map.get(users, username) do
      nil ->
        user = %{username: username, role: role, password: password, score: 0, streak: 0}
        users2 = Map.put(users, username, user)
        persist_users(users2)
        {:reply, {:ok, user}, users2}

      %{password: ^password} = user ->
        {:reply, {:ok, user}, users}

      _ ->
        {:reply, {:error, :invalid_password}, users}
    end
  end

  def handle_call({:login, username, password}, _from, users) do
    case Map.get(users, username) do
      nil ->
        {:reply, {:error, :user_not_found}, users}

      %{password: ^password} = user ->
        {:reply, {:ok, user}, users}

      _ ->
        {:reply, {:error, :invalid_password}, users}
    end
  end

  def handle_call({:register, username, role, password}, _from, users) do
    case Map.get(users, username) do
      nil ->
        user = %{username: username, role: role, password: password, score: 0, streak: 0}
        users2 = Map.put(users, username, user)
        persist_users(users2)
        {:reply, {:ok, user}, users2}

      _ ->
        {:reply, {:error, :user_already_exists}, users}
    end
  end

  def handle_call({:add_score, username, delta}, _from, users) do
    users2 =
      update_in(users, [username], fn
        nil -> nil
        u -> Map.update!(u, :score, &(&1 + delta))
      end)

    persist_users(users2)
    {:reply, :ok, users2}
  end

  def handle_call({:increment_streak, username}, _from, users) do
    {bonus, users2} =
      case Map.get(users, username) do
        nil ->
          {0, users}
        user ->
          new_streak = user.streak + 1
          bonus = calculate_bonus(new_streak)

          updated_user = user
            |> Map.put(:streak, new_streak)
            |> Map.update!(:score, &(&1 + bonus))

          {bonus, Map.put(users, username, updated_user)}
      end

    persist_users(users2)
    {:reply, {:ok, bonus}, users2}
  end

  def handle_call({:reset_streak, username}, _from, users) do
    users2 =
      update_in(users, [username], fn
        nil -> nil
        u -> Map.put(u, :streak, 0)
      end)

    persist_users(users2)
    {:reply, :ok, users2}
  end

  def handle_call({:get_streak, username}, _from, users) do
    streak =
      case Map.get(users, username) do
        nil -> 0
        user -> Map.get(user, :streak, 0)
      end
    {:reply, streak, users}
  end

  def handle_call({:get_score, username}, _from, users) do
    score = users |> Map.get(username) |> (fn u -> if u, do: u.score, else: 0 end).()
    {:reply, score, users}
  end

  def handle_call({:ranking, limit}, _from, users) do
    top =
      users
      |> Map.values()
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:reply, top, users}
  end

  def handle_call({:ranking_by_role, role, limit}, _from, users) do
    top =
      users
      |> Map.values()
      |> Enum.filter(fn u -> u.role == role end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:reply, top, users}
  end

  def handle_call({:get_role, username}, _from, users) do
    role =
      case Map.get(users, username) do
        nil -> nil
        user -> user.role
      end
    {:reply, role, users}
  end

  def handle_call(:get_all_users, _from, users) do
    {:reply, users, users}
  end

  defp calculate_bonus(streak) do
    cond do
      streak >= 10 -> 25
      streak >= 5 -> 10
      streak >= 3 -> 5
      true -> 0
    end
  end

  defp persist_users(users_map) do
    users_list = users_map
      |> Map.values()
      |> Enum.map(fn u ->
        %{
          "username" => u.username,
          "role" => Atom.to_string(u.role),
          "password" => u.password,
          "score" => u.score,
          "streak" => Map.get(u, :streak, 0)
        }
      end)

    json = Jason.encode!(users_list, pretty: true)
    File.write!(@users_file, json)
  end

  defp load_users do
    case File.read(@users_file) do
      {:ok, content} ->
        content = String.trim(content)

        cond do
          content == "" ->
            %{}

          String.starts_with?(content, "[") or String.starts_with?(content, "{") ->
            case Jason.decode(content) do
              {:ok, users_list} when is_list(users_list) ->
                users_list
                |> Enum.reduce(%{}, fn user, acc ->
                  username = user["username"]
                  role = String.to_atom(user["role"])
                  password = user["password"]
                  score = user["score"] || 0
                  streak = user["streak"] || 0

                  Map.put(acc, username, %{
                    username: username,
                    role: role,
                    password: password,
                    score: score,
                    streak: streak
                  })
                end)

              _ ->
                %{}
            end

          String.contains?(content, ",") ->
            IO.puts("Detectado formato CSV antiguo en users.json, convirtiendo a JSON...")

            users = content
            |> String.split("\n", trim: true)
            |> Enum.reduce(%{}, fn line, acc ->
              line = String.trim(line)

              case String.split(line, ",") do
                [username, role_s, password, score_s] ->
                  Map.put(acc, username, %{
                    username: username,
                    role: String.to_atom(role_s),
                    password: password,
                    score: String.to_integer(String.trim(score_s)),
                    streak: 0
                  })

                [username, role_s, password, score_s, streak_s] ->
                  Map.put(acc, username, %{
                    username: username,
                    role: String.to_atom(role_s),
                    password: password,
                    score: String.to_integer(String.trim(score_s)),
                    streak: String.to_integer(String.trim(streak_s))
                  })

                _ -> acc
              end
            end)

            persist_users(users)
            IO.puts("Usuarios convertidos a JSON exitosamente")
            users

          true ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
