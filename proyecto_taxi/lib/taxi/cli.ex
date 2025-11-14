defmodule Taxi.CLI do
  def start do
    server_node = detect_server_node()
    case server_node do
      nil ->
        IO.puts("No se encontró el nodo servidor")
        IO.puts("Asegúrate de conectarte primero: Node.connect(:\"server@Esteban06yt\")")
      node when node == node() ->
        IO.puts("Ejecutando en nodo SERVIDOR")
        IO.puts("Bienvenido al sistema Taxi CLI")
        loop(nil, node)
      node ->
        IO.puts("Conectado al servidor remoto: #{node}")
        IO.puts("Bienvenido al sistema Taxi CLI")
        loop(nil, node)
    end
  end

  defp loop(session_user, server_node) do
    input = IO.gets("> ") |> to_string() |> String.trim()
    case parse_and_exec(input, session_user, server_node) do
      {:ok, new_session} -> loop(new_session, server_node)
      :quit -> :ok
      {:error, msg, s} ->
        IO.puts("Error: #{msg}")
        loop(s, server_node)
    end
  end

  defp parse_and_exec("", s, _node), do: {:ok, s}

  defp parse_and_exec("help", s, _node) do
    IO.puts("""
    Comandos disponibles:
      connect                 -> iniciar sesión o crear cuenta
      disconnect              -> salir de la sesión actual
      request_trip origen=Parque destino=Centro  (solo clientes)
      cancel_trip trip_id     -> cancelar un viaje pendiente (-3 puntos)
      list_trips              -> ver viajes disponibles
      my_trips                -> ver mis viajes activos
      accept_trip trip_id     (solo conductores)
      my_score / stats        -> ver mi puntaje y racha
      ranking                 -> ver ranking global
      ranking_clients         -> ver ranking de clientes
      ranking_drivers         -> ver ranking de conductores
      locations               -> ver ubicaciones disponibles
      help
      quit

      Bonos por racha (conductores):
       3 viajes -> +5 pts | 5 viajes -> +10 pts | 10 viajes -> +25 pts
    """)
    {:ok, s}
  end

  defp parse_and_exec("quit", _s, _node), do: :quit

  defp parse_and_exec("connect", _s, server_node) do
    IO.puts("¿Deseas iniciar sesión o crear una nueva cuenta?")
    IO.puts("1. Iniciar sesión")
    IO.puts("2. Crear cuenta")
    opcion = IO.gets("> ") |> String.trim()

    case opcion do
      "1" -> do_login(server_node)
      "2" -> do_register(server_node)
      _ ->
        IO.puts("Opción no válida, usa 1 o 2")
        {:ok, nil}
    end
  end

  defp parse_and_exec("disconnect", _s, server_node) do
    caller = self()
    :ok = call_server(server_node, Taxi.Server, :disconnect, [caller])
    IO.puts("Desconectado correctamente.")
    {:ok, nil}
  end

  defp parse_and_exec(cmd, s, server_node) do
    cond do
      String.starts_with?(cmd, "request_trip ") ->
        handle_request_trip(cmd, s, server_node)

      String.starts_with?(cmd, "cancel_trip ") ->
        handle_cancel_trip(cmd, s, server_node)

      String.starts_with?(cmd, "accept_trip ") ->
        handle_accept_trip(cmd, s, server_node)

      cmd == "list_trips" ->
        handle_list_trips(s, server_node)

      cmd == "my_trips" ->
        handle_my_trips(s, server_node)

      cmd == "my_score" or cmd == "stats" ->
        handle_my_score(s, server_node)

      cmd == "ranking" ->
        handle_ranking(s, server_node)

      cmd == "ranking_clients" ->
        handle_ranking_by_role(s, server_node, :client)

      cmd == "ranking_drivers" ->
        handle_ranking_by_role(s, server_node, :driver)

      cmd == "locations" ->
        handle_locations(s, server_node)

      true ->
        IO.puts("Comando desconocido: #{cmd}")
        {:ok, s}
    end
  end

  defp do_login(server_node) do
    username = IO.gets("Nombre de usuario: ") |> String.trim()
    password = get_password("Contraseña: ")

    case call_server(server_node, Taxi.Server, :connect, [self(), username, nil, password]) do
      {:ok, user} ->
        IO.puts("Bienvenido de nuevo, #{user}")
        {:ok, username}

      {:error, :user_not_found} ->
        IO.puts("Usuario no encontrado.")
        {:ok, nil}

      {:error, :invalid_password} ->
        IO.puts("Contraseña incorrecta.")
        {:ok, nil}

      {:badrpc, reason} ->
        IO.puts("Error de conexión con el servidor: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp do_register(server_node) do
    username = IO.gets("Elige un nombre de usuario: ") |> String.trim()
    password = get_password("Crea una contraseña: ")

    IO.puts("Selecciona tu rol:")
    IO.puts("1. Cliente")
    IO.puts("2. Conductor")
    role =
      case IO.gets("> ") |> String.trim() do
        "1" -> "cliente"
        "2" -> "conductor"
        _ -> "cliente"
      end

    case call_server(server_node, Taxi.Server, :connect, [self(), username, role, password]) do
      {:ok, user} ->
        IO.puts("Cuenta creada y conectada como #{user}")
        {:ok, username}

      {:error, :user_already_exists} ->
        IO.puts("Ya existe una cuenta con ese nombre.")
        {:ok, nil}

      {:badrpc, reason} ->
        IO.puts("Error de conexión: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  defp handle_request_trip(cmd, s, server_node) do
    if s == nil do
      {:error, "No estás conectado. Usa connect", s}
    else
      user_role = call_server(server_node, Taxi.UserManager, :get_user_role, [s])
      if user_role != :client do
        {:error, "Solo los clientes pueden solicitar viajes. Tu rol es: #{user_role}", s}
      else
        args = parse_kv_args(String.replace_prefix(cmd, "request_trip ", ""))
        case {Map.get(args, "origen"), Map.get(args, "destino")} do
          {nil, _} -> {:error, "Falta origen", s}
          {_, nil} -> {:error, "Falta destino", s}
          {o, d} ->
            case call_server(server_node, Taxi.Server, :request_trip, [self(), s, o, d]) do
              {:ok, id} ->
                IO.puts("Viaje creado con ID #{id}")
                {:ok, s}

              {:error, :invalid_origin} ->
                {:error, "El origen '#{o}' no es válido. Usa 'locations' para ver opciones", s}

              {:error, :invalid_destination} ->
                {:error, "El destino '#{d}' no es válido", s}

              {:error, :same_origin_destination} ->
                {:error, "El origen y destino no pueden ser iguales", s}

              {:error, :trip_already_exists} ->
                {:error, "Ya tienes un viaje pendiente con ese origen/destino", s}

              {:error, :user_has_active_trip} ->
                {:error, "Ya tienes un viaje activo. Complétalo o cancélalo primero", s}

              {:error, reason} ->
                {:error, "Error creando viaje: #{inspect(reason)}", s}

              {:badrpc, reason} ->
                {:error, "Error de conexión: #{inspect(reason)}", s}
            end
        end
      end
    end
  end

  defp handle_list_trips(s, server_node) do
    trips = call_server(server_node, Taxi.Server, :list_trips, [])
    case trips do
      {:badrpc, reason} ->
        IO.puts("Error obteniendo viajes: #{inspect(reason)}")
      trips when is_list(trips) ->
        if Enum.empty?(trips) do
          IO.puts("No hay viajes disponibles")
        else
          IO.puts("\nViajes disponibles:")
          Enum.each(trips, fn t ->
            IO.puts("  ID: #{t["id"]} | Cliente: #{t["client"]} | #{t["origin"]} -> #{t["destination"]}")
          end)
        end
    end
    {:ok, s}
  end

  defp handle_accept_trip(cmd, s, server_node) do
    if s == nil do
      {:error, "No estás conectado.", s}
    else
      user_role = call_server(server_node, Taxi.UserManager, :get_user_role, [s])
      if user_role != :driver do
        {:error, "Solo los conductores pueden aceptar viajes. Tu rol es: #{user_role}", s}
      else
        trip_id = String.trim(String.replace_prefix(cmd, "accept_trip ", ""))
        case call_server(server_node, Taxi.Server, :accept_trip, [self(), trip_id, s]) do
          {:ok, id} ->
            IO.puts("Aceptaste el viaje #{id}")
            {:ok, s}
          {:error, :trip_not_found} ->
            {:error, "El viaje #{trip_id} no existe o ya fue completado", s}
          {:error, :user_has_active_trip} ->
            {:error, "Ya tienes un viaje activo. Complétalo primero", s}
          {:error, reason} ->
            {:error, "No se pudo aceptar: #{inspect(reason)}", s}
          {:badrpc, reason} ->
            {:error, "Error de conexión: #{inspect(reason)}", s}
        end
      end
    end
  end

  defp handle_my_score(s, server_node) do
    if s == nil do
      {:error, "No estás conectado.", s}
    else
      score = call_server(server_node, Taxi.UserManager, :get_score, [s])
      streak = call_server(server_node, Taxi.UserManager, :get_streak, [s])
      role = call_server(server_node, Taxi.UserManager, :get_user_role, [s])

      IO.puts("\nTu estadística:")
      IO.puts("Puntaje: #{score} pts")

      if role == :driver and streak > 0 do
        next_bonus = cond do
          streak >= 10 -> "¡Máxima racha! Sigue así"
          streak >= 5 -> "Próximo bono en #{10 - streak} viajes (25 pts)"
          streak >= 3 -> "Próximo bono en #{5 - streak} viajes (10 pts)"
          true -> "Próximo bono en #{3 - streak} viajes (5 pts)"
        end
        IO.puts("Racha actual: #{streak} viajes consecutivos")
        IO.puts("#{next_bonus}")
      end

      {:ok, s}
    end
  end

  defp handle_ranking(s, server_node) do
    r = call_server(server_node, Taxi.Server, :ranking, [])
    case r do
      {:badrpc, reason} ->
        IO.puts("Error obteniendo ranking: #{inspect(reason)}")
      ranking when is_list(ranking) ->
        IO.puts("\nRanking Global:")
        Enum.with_index(ranking, 1) |> Enum.each(fn {u, pos} ->
          emoji = case pos do
            1 -> "1st"
            2 -> "2nd"
            3 -> "3rd"
            _ -> "#{pos}."
          end
          role_emoji = if u.role == :driver, do: "driver", else: "client"
          IO.puts("#{emoji} #{role_emoji} #{u.username} -> #{u.score} pts")
        end)
    end
    {:ok, s}
  end

  defp handle_ranking_by_role(s, server_node, role) do
    r = call_server(server_node, Taxi.Server, :ranking_by_role, [role])
    case r do
      {:badrpc, reason} ->
        IO.puts("Error obteniendo ranking: #{inspect(reason)}")
      ranking when is_list(ranking) ->
        title = if role == :client, do: "Ranking Clientes:", else: "Ranking Conductores:"
        IO.puts("\n#{title}")
        Enum.with_index(ranking, 1) |> Enum.each(fn {u, pos} ->
          lugar = case pos do
            1 -> "1st"
            2 -> "2nd"
            3 -> "3rd"
            _ -> "#{pos}."
          end
          IO.puts("#{lugar} #{u.username} -> #{u.score} pts")
        end)
    end
    {:ok, s}
  end

  defp handle_cancel_trip(cmd, s, server_node) do
    if s == nil do
      {:error, "No estás conectado", s}
    else
      trip_id = String.trim(String.replace_prefix(cmd, "cancel_trip ", ""))
      case call_server(server_node, Taxi.Server, :cancel_trip, [trip_id, s]) do
        {:ok, id} ->
          IO.puts("Viaje #{id} cancelado (-3 puntos)")
          {:ok, s}
        {:error, :cannot_cancel} ->
          {:error, "No puedes cancelar este viaje (ya está en progreso o no es tuyo)", s}
        {:error, reason} ->
          {:error, "Error: #{inspect(reason)}", s}
        {:badrpc, reason} ->
          {:error, "Error de conexión: #{inspect(reason)}", s}
      end
    end
  end

  defp handle_my_trips(s, server_node) do
    if s == nil do
      {:error, "No estás conectado", s}
    else
      trips = call_server(server_node, Taxi.Server, :my_trips, [s])
      if Enum.empty?(trips) do
        IO.puts("No tienes viajes activos")
      else
        IO.puts("\nTus viajes activos:")
        Enum.each(trips, fn t ->
          status_icon = case t["state"] do
            :waiting -> "esperando"
            :in_progress -> "en progreso"
            _ -> "ok"
          end
          driver = t["driver"] || "esperando..."
          IO.puts("#{status_icon} ID:#{t["id"]} | #{t["origin"]}->#{t["destination"]} | Conductor: #{driver}")
        end)
      end
      {:ok, s}
    end
  end

  defp handle_locations(s, server_node) do
    locations = call_server(server_node, Taxi.Location, :list_locations, [])
    IO.puts("\nUbicaciones disponibles:")
    Enum.each(locations, fn loc -> IO.puts("  • #{loc}") end)
    {:ok, s}
  end

  defp get_password(prompt) do
    IO.write(prompt)
    IO.gets("") |> String.trim()
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

  defp detect_server_node do
    current = node()
    if String.starts_with?(Atom.to_string(current), "server@") do
      current
    else
      [current | Node.list()]
      |> Enum.find(fn n ->
        String.starts_with?(Atom.to_string(n), "server@")
      end)
    end
  end

  defp call_server(server_node, module, function, args) do
    if server_node == node() do
      apply(module, function, args)
    else
      :rpc.call(server_node, module, function, args)
    end
  end
end
