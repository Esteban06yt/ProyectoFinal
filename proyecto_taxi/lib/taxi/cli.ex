defmodule Taxi.CLI do
  @moduledoc """
  Módulo CLI para interactuar con el sistema.
  Ejemplo de uso:
    Taxi.CLI.start()
  Comandos:
    connect username [role]
    disconnect
    request_trip origen=Parque destino=Centro
    list_trips
    accept_trip trip_id
    my_score
    ranking
    help
    quit
  """

  def start do
    IO.puts("Bienvenido al sistema Taxi CLI")
    loop(nil)
  end

  defp loop(session_user) do
    input = IO.gets("> ") |> to_string() |> String.trim()
    case parse_and_exec(input, session_user) do
      {:ok, new_session} -> loop(new_session)
      :quit -> :ok
      {:error, msg, s} ->
        IO.puts("Error: #{msg}")
        loop(s)
    end
  end

  defp parse_and_exec("", s), do: {:ok, s}

  defp parse_and_exec("help", s) do
    IO.puts("""
    Comandos disponibles:
      connect username [role]
      disconnect
      request_trip origen=Parque destino=Centro
      list_trips
      accept_trip trip_id
      my_score
      ranking
      help
      quit
    """)
    {:ok, s}
  end

  defp parse_and_exec("quit", _s), do: :quit

  defp parse_and_exec(<<"connect ", rest::binary>>, _s) do
    parts = String.split(rest)
    case parts do
      [username] ->
        password = get_password()
        do_connect(username, "cliente", password)
      [username, role] ->
        password = get_password()
        do_connect(username, role, password)
      _ ->
        {:error, "Uso: connect username [role]", nil}
    end
  end

  defp parse_and_exec("disconnect", _s) do
    caller = self()
    :ok = Taxi.Server.disconnect(caller)
    IO.puts("Desconectado correctamente")
    {:ok, nil}
  end

  defp parse_and_exec(cmd, s) do
    cond do
      String.starts_with?(cmd, "request_trip ") ->
        handle_request_trip(cmd, s)

      String.starts_with?(cmd, "accept_trip ") ->
        handle_accept_trip(cmd, s)

      cmd == "list_trips" ->
        handle_list_trips(s)

      cmd == "my_score" ->
        handle_my_score(s)

      cmd == "ranking" ->
        handle_ranking(s)

      true ->
        IO.puts("Comando desconocido: #{cmd}")
        {:ok, s}
    end
  end

  defp handle_request_trip(cmd, s) do
    args = parse_kv_args(String.replace_prefix(cmd, "request_trip ", ""))
    case {Map.get(args, "origen"), Map.get(args, "destino")} do
      {nil, _} -> {:error, "Falta origen", s}
      {_, nil} -> {:error, "Falta destino", s}
      {o, d} ->
        if s == nil do
          {:error, "No estás conectado. Usa connect", s}
        else
          case Taxi.Server.request_trip(self(), s, o, d) do
            {:ok, id} ->
              IO.puts("Viaje creado con id #{id}")
              {:ok, s}
            {:error, reason} ->
              {:error, "Error creando viaje: #{inspect(reason)}", s}
          end
        end
    end
  end

  defp handle_list_trips(s) do
    trips = Taxi.Server.list_trips()
    if Enum.empty?(trips) do
      IO.puts("No hay viajes disponibles.")
    else
      Enum.each(trips, fn t ->
        IO.puts("id=#{t["id"]} cliente=#{t["client"]} #{t["origin"]}->#{t["destination"]}")
      end)
    end
    {:ok, s}
  end

  defp handle_accept_trip(cmd, s) do
    if s == nil do
      {:error, "No estás conectado. Usa connect", s}
    else
      trip_id = String.trim(String.replace_prefix(cmd, "accept_trip ", ""))
      case Taxi.Server.accept_trip(self(), trip_id, s) do
        {:ok, id} ->
          IO.puts("Aceptaste el viaje #{id}")
          {:ok, s}
        {:error, reason} ->
          {:error, "No se pudo aceptar: #{inspect(reason)}", s}
      end
    end
  end

  defp handle_my_score(s) do
    if s == nil do
      {:error, "No estás conectado.", s}
    else
      score = Taxi.Server.my_score(s)
      IO.puts("Puntaje de #{s}: #{score}")
      {:ok, s}
    end
  end

  defp handle_ranking(s) do
    r = Taxi.Server.ranking()
    Enum.each(r, fn u -> IO.puts("#{u.username} (#{u.role}) -> #{u.score}") end)
    {:ok, s}
  end

  defp do_connect(username, role, password) do
    caller = self()
    case Taxi.Server.connect(caller, username, role, password) do
      {:ok, user} ->
        IO.puts("Conectado como #{user}")
        {:ok, username}
      {:error, :invalid_password} ->
        IO.puts("Contraseña incorrecta")
        {:ok, nil}
    end
  end

  defp get_password(prompt \\ "Introduce tu contraseña: ") do
    IO.write(prompt)

    password =
      case :os.type() do
        {:unix, _} ->
          System.cmd("stty", ["-echo"])
          pass = IO.gets("") |> String.trim()
          System.cmd("stty", ["echo"])
          IO.puts("")
          pass

        _ ->
          IO.gets("") |> String.trim()
      end

    password
  end

  defp parse_kv_args(str) do
    str
    |> String.split()
    |> Enum.map(fn token ->
      case String.split(token, "=") do
        [k, v] -> {k, v}
        _ -> {nil, nil}
      end
    end)
    |> Enum.reject(fn {k, _} -> k == nil end)
    |> Enum.into(%{})
  end
end
